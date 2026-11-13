#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# The repository Dex image is the local OIDC provider; the pinned index is
# resolved to the child that matches the architecture of the image under test.
dex_index='ghcr.io/tektum/dex@sha256:4469f9f77929bc30c8ad61f46b2ec8c94b2b11db10b080f8652371ef667e2842'
label=verity.smoke=oauth2-proxy-$$
network="verity-oauth2-proxy-net-$$"
dex="verity-oauth2-proxy-dex-$$"
proxy="verity-oauth2-proxy-$$"
work=$(mktemp -d)
cookie_secret=0123456789abcdef0123456789abcdef
client_secret=smoke-client-secret

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -fv >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  for c in "$dex" "$proxy"; do
    printf '%s\n' "--- logs: $c" >&2
    docker logs "$c" >&2 2>&1 || true
  done
  exit 1
}

expected_version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' \
  "$here/../melange.yaml")
[ -n "$expected_version" ] || fail 'could not read the recipe version'

# OCI contract.
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/oauth2-proxy"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/nonroot ||
  fail 'unexpected working directory'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" |
  grep -Fx 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' >/dev/null ||
  fail 'CA bundle environment is missing'

docker run --rm --network none --read-only --label "$label" "$image" --version \
  >"$work/version" 2>&1 || fail 'oauth2-proxy --version failed'
grep -F "oauth2-proxy v$expected_version " "$work/version" >/dev/null ||
  fail "version output does not report v$expected_version: $(cat "$work/version")"

# Negative: a missing cookie secret must be rejected before serving.
if docker run --rm --network none --read-only --label "$label" "$image" \
  --provider=oidc --oidc-issuer-url=http://127.0.0.1:1/dex \
  --client-id=x --client-secret=x --email-domain='*' \
  --upstream=static://200 >"$work/bad.out" 2>&1; then
  fail 'missing cookie secret unexpectedly succeeded'
fi
grep -F 'missing setting: cookie-secret' "$work/bad.out" >/dev/null ||
  fail "missing cookie secret diagnostic is missing: $(cat "$work/bad.out")"

# Negative: an unknown flag must be rejected.
if docker run --rm --network none --read-only --label "$label" "$image" \
  --no-such-flag >"$work/flag.out" 2>&1; then
  fail 'unknown flag unexpectedly succeeded'
fi
grep -F 'unknown flag: --no-such-flag' "$work/flag.out" >/dev/null ||
  fail "unknown flag diagnostic is missing: $(cat "$work/flag.out")"

# pull_child INDEX: pull the pinned index by its per-platform child digest,
# verifying the index bytes against the pin first so the pin stays authoritative.
image_arch=$(docker image inspect -f '{{.Architecture}}' "$image")
pull_child() {
  raw=$(docker buildx imagetools inspect --raw "$1") || fail "cannot inspect $1"
  [ "sha256:$(printf '%s' "$raw" | sha256sum | cut -d' ' -f1)" = "${1#*@}" ] ||
    fail "index digest mismatch for $1"
  child=$(printf '%s' "$raw" | jq -r --arg arch "$image_arch" '
    [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
    | if length == 1 then .[0] else empty end') || fail "cannot resolve a child of $1"
  case $child in
    sha256:*) ;;
    *) fail "no unique linux/$image_arch child in $1" ;;
  esac
  docker pull --quiet --platform "linux/$image_arch" "${1%%@*}@$child" >/dev/null ||
    fail "cannot pull ${1%%@*}@$child"
  printf '%s' "${1%%@*}@$child"
}
dex_image=$(pull_child "$dex_index")

# Dex with one static client and one static user (password: "password").
# The issuer and redirect hosts are container names; the host-side curl
# reaches them through --connect-to.
cat >"$work/dex.yaml" <<CFG
issuer: http://dex:5556/dex
storage:
  type: memory
web:
  http: 0.0.0.0:5556
oauth2:
  skipApprovalScreen: true
enablePasswordDB: true
staticClients:
  - id: oauth2-proxy
    name: oauth2-proxy
    secret: $client_secret
    redirectURIs:
      - http://proxy:4180/oauth2/callback
staticPasswords:
  - email: admin@example.com
    hash: "\$2a\$10\$2b2cU8CPhOTaGrs1HRQuAueS7JTT5ZHsHSzYiFPm1leZck7Mc8T4W"
    username: admin
    userID: 08a8684b-db88-4b73-90a9-3cd1661f5466
CFG
chmod 644 "$work/dex.yaml"

docker network create --label "$label" "$network" >/dev/null
docker run -d --name "$dex" --label "$label" --network "$network" \
  --network-alias dex --read-only --cap-drop ALL --security-opt no-new-privileges \
  -p 127.0.0.1::5556 -v "$work/dex.yaml:/cfg/dex.yaml:ro" \
  "$dex_image" serve /cfg/dex.yaml >/dev/null

# wait_http CONTAINER PORT PATH: print host:port once PATH answers 200.
wait_http() {
  i=0
  while [ "$i" -lt 60 ]; do
    [ "$(docker inspect --format '{{.State.Running}}' "$1")" = true ] ||
      fail "$1 exited before becoming ready"
    hostport=$(docker port "$1" "$2/tcp" 2>/dev/null | head -n 1 || true)
    if [ -n "$hostport" ] && curl -fsS -o /dev/null "http://$hostport$3" 2>/dev/null; then
      printf '%s' "$hostport"
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  fail "$1 did not become ready on $3"
}
dex_hostport=$(wait_http "$dex" 5556 /dex/.well-known/openid-configuration)

