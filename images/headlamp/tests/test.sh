#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(cd "$(dirname "$0")" && pwd)
container="verity-headlamp-test-$$"
tmp=$(mktemp -d)

fail() {
  docker logs "$container" >&2 2>&1 || true
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

version=$(sed -n 's/^  version: "\([^"]*\)".*/\1/p' "$here/../melange.yaml")
[ -n "$version" ] || fail 'could not read package.version from melange.yaml'

# OCI contract mirrors the upstream image: uid 100 / gid 101 from the Helm
# chart, the server entrypoint with the static frontend and plugin dirs, and
# the static plugins directory variable.
[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 100 ] \
  || fail 'image user is not 100'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/headlamp/headlamp-server","-html-static-dir","/headlamp/frontend","-plugins-dir","/headlamp/plugins"]' ] \
  || fail 'unexpected image entrypoint'
[ "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /headlamp ] \
  || fail 'unexpected working directory'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" \
  | grep -Fx 'HEADLAMP_STATIC_PLUGINS_DIR=/headlamp/static-plugins' >/dev/null \
  || fail 'HEADLAMP_STATIC_PLUGINS_DIR is not set to /headlamp/static-plugins'

out=$(docker run --rm "$image" -version 2>&1) || fail "-version exited non-zero: $out"
printf '%s\n' "$out" | grep -Ex "Headlamp $version \\(linux/(amd64|arm64)\\)" >/dev/null \
  || fail "unexpected -version output: $out"

# Negative case: an unknown flag must be rejected with a readable error.
if docker run --rm "$image" -no-such-flag >"$tmp/badflag.log" 2>&1; then
  fail 'headlamp-server accepted an unknown flag'
fi
grep -F 'flag provided but not defined: -no-such-flag' "$tmp/badflag.log" >/dev/null \
  || { cat "$tmp/badflag.log" >&2; fail 'unknown flag error was not readable'; }

# A dummy kubeconfig pointing at an unreachable API server; Headlamp only
# needs to parse it to list the cluster.
mkdir -p "$tmp/kube" "$tmp/plugins/verity-smoke"
cat >"$tmp/kube/config" <<'YAML'
apiVersion: v1
kind: Config
clusters:
  - name: verity-smoke
    cluster:
      server: https://127.0.0.1:6443
      insecure-skip-tls-verify: true
contexts:
  - name: verity-smoke
    context:
      cluster: verity-smoke
      user: verity-smoke
current-context: verity-smoke
users:
  - name: verity-smoke
    user:
      token: dummy
YAML
printf '{"name":"verity-smoke","version":"0.0.1"}\n' >"$tmp/plugins/verity-smoke/package.json"
printf 'console.log("verity-smoke");\n' >"$tmp/plugins/verity-smoke/main.js"
chmod -R a+rX "$tmp/kube" "$tmp/plugins"

docker run --name "$container" -d --read-only \
  --tmpfs /tmp:uid=100,gid=101,mode=1777 \
  --tmpfs /home/headlamp:uid=100,gid=101,mode=0755 \
  -v "$tmp/kube:/kube:ro" \
  -v "$tmp/plugins:/headlamp/plugins:ro" \
  -p 127.0.0.1::4466 \
  "$image" \
  -in-cluster=false -kubeconfig /kube/config >/dev/null
port=$(docker port "$container" 4466/tcp | awk -F: 'NR == 1 { print $2 }')
[ -n "$port" ] || fail 'port 4466 was not published'
base="http://127.0.0.1:$port"

attempt=0
until curl --fail --silent --connect-timeout 1 --max-time 5 -o /dev/null "$base/"; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 60 ] || fail 'headlamp did not serve / on 4466 within 60s'
  [ "$(docker inspect --format '{{.State.Running}}' "$container")" = true ] \
    || fail 'headlamp exited before becoming ready'
  sleep 1
done

# index.html is the built frontend with the server-side base URL rewrite.
curl --fail --silent --max-time 5 "$base/" >"$tmp/index.html" || fail 'GET / failed'
grep -F 'Headlamp: Kubernetes Web UI' "$tmp/index.html" >/dev/null \
  || fail 'index.html is not the Headlamp frontend'
grep -F "headlampBaseUrl = '/'" "$tmp/index.html" >/dev/null \
  || fail 'index.html base URL was not rewritten by the server'
grep -F '<div id="root">' "$tmp/index.html" >/dev/null \
  || fail 'index.html has no React root element'

# The frontend bundle referenced by index.html is served, with the
# precompressed brotli sidecar when the client accepts it.
asset=$(grep -o 'src="[^"]*\.js"' "$tmp/index.html" | sed 's/^src="//; s/"$//; s#^\./#/#; s#^\([^/]\)#/\1#' | head -n 1)
[ -n "$asset" ] || fail 'index.html references no script bundle'
curl --fail --silent --max-time 5 -o /dev/null "$base$asset" || fail "script bundle $asset was not served"
curl --fail --silent --max-time 5 -o /dev/null -D "$tmp/asset.headers" -H 'Accept-Encoding: br' "$base$asset" \
  || fail "brotli request for $asset failed"
grep -i '^content-encoding: br' "$tmp/asset.headers" >/dev/null \
  || { cat "$tmp/asset.headers" >&2; fail "$asset was not served from its brotli sidecar"; }

# /config lists the kubeconfig context.
curl --fail --silent --max-time 5 "$base/config" >"$tmp/config.json" || fail 'GET /config failed'
jq -e '.clusters | type == "array"' "$tmp/config.json" >/dev/null \
  || { cat "$tmp/config.json" >&2; fail '/config is not JSON with a clusters array'; }
jq -e '[.clusters[] | select(.name == "verity-smoke" and .server == "https://127.0.0.1:6443")] | length == 1' \
  "$tmp/config.json" >/dev/null \
  || { cat "$tmp/config.json" >&2; fail '/config does not list the verity-smoke kubeconfig cluster'; }

# Plugins in /headlamp/plugins are listed and served.
curl --fail --silent --max-time 5 "$base/plugins" >"$tmp/plugins.json" || fail 'GET /plugins failed'
jq -e '[.[] | select(.name == "verity-smoke" and .path == "plugins/verity-smoke")] | length == 1' \
  "$tmp/plugins.json" >/dev/null \
  || { cat "$tmp/plugins.json" >&2; fail '/plugins does not list the mounted plugin'; }
curl --fail --silent --max-time 5 "$base/plugins/verity-smoke/main.js" | grep -F 'verity-smoke' >/dev/null \
  || fail 'mounted plugin main.js was not served'

# Negative case: the API proxy must refuse a cluster that is not in the
# kubeconfig.
code=$(curl --silent --max-time 5 -o /dev/null -w '%{http_code}' "$base/clusters/no-such-cluster/version")
[ "$code" = 404 ] || fail "request for an unknown cluster returned $code, want 404"

# SIGTERM must stop the server cleanly.
docker stop --timeout 30 "$container" >/dev/null
[ "$(docker inspect --format '{{.State.ExitCode}}' "$container")" = 0 ] \
  || fail 'headlamp did not exit cleanly on SIGTERM'
docker logs "$container" 2>&1 | grep -F 'Received shutdown signal' >/dev/null \
  || fail 'headlamp did not log its SIGTERM shutdown'

printf 'headlamp %s smoke test passed\n' "$version"
