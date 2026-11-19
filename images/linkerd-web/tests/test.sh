#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
recipe="$(dirname "$0")/../melange.yaml"
container="verity-linkerd-web-test-$$"
copy="verity-linkerd-web-copy-$$"
tmp=$(mktemp -d)

fail() {
  docker logs "$container" >&2 2>&1 || true
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker rm -f "$copy" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

version=$(sed -n 's/^  version: "\([^"]*\)".*$/\1/p' "$recipe")
[ -n "$version" ] || fail 'could not read package.version from melange.yaml'
expected="edge-$version"

# OCI contract mirrors cr.l5d.io/linkerd/web, with the linkerd-viz chart's
# default 2103:2103 identity instead of root.
[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 2103:2103 ] \
  || fail 'image user is not 2103:2103'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["./web"]' ] \
  || fail 'image entrypoint is not ["./web"]'
[ "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /linkerd ] \
  || fail 'working directory is not /linkerd'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" \
  | grep -Fx "LINKERD_CONTAINER_VERSION_OVERRIDE=$expected" >/dev/null \
  || fail "LINKERD_CONTAINER_VERSION_OVERRIDE is not $expected"

# The binary links no version; it must report the one bound by the image.
reported=$(docker run --rm "$image" -version) || fail 'web -version failed'
[ "$reported" = "$expected" ] || fail "web -version reported '$reported', expected '$expected'"

# Upstream layout: binary, LICENSE, built assets and templates under /linkerd,
# CA bundle in place, and no node_modules shipped.
docker create --name "$copy" "$image" >/dev/null
docker export "$copy" | tar -tf - | sed 's|^\./||; s|/$||' >"$tmp/files"
for path in linkerd/web linkerd/LICENSE linkerd/app/dist/index_bundle.js \
  linkerd/templates/app.tmpl.html linkerd/templates/includes/base.tmpl.html \
  etc/ssl/certs/ca-certificates.crt; do
  grep -Fx "$path" "$tmp/files" >/dev/null || fail "missing /$path"
done
if grep -F node_modules "$tmp/files" >/dev/null; then
  fail 'image ships node_modules'
fi
docker cp "$copy:/linkerd/LICENSE" "$tmp/LICENSE"
grep -F 'Apache License' "$tmp/LICENSE" >/dev/null || fail '/linkerd/LICENSE is not the Apache license'

# Negative: an undefined flag is rejected by the flag set.
if docker run --rm "$image" -no-such-flag >"$tmp/flag.log" 2>&1; then
  fail 'web accepted an undefined flag'
fi
grep -F 'flag provided but not defined: -no-such-flag' "$tmp/flag.log" >/dev/null \
  || { cat "$tmp/flag.log" >&2; fail 'undefined flag error was not readable'; }

# Negative: a metrics-api address without a port is rejected before startup.
if docker run --rm "$image" -linkerd-metrics-api-addr=metrics-api >"$tmp/addr.log" 2>&1; then
  fail 'web accepted a metrics-api address without a port'
fi
grep -F 'failed to parse metrics API server address: metrics-api' "$tmp/addr.log" >/dev/null \
  || { cat "$tmp/addr.log" >&2; fail 'invalid metrics-api address error was not readable'; }

# Negative: outside a cluster and without a kubeconfig the server cannot build
# its Kubernetes client and must exit instead of serving.
if docker run --rm "$image" >"$tmp/nocluster.log" 2>&1; then
  fail 'web started without any Kubernetes configuration'
fi
grep -F 'failed to construct Kubernetes API client' "$tmp/nocluster.log" >/dev/null \
  || { cat "$tmp/nocluster.log" >&2; fail 'missing Kubernetes configuration error was not readable'; }

# A kubeconfig that points at a closed local port lets the server start with no
# cluster: the linkerd-config lookup fails and is logged, and the metrics-api
# address is unreachable, so only API routes that need them fail.
cat >"$tmp/kubeconfig" <<'YAML'
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
      token: offline
YAML
chmod 644 "$tmp/kubeconfig"

docker run --name "$container" -d --read-only \
  -v "$tmp/kubeconfig:/etc/linkerd-web/kubeconfig:ro" \
  -p 127.0.0.1::8084 -p 127.0.0.1::9994 \
  "$image" \
  -kubeconfig=/etc/linkerd-web/kubeconfig \
  -linkerd-metrics-api-addr=127.0.0.1:1 \
  -cluster-domain=cluster.local \
  '-enforced-host=^(localhost|127\.0\.0\.1)(:[0-9]+)?$' >/dev/null
web_port=$(docker port "$container" 8084/tcp | awk -F: 'NR == 1 { print $NF }')
admin_port=$(docker port "$container" 9994/tcp | awk -F: 'NR == 1 { print $NF }')
[ -n "$web_port" ] || fail 'dashboard port 8084 was not published'
[ -n "$admin_port" ] || fail 'admin port 9994 was not published'
base="http://127.0.0.1:$web_port"
admin="http://127.0.0.1:$admin_port"

attempt=0
until [ "$(curl --silent --max-time 2 "$admin/ready" 2>/dev/null)" = ok ]; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 60 ] || fail 'admin /ready never reported ok'
  [ "$(docker inspect --format '{{.State.Running}}' "$container")" = true ] \
    || fail 'web exited before becoming ready'
  sleep 1
done
attempt=0
until curl --fail --silent --max-time 2 -o /dev/null "$base/"; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 30 ] || fail 'dashboard HTTP server never answered'
  sleep 1
