#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
work=$(mktemp -d)
recipe_dir=$(dirname "$0")/..
recipe="$recipe_dir/melange.yaml"
version=$(sed -n 's/^  version: "\([^"]*\)".*$/\1/p' "$recipe")
commit=$(sed -n 's/^  source-commit: \([0-9a-f]\{40\}\)$/\1/p' "$recipe")
test -n "$version" && test -n "$commit"

cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

# Upstream docker/webhook.Dockerfile: WORKDIR /, USER 65532:65532, ENTRYPOINT ["/manager"].
user=$(docker image inspect --format '{{.Config.User}}' "$image")
case "$user" in
  65532 | 65532:65532) ;;
  *) fail "unexpected OCI user: $user" ;;
esac
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/manager"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = / ||
  fail 'unexpected working directory'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" |
  grep -Fx 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' >/dev/null ||
  fail 'CA bundle environment is missing'

docker run --rm --network none --read-only "$image" --version >"$work/version" 2>&1
grep -F "\"buildVersion\":\"v${version}\"" "$work/version" >/dev/null ||
  fail 'version output is missing build version'
grep -F "\"gitCommit\":\"${commit}\"" "$work/version" >/dev/null ||
  fail 'version output is missing git commit'

if docker run --rm --network none --read-only "$image" --definitely-invalid \
  >"$work/invalid" 2>&1; then
  fail 'invalid argument unexpectedly succeeded'
fi
grep -F 'flag provided but not defined: -definitely-invalid' "$work/invalid" >/dev/null ||
  fail 'invalid argument diagnostic is missing'

if docker run --rm --network none --read-only "$image" --log-level=bogus \
  >"$work/loglevel" 2>&1; then
  fail 'invalid log level unexpectedly succeeded'
fi
grep -F 'invalid --log-level set' "$work/loglevel" >/dev/null ||
  fail 'invalid log level diagnostic is missing'

# Offline startup: point the webhook at an unreachable API server with a
# pre-provisioned self-signed serving cert. It must reach the TLS option
# parsing stage and reject an invalid minimum TLS version before any network.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost \
  -keyout "$work/tls.key" -out "$work/tls.crt" >/dev/null 2>&1 ||
  fail 'unable to generate self-signed certificate'
chmod 0644 "$work/tls.key" "$work/tls.crt"
cat >"$work/kubeconfig" <<'KUBECONFIG'
apiVersion: v1
kind: Config
clusters:
  - name: offline
    cluster:
      server: https://127.0.0.1:1
      insecure-skip-tls-verify: true
contexts:
  - name: offline
    context:
      cluster: offline
      user: offline
current-context: offline
users:
  - name: offline
    user:
      token: placeholder
KUBECONFIG
chmod 0644 "$work/kubeconfig"
chmod 0755 "$work"

run_offline() {
  timeout 120 docker run --rm --network none --read-only \
    -v "$work:/config:ro" -e KUBECONFIG=/config/kubeconfig "$@"
}

if run_offline "$image" --webhook-cert-dir=/config --disable-cert-rotation \
  --tls-min-version=9.9 >"$work/tls" 2>&1; then
  fail 'invalid TLS version unexpectedly succeeded'
fi
grep -F 'invalid TLS version. Must be one of: 1.0, 1.1, 1.2, 1.3' "$work/tls" >/dev/null ||
  fail 'invalid TLS version diagnostic is missing'

if run_offline "$image" --webhook-cert-dir=/config --disable-cert-rotation \
  >"$work/notenant" 2>&1; then
  fail 'startup without AZURE_TENANT_ID unexpectedly succeeded'
fi
grep -F 'required key AZURE_TENANT_ID missing value' "$work/notenant" >/dev/null ||
  fail 'missing tenant diagnostic is missing'

# With tenant config and the mounted self-signed serving cert, the webhook
# loads the cert, serves on :9443, then fails predictably on the unreachable
# API server version check.
if run_offline -e AZURE_TENANT_ID=00000000-0000-0000-0000-000000000000 "$image" \
  --webhook-cert-dir=/config --disable-cert-rotation --log-level=debug \
  >"$work/startup" 2>&1; then
  fail 'offline startup unexpectedly succeeded'
fi
grep -F "\"userAgent\":\"azure-workload-identity/webhook/v${version} (linux/" "$work/startup" |
  grep -F "${commit}/" >/dev/null || fail 'startup user agent with version is missing'
grep -F '"message":"Serving webhook server"' "$work/startup" | grep -F '"port":9443' \
  >/dev/null || fail 'webhook server did not start with the mounted certificate'
grep -F '"message":"starting server","name":"health probe","addr":"[::]:9440"' \
  "$work/startup" >/dev/null || fail 'health probe server did not start'
grep -F 'failed to check kubernetes version' "$work/startup" | grep -F '127.0.0.1:1' \
  >/dev/null || fail 'unreachable API server diagnostic is missing'

printf 'SMOKE PASS image=%s\n' "$image"