docker run -d --name "$proxy" --label "$label" --network "$network" \
  --network-alias proxy --read-only --cap-drop ALL --security-opt no-new-privileges \
  -p 127.0.0.1::4180 "$image" \
  --http-address=0.0.0.0:4180 \
  --provider=oidc \
  --oidc-issuer-url=http://dex:5556/dex \
  --client-id=oauth2-proxy \
  --client-secret="$client_secret" \
  --redirect-url=http://proxy:4180/oauth2/callback \
  --cookie-secret="$cookie_secret" \
  --cookie-secure=false \
  --email-domain='*' \
  --skip-provider-button=true \
  --set-xauthrequest=true \
  --upstream=static://200 >/dev/null
proxy_hostport=$(wait_http "$proxy" 4180 /ping)

curl -fsS "http://$proxy_hostport/ready" >"$work/ready" || fail 'ready endpoint failed'
grep -Fx OK "$work/ready" >/dev/null || fail 'ready endpoint did not answer OK'

browser() {
  curl -sS --max-redirs 10 -b "$work/jar" -c "$work/jar" \
    --connect-to "dex:5556:$dex_hostport" --connect-to "proxy:4180:$proxy_hostport" "$@"
}

# Unauthenticated requests are refused, not proxied.
code=$(browser -o "$work/anon" -w '%{http_code}' -H 'Accept: application/json' \
  http://proxy:4180/) || fail 'unauthenticated request failed'
[ "$code" = 401 ] || fail "unauthenticated API request returned $code, want 401"
if grep -F Authenticated "$work/anon" >/dev/null; then
  fail 'unauthenticated request reached the upstream'
fi

# A browser request without a session is sent straight to the Dex
# authorization endpoint for this client and callback.
browser -o /dev/null -D "$work/start.headers" http://proxy:4180/ ||
  fail 'unauthenticated browser request failed'
head -n 1 "$work/start.headers" | grep -E '^HTTP/[0-9.]+ 302' >/dev/null ||
  fail "unauthenticated browser request was not redirected: $(head -n 1 "$work/start.headers")"
location=$(awk 'tolower($1) == "location:" { sub(/\r$/, "", $2); print $2 }' "$work/start.headers")
case $location in
  http://dex:5556/dex/auth\?*) ;;
  *) fail "unexpected authorization redirect: $location" ;;
esac
case $location in
  *client_id=oauth2-proxy*) ;;
  *) fail "authorization redirect lacks client_id: $location" ;;
esac
case $location in
  *redirect_uri=http%3A%2F%2Fproxy%3A4180%2Foauth2%2Fcallback*) ;;
  *) fail "authorization redirect lacks redirect_uri: $location" ;;
esac

# Follow the authorization redirect to the Dex login form.
login_url=$(browser -L -o "$work/form" -w '%{url_effective}' "$location") ||
  fail 'authorization request failed'
case $login_url in
  http://dex:5556/dex/auth/local/login*) ;;
  *) fail "sign-in did not reach the Dex login form: $login_url" ;;
esac

# Negative: a wrong password must not yield a session.
code=$(browser -L -o "$work/denied" -w '%{http_code}' \
  --data-urlencode login=admin@example.com --data-urlencode password=wrong \
  "$login_url") || fail 'wrong-password request failed'
if grep -F Authenticated "$work/denied" >/dev/null; then
  fail 'wrong password reached the upstream'
fi
grep -i 'invalid' "$work/denied" >/dev/null ||
  fail "wrong password did not show a Dex error (status $code)"

# Log in; Dex redirects to the proxy callback, which exchanges the code with
# Dex over the container network, sets the session cookie and returns to /.
code=$(browser -L -o "$work/home" -w '%{http_code} %{url_effective}' \
  --data-urlencode login=admin@example.com --data-urlencode password=password \
  "$login_url") || fail 'login request failed'
[ "$code" = '200 http://proxy:4180/' ] ||
  fail "login flow ended at '$code', want '200 http://proxy:4180/'"
grep -Fx Authenticated "$work/home" >/dev/null ||
  fail 'authenticated request did not reach the upstream'

browser -f -o "$work/userinfo" http://proxy:4180/oauth2/userinfo ||
  fail 'userinfo request failed'
jq -e '.email == "admin@example.com"' "$work/userinfo" >/dev/null ||
  fail "userinfo does not carry the Dex identity: $(cat "$work/userinfo")"

# The auth endpoint used by ingress controllers exposes the identity headers.
code=$(browser -o /dev/null -D "$work/auth.headers" -w '%{http_code}' \
  http://proxy:4180/oauth2/auth) || fail 'auth request failed'
[ "$code" = 202 ] || fail "auth endpoint returned $code, want 202"
grep -i '^x-auth-request-email: admin@example.com' "$work/auth.headers" >/dev/null ||
  fail 'auth endpoint lacks X-Auth-Request-Email'
grep -i '^x-auth-request-user: ' "$work/auth.headers" >/dev/null ||
  fail 'auth endpoint lacks X-Auth-Request-User'

# Graceful stop on SIGTERM.
docker kill --signal TERM "$proxy" >/dev/null
code=$(docker wait "$proxy")
[ "$code" = 0 ] || fail "oauth2-proxy did not stop cleanly on SIGTERM (exit $code)"

printf 'SMOKE PASS image=%s\n' "$image"
