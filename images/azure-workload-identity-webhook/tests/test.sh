#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
work=$(mktemp -d)
recipe_dir=$(dirname "$0")/..
recipe="$recipe_dir/melange.yaml"
version=$(sed -n 's/^  version: "\([^"]*\)".*$/\1/p' "$recipe")
commit=$(sed -n 's/^  source-commit: \([0-9a-f]\{40\}\)$/\1/p' "$recipe")
test -n "$version" && test -n "$commit"
helper_index=docker.io/library/busybox:1.37.0@sha256:9db7b59979c38555a39def84a31fb98b5296952f9e3afd4f6f11f05b07adfab0

holder=
webhook=

cleanup() {
  [ -z "$webhook" ] || docker rm -f "$webhook" >/dev/null 2>&1 || true
  [ -z "$holder" ] || docker rm -f "$holder" >/dev/null 2>&1 || true
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

# A classic Docker image store cannot bind the index digest to a second
# platform's image, so pull the helper by its own per-platform child digest.
# The index bytes are verified against the pinned digest before a child is
# chosen, which keeps the pin authoritative.
image_arch=$(docker image inspect -f '{{.Architecture}}' "$image")
helper_raw=$(docker buildx imagetools inspect --raw "$helper_index") ||
  fail 'cannot inspect helper image index'
[ "sha256:$(printf '%s' "$helper_raw" | sha256sum | cut -d' ' -f1)" = "${helper_index#*@}" ] ||
  fail 'helper image index digest mismatch'
helper_digest=$(printf '%s' "$helper_raw" |
  jq -r --arg arch "$image_arch" '
    [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
    | if length == 1 then .[0] else empty end') ||
  fail 'cannot resolve helper image digest'
case $helper_digest in
  sha256:*) ;;
  *) fail "no unique linux/$image_arch helper image in $helper_index" ;;
esac
helper=docker.io/library/busybox@$helper_digest
docker pull --quiet --platform "linux/$image_arch" "$helper" >/dev/null ||
  fail 'cannot pull helper image'

# Deterministic offline serving check. A pinned busybox holder owns an
# isolated network namespace (no external network) and accepts API server
# connections on 127.0.0.1:6443 without replying, so the webhook's Kubernetes
# version check blocks instead of racing server start-up.
holder=$(docker run -d --network none "$helper" \
  sh -c 'while true; do nc -l -p 6443 >/dev/null; done')
sed 's|https://127.0.0.1:1|https://127.0.0.1:6443|' "$work/kubeconfig" >"$work/kubeconfig-hold"
chmod 0644 "$work/kubeconfig-hold"
webhook=$(docker run -d --network "container:$holder" --read-only \
  -v "$work:/config:ro" -e KUBECONFIG=/config/kubeconfig-hold \
  -e AZURE_TENANT_ID=00000000-0000-0000-0000-000000000000 "$image" \
  --webhook-cert-dir=/config --disable-cert-rotation --log-level=debug)

probe() {
  docker run --rm --network "container:$holder" "$helper" "$@"
}
ready=
for _ in $(seq 1 90); do
  if probe wget -qO- http://127.0.0.1:9440/healthz >"$work/healthz" 2>/dev/null; then
    ready=1
    break
  fi
  sleep 1
done
test -n "$ready" || { docker logs "$webhook" >&2 || true; fail 'healthz never became ready'; }
grep -Fx ok "$work/healthz" >/dev/null || fail 'unexpected healthz body'
probe wget -qO- http://127.0.0.1:9440/readyz | grep -Fx ok >/dev/null ||
  fail 'readyz is not ok'
# The webhook serves TLS on 9443 with the mounted self-signed certificate.
probe sh -c 'echo | nc -w 3 127.0.0.1 9443 >/dev/null' ||
  fail 'webhook TLS port 9443 is not listening'
probe wget -qO- http://127.0.0.1:8095/metrics | grep -F '# TYPE' >/dev/null ||
  fail 'metrics endpoint is not serving'

docker logs "$webhook" >"$work/startup" 2>&1
grep -F "\"userAgent\":\"azure-workload-identity/webhook/v${version} (linux/" "$work/startup" |
  grep -F "${commit}/" >/dev/null || fail 'startup user agent with version is missing'
grep -F '"message":"Serving webhook server"' "$work/startup" | grep -F '"port":9443' \
  >/dev/null || fail 'webhook server did not start with the mounted certificate'

printf 'SMOKE PASS image=%s\n' "$image"