done

[ "$(curl --fail --silent --max-time 5 "$admin/ping")" = pong ] || fail 'admin /ping did not answer pong'
curl --fail --silent --max-time 5 "$admin/metrics" | grep -E '^go_goroutines [0-9]+' >/dev/null \
  || fail 'admin /metrics did not expose Prometheus metrics'
docker logs "$container" 2>&1 | grep -F "running version $expected" >/dev/null \
  || fail "startup log did not report version $expected"

# Dashboard HTML rendered from /linkerd/templates.
curl --fail --silent --max-time 5 -D "$tmp/index.headers" -o "$tmp/index.html" "$base/namespaces" \
  || fail 'dashboard index request failed'
grep -F '<title>Linkerd</title>' "$tmp/index.html" >/dev/null || fail 'index HTML has no Linkerd title'
grep -F 'data-controller-namespace="linkerd"' "$tmp/index.html" >/dev/null \
  || fail 'index HTML did not render the app template'
grep -F 'src="/dist/index_bundle.js"' "$tmp/index.html" >/dev/null \
  || fail 'index HTML does not load /dist/index_bundle.js'
grep -i '^x-frame-options: SAMEORIGIN' "$tmp/index.headers" >/dev/null \
  || fail 'index response lacks X-Frame-Options'

# Bundled JS from /linkerd/app/dist: the loader names a hashed main chunk.
curl --fail --silent --max-time 5 -o "$tmp/index_bundle.js" "$base/dist/index_bundle.js" \
  || fail '/dist/index_bundle.js request failed'
chunk=$(grep -oE 'main\.[0-9a-f]+\.js' "$tmp/index_bundle.js" | head -n 1)
[ -n "$chunk" ] || fail 'index_bundle.js does not reference a hashed main chunk'
curl --fail --silent --max-time 10 -D "$tmp/chunk.headers" -o "$tmp/main.js" "$base/dist/$chunk" \
  || fail "/dist/$chunk request failed"
grep -i '^content-type: text/javascript' "$tmp/chunk.headers" >/dev/null \
  || grep -i '^content-type: application/javascript' "$tmp/chunk.headers" >/dev/null \
  || fail "/dist/$chunk is not served as JavaScript"
size=$(wc -c <"$tmp/main.js")
[ "$size" -gt 100000 ] || fail "/dist/$chunk is only $size bytes"
grep -F 'linkerd' "$tmp/main.js" >/dev/null || fail "/dist/$chunk does not contain the dashboard code"

# Negative: a missing asset is 404, and the files-only asset directory does not
# list its entries.
code=$(curl --silent --max-time 5 -o /dev/null -w '%{http_code}' "$base/dist/no-such-asset.js")
[ "$code" = 404 ] || fail "missing asset returned $code, expected 404"
curl --fail --silent --max-time 5 -o "$tmp/listing.html" "$base/dist/" \
  || fail '/dist/ request failed'
if grep -E 'index_bundle|main\.|img' "$tmp/listing.html" >/dev/null; then
  fail '/dist/ lists asset directory entries'
fi

# Negative: an API route that needs the unreachable metrics-api reports the
# gRPC failure as a JSON error instead of hanging or succeeding.
code=$(curl --silent --max-time 30 -o "$tmp/stat.json" -w '%{http_code}' \
  "$base/api/tps-reports?resource_type=deployment&namespace=default")
[ "$code" = 500 ] || { cat "$tmp/stat.json" >&2; fail "unreachable metrics-api returned $code, expected 500"; }
grep -F '"error":"rpc error: code = Unavailable' "$tmp/stat.json" >/dev/null \
  || { cat "$tmp/stat.json" >&2; fail 'unreachable metrics-api error was not reported'; }

# Negative: --enforced-host rejects a foreign Host header (DNS rebinding).
code=$(curl --silent --max-time 5 -o "$tmp/rebind.txt" -w '%{http_code}' \
  -H 'Host: attacker.example' "$base/")
[ "$code" = 400 ] || fail "foreign Host header returned $code, expected 400"
grep -F 'linkerd.io/dns-rebinding' "$tmp/rebind.txt" >/dev/null \
  || fail 'foreign Host rejection did not explain DNS rebinding'

# SIGTERM shuts the servers down cleanly.
docker stop --time 15 "$container" >/dev/null
[ "$(docker inspect --format '{{.State.ExitCode}}' "$container")" = 0 ] \
  || fail 'web did not exit 0 on SIGTERM'
docker logs "$container" 2>&1 | grep -F 'shutting down HTTP server' >/dev/null \
  || fail 'web did not log a graceful shutdown'

printf 'linkerd-web %s smoke test passed\n' "$expected"
