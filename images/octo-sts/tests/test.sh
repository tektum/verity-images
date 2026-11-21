#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
label=verity.test=octo-sts-$$
server="verity-octo-sts-server-$$"
work=$(mktemp -d)

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -fv >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  docker logs "$server" >&2 2>&1 || true
  printf '%s\n' "$1" >&2
  exit 1
}

expected_version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' \
  "$here/../melange.yaml")
[ -n "$expected_version" ] || fail 'could not read the recipe version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/octo-sts"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/nonroot ||
  fail 'unexpected working directory'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" \
  >"$work/env"
grep -Fx 'PORT=8080' "$work/env" >/dev/null || fail 'default PORT is not 8080'
grep -Fx 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' "$work/env" >/dev/null ||
  fail 'CA bundle environment is missing'

# The binary carries no version flag; the stamped Go main module version is the
# version contract.
created=$(docker create --label "$label" "$image")
docker cp "$created:/usr/bin/octo-sts" "$work/octo-sts"
docker rm "$created" >/dev/null
go version -m "$work/octo-sts" >"$work/buildinfo"
awk '$1 == "mod" && $2 == "github.com/octo-sts/app" { print $3 }' "$work/buildinfo" |
  grep -Ex "v$expected_version(\+dirty)?" >/dev/null ||
  fail "binary is not stamped with octo-sts v$expected_version"
awk '$1 == "path" { print $2 }' "$work/buildinfo" | grep -Fx github.com/octo-sts/app/cmd/app \
  >/dev/null || fail 'binary is not the octo-sts app command'

# Negative: without a GitHub App the service refuses to start.
if timeout 60 docker run --rm --label "$label" --network none --read-only "$image" \
  >"$work/no-app" 2>&1; then
  fail 'service started without a GitHub App'
fi
grep -F 'GITHUB_APP_IDS is required when APP_CONFIG_FILE is not set' "$work/no-app" \
  >/dev/null || fail 'missing GitHub App diagnostic is absent'

# Negative: STS_DOMAIN is required even with an App configured.
if timeout 60 docker run --rm --label "$label" --network none --read-only -e GITHUB_APP_IDS=1 \
  "$image" >"$work/no-domain" 2>&1; then
  fail 'service started without STS_DOMAIN'
fi
grep -F 'required key STS_DOMAIN missing value' "$work/no-domain" >/dev/null ||
  fail 'missing STS_DOMAIN diagnostic is absent'

# A throwaway App private key; no GitHub call is made in this test.
openssl genrsa -out "$work/app.pem" 2048 2>/dev/null || fail 'cannot generate a test key'
chmod 0644 "$work/app.pem"

docker run -d --label "$label" --name "$server" --read-only \
  -p 127.0.0.1::8080 \
  -v "$work/app.pem:/var/run/octo-sts/app.pem:ro" \
  -e STS_DOMAIN=octo-sts.test \
  -e GITHUB_APP_IDS=12345 \
  -e APP_SECRET_CERTIFICATE_FILE=/var/run/octo-sts/app.pem \
  -e METRICS=false \
  "$image" >/dev/null
port=$(docker port "$server" 8080/tcp | head -n 1 | sed 's/.*://')
[ -n "$port" ] || fail 'server port is not published'

attempts=0
until curl --fail --silent --connect-timeout 1 --max-time 5 \
  "http://127.0.0.1:$port/" >"$work/root" 2>/dev/null; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 30 ] || fail 'server did not become ready'
  sleep 1
done
jq -e '.msg | contains("github.com/octo-sts/app")' "$work/root" >/dev/null ||
  fail 'root endpoint returned unexpected content'

# exchange OUT [CURL ARGS...]: POST to the token exchange endpoint, print the status.
exchange() {
  out=$1
  shift
  curl --silent --max-time 60 -o "$out" -w '%{http_code}' -X POST "$@" \
    "http://127.0.0.1:$port/sts/exchange?scope=octo-sts/app&identity=ci" ||
    fail "exchange request for $out did not complete"
}

status=$(exchange "$work/no-auth")
[ "$status" = 401 ] || fail "exchange without a token returned $status"
jq -e '.message == "expected exactly one authorization header"' "$work/no-auth" >/dev/null ||
  fail 'unexpected missing-token error'

status=$(exchange "$work/bad-token" -H 'Authorization: Bearer not-a-jwt')
[ "$status" = 400 ] || fail "exchange with a malformed token returned $status"
jq -e '.message == "invalid bearer token"' "$work/bad-token" >/dev/null ||
  fail 'unexpected malformed-token error'

# A well-formed token from an unreachable issuer must be rejected before any
# GitHub call: the service tries OIDC discovery and fails closed.
b64url() { printf '%s' "$1" | base64 | tr -d '\n=' | tr '+/' '-_'; }
header=$(b64url '{"alg":"RS256","typ":"JWT"}')
claims=$(b64url '{"iss":"https://issuer.invalid","sub":"repo:octo-sts/app:ref:refs/heads/main","aud":"octo-sts.test","exp":4102444800,"iat":1700000000}')
status=$(exchange "$work/untrusted" -H "Authorization: Bearer $header.$claims.c2lnbmF0dXJl")
[ "$status" = 400 ] || fail "exchange with an untrusted issuer returned $status"
jq -e '.message == "unable to fetch or create the provider"' "$work/untrusted" >/dev/null ||
  fail 'unexpected untrusted-issuer error'

test "$(docker inspect --format '{{.State.Running}}' "$server")" = true ||
  fail 'server exited during the exchange checks'

echo "octo-sts $expected_version smoke test passed"
