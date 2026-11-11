#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE [FLAVOR]}
here=$(cd "$(dirname "$0")" && pwd)
expected_version=$(sed -n 's/^  version: "\([^"]*\)".*$/\1/p' "$here/../melange.yaml" | head -n 1)
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

name="verity-aspnet-runtime-test-$$"
work=$(mktemp -d)
cleanup() {
  docker rm -f "$name" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM
chmod 755 "$work"

# OCI contract: dotnet entrypoint, non-root user, container-aware environment, port 8080.
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/dotnet"]' ] || fail 'unexpected entrypoint'
user=$(docker image inspect -f '{{.Config.User}}' "$image")
case "$user" in
  ''|0|root|0:*|root:*) fail "image runs as root: '$user'" ;;
esac
env=$(docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$image")
printf '%s\n' "$env" | grep -qx 'DOTNET_ROOT=/usr/share/dotnet' || fail 'DOTNET_ROOT is not set'
printf '%s\n' "$env" | grep -qx 'DOTNET_RUNNING_IN_CONTAINER=true' || fail 'DOTNET_RUNNING_IN_CONTAINER is not set'
printf '%s\n' "$env" | grep -qx 'ASPNETCORE_URLS=http://+:8080' || fail 'ASPNETCORE_URLS is not http://+:8080'

# Both shared frameworks are present, and no SDK.
runtimes=$(docker run --rm "$image" --list-runtimes)
printf '%s\n' "$runtimes" | grep -qx "Microsoft.AspNetCore.App $expected_version \[/usr/share/dotnet/shared/Microsoft.AspNetCore.App\]" ||
  fail "AspNetCore.App $expected_version missing: $runtimes"
printf '%s\n' "$runtimes" | grep -qx "Microsoft.NETCore.App $expected_version \[/usr/share/dotnet/shared/Microsoft.NETCore.App\]" ||
  fail "NETCore.App $expected_version missing: $runtimes"
[ "$(printf '%s\n' "$runtimes" | wc -l)" = 2 ] || fail "unexpected runtimes: $runtimes"
if docker run --rm "$image" --list-sdks 2>&1 | grep -q '^[0-9]'; then fail 'an SDK is installed'; fi

# web.dll is a framework-dependent minimal API (built against net10.0; it runs on the 11 runtime through the net11.0 runtimeconfig), committed as base64 text so the test needs no SDK.
# Regenerate: dotnet publish tests/fixture -c Release -o out && base64 -w0 out/web.dll > web.dll.b64
# and copy out/web.runtimeconfig.json next to it.
base64 -d "$here/web.dll.b64" > "$work/web.dll"
cp "$here/web.runtimeconfig.json" "$work/web.runtimeconfig.json"
chmod 644 "$work/web.dll" "$work/web.runtimeconfig.json"

# Negative: a missing assembly fails and the failure reaches the caller.
status=0
docker run --rm "$image" /work/missing.dll >/dev/null 2>&1 || status=$?
[ "$status" != 0 ] || fail 'a missing assembly exited 0'

# Negative: an app that needs a framework version this image does not carry must not start.
mkdir "$work/future"
chmod 755 "$work/future"
cp "$work/web.dll" "$work/future/web.dll"
cat > "$work/future/web.runtimeconfig.json" <<EOF
{"runtimeOptions":{"tfm":"net99.0","frameworks":[{"name":"Microsoft.NETCore.App","version":"99.0.0"},{"name":"Microsoft.AspNetCore.App","version":"99.0.0"}]}}
EOF
status=0
docker run --rm -v "$work/future:/work:ro" "$image" /work/web.dll >/dev/null 2>&1 || status=$?
[ "$status" != 0 ] || fail 'an app requiring a missing framework version started'

# Serve on the default port with the default ASPNETCORE_URLS.
docker run -d --name "$name" --label verity.test=aspnet-runtime -p 127.0.0.1::8080 -v "$work:/work:ro" "$image" /work/web.dll >/dev/null ||
  fail 'container did not start'
port=$(docker port "$name" 8080/tcp | sed -n 's/^127\.0\.0\.1:\([0-9]*\)$/\1/p' | head -n 1)
[ -n "$port" ] || fail 'published port not found'

body=''
i=0
while [ "$i" -lt 90 ]; do
  body=$(curl -fsS --max-time 3 "http://127.0.0.1:$port/" 2>/dev/null) && break
  [ "$(docker inspect -f '{{.State.Running}}' "$name")" = true ] || fail "container exited: $(docker logs "$name" 2>&1 | tail -n 20)"
  i=$((i + 1))
  sleep 1
done
[ "$body" = 'hello from verity aspnet' ] || fail "GET / returned '$body'; logs: $(docker logs "$name" 2>&1 | tail -n 20)"

urls=$(curl -fsS --max-time 5 "http://127.0.0.1:$port/urls") || fail 'GET /urls failed'
[ "$urls" = 'http://+:8080' ] || fail "ASPNETCORE_URLS inside the app is '$urls'"
json=$(curl -fsS --max-time 5 "http://127.0.0.1:$port/json") || fail 'GET /json failed'
printf '%s\n' "$json" | grep -q '"framework":".NET 11\.' || fail "unexpected /json body: $json"

# Negative: an unknown route is a 404, not a crash.
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$port/does-not-exist")
[ "$code" = 404 ] || fail "unknown route returned $code"
[ "$(docker inspect -f '{{.State.Running}}' "$name")" = true ] || fail 'container stopped after requests'
