#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-ohif-viewer-test-$$"
negative="$container-negative"
work=$(mktemp -d)
fail() {
  printf '%s\n' "$1" >&2
  docker logs "$container" 2>&1 | tail -n 40 >&2 || true
  exit 1
}
cleanup() {
  docker rm -f "$container" "$negative" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

recipe_version=$(sed -n 's/^  version: "\([^"]*\)".*$/\1/p' "$(dirname "$0")/../melange.yaml")
[ -n "$recipe_version" ] || fail 'OHIF Viewer package version is missing'

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/nginx"]' ] ||
  fail 'unexpected OCI entrypoint'
[ "$(docker image inspect -f '{{json .Config.Cmd}}' "$image")" = '["-c","/etc/ohif-viewer/nginx.conf","-e","stderr"]' ] ||
  fail 'unexpected OCI command'
[ "$(docker image inspect -f '{{.Config.StopSignal}}' "$image")" = SIGQUIT ] || fail 'unexpected OCI stop signal'
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = /usr/share/ohif-viewer ] ||
  fail 'unexpected OCI working directory'
docker run --rm --network none --entrypoint /bin/sh "$image" -c true >/dev/null 2>&1 &&
  fail 'image unexpectedly ships a shell'

# Negative: an invalid nginx configuration stops the server with a readable error.
printf 'events {}\nhttp { server { listen 8080; bogus_directive on; } }\n' > "$work/invalid.conf"
docker run --name "$negative" -d --network none -v "$work/invalid.conf:/etc/ohif-viewer/nginx.conf:ro" \
  "$image" >/dev/null
negative_code=$(timeout 60 docker wait "$negative") || fail 'invalid configuration did not stop nginx'
[ "$negative_code" != 0 ] || fail 'invalid configuration unexpectedly succeeded'
docker logs "$negative" 2>&1 | grep -q 'unknown directive "bogus_directive"' ||
  fail 'invalid configuration failure was not readable'

# The root filesystem stays read-only and every capability is dropped: nginx writes
# only its pid and temporary files under /tmp. A site configuration is mounted over
# app-config.js, the upstream deployment contract.
printf 'window.config = { name: "verity-smoke-%s", routerBasename: null, extensions: [], modes: [], dataSources: [] };\n' \
  "$$" > "$work/app-config.js"
docker run --name "$container" -d --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges \
  -v "$work/app-config.js:/usr/share/ohif-viewer/app-config.js:ro" -p 127.0.0.1::8080 "$image" >/dev/null
port=$(docker port "$container" 8080/tcp | awk -F: 'NR == 1 { print $2 }')
[ -n "$port" ] || fail 'published port is missing'
base="http://127.0.0.1:$port"

headers="$work/headers"
body="$work/body"
fetch() {
  curl -s --connect-timeout 2 --max-time 30 -o "$body" -D "$headers" -w '%{http_code}' "$base$1" || true
}
header() {
  tr -d '\r' < "$headers" | awk -v name="$1" 'tolower($1) == tolower(name ":") { $1 = ""; sub(/^ /, ""); print; exit }'
}

ready=false
for _ in $(seq 1 60); do
  if [ "$(fetch /)" = 200 ]; then
    ready=true
    break
  fi
  sleep 1
done
[ "$ready" = true ] || fail 'OHIF Viewer did not become ready'

grep -Fq '<title>OHIF Viewer</title>' "$body" || fail 'index.html does not carry the OHIF Viewer title'
grep -Fq '<div id="root">' "$body" || fail 'index.html does not carry the app root element'
grep -Fq 'src="/app-config.js"' "$body" || fail 'index.html does not load app-config.js'
case "$(header Content-Type)" in
  text/html*) ;;
  *) fail "unexpected index.html content type: $(header Content-Type)" ;;
esac
[ "$(header Server)" = nginx ] || fail "Server header discloses a version: $(header Server)"
[ "$(header Cross-Origin-Resource-Policy)" = same-origin ] || fail 'Cross-Origin-Resource-Policy header is missing'

bundle=$(grep -o 'src="/app\.bundle\.[0-9a-f]*\.js"' "$body" | head -n 1 | sed 's/^src="//; s/"$//')
[ -n "$bundle" ] || fail 'index.html does not reference the application bundle'
[ "$(fetch "$bundle")" = 200 ] || fail "application bundle $bundle is not served"
case "$(header Content-Type)" in
  application/javascript* | text/javascript*) ;;
  *) fail "unexpected bundle content type: $(header Content-Type)" ;;
esac
[ "$(wc -c < "$body")" -gt 1000000 ] || fail 'application bundle is truncated'

[ "$(fetch /app-config.js)" = 200 ] || fail 'app-config.js is not served'
grep -Fq "verity-smoke-$$" "$body" || fail 'mounted app-config.js is not served'

[ "$(curl -s -o /dev/null -w '%{http_code}' -H 'Accept-Encoding: gzip' -D "$headers" "$base$bundle")" = 200 ] ||
  fail 'gzip request for the application bundle failed'
[ "$(header Content-Encoding)" = gzip ] || fail 'application bundle is not gzip encoded on request'
[ "$(header Vary)" = Accept-Encoding ] || fail 'compressed response does not send Vary: Accept-Encoding'

wasm=$(docker cp "$container:/usr/share/ohif-viewer" - | tar -t | grep -m 1 '^ohif-viewer/[0-9a-f]*\.wasm$' || true)
[ -n "$wasm" ] || fail 'the build ships no WebAssembly module'
[ "$(fetch "/${wasm#ohif-viewer/}")" = 200 ] || fail "WebAssembly module $wasm is not served"
[ "$(header Content-Type)" = application/wasm ] || fail "unexpected WebAssembly content type: $(header Content-Type)"

# Client-side routes, including a dotted DICOM UID path segment, load the app shell.
for route in '/viewer?StudyInstanceUIDs=1.2.840.113619.2.5' /segmentation /viewer/1.2.840.113619.2.5; do
  [ "$(fetch "$route")" = 200 ] || fail "client-side route $route did not load the app shell"
  grep -Fq '<title>OHIF Viewer</title>' "$body" || fail "client-side route $route did not return index.html"
done

# Negative: a missing static asset is a 404, never the app shell.
for missing in /missing.bundle.js /missing.wasm /assets/missing.png; do
  [ "$(fetch "$missing")" = 404 ] || fail "missing asset $missing did not return 404"
  if grep -Fq '<title>OHIF Viewer</title>' "$body"; then
    fail "missing asset $missing returned the app shell"
  fi
done

# The server runs as the image user, not root.
uids=$(docker top "$container" -eo pid,uid,comm | awk 'NR > 1 { print $2 }' | sort -u)
[ "$uids" = 65532 ] || fail "nginx processes run as unexpected uids: $uids"

docker stop -t 30 "$container" >/dev/null
code=$(docker inspect -f '{{.State.ExitCode}}' "$container")
[ "$code" = 0 ] || fail "unexpected exit code $code after graceful stop"
docker logs "$container" 2>&1 | grep -q 'gracefully shutting down' || fail 'nginx did not shut down gracefully'

printf 'passed ohif-viewer %s smoke test\n' "$recipe_version"
