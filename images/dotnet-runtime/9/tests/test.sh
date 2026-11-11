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

# OCI contract: dotnet entrypoint, non-root user, container-aware environment.
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/dotnet"]' ] || fail 'unexpected entrypoint'
user=$(docker image inspect -f '{{.Config.User}}' "$image")
case "$user" in
  ''|0|root|0:*|root:*) fail "image runs as root: '$user'" ;;
esac
env=$(docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$image")
printf '%s\n' "$env" | grep -qx 'DOTNET_ROOT=/usr/share/dotnet' || fail 'DOTNET_ROOT is not set'
printf '%s\n' "$env" | grep -qx 'DOTNET_RUNNING_IN_CONTAINER=true' || fail 'DOTNET_RUNNING_IN_CONTAINER is not set'
printf '%s\n' "$env" | grep -q '^DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=' && fail 'invariant globalization must stay off while ICU is installed'

# The image carries the shared runtime only: no SDK, no ASP.NET Core framework.
runtimes=$(docker run --rm "$image" --list-runtimes)
[ "$runtimes" = "Microsoft.NETCore.App $expected_version [/usr/share/dotnet/shared/Microsoft.NETCore.App]" ] ||
  fail "unexpected runtimes: $runtimes"
if docker run --rm "$image" --list-sdks 2>&1 | grep -q '^[0-9]'; then fail 'an SDK is installed'; fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
chmod 755 "$work"
# hello.dll is a framework-dependent console app (net9.0), committed as base64 text so the test needs no SDK.
# Regenerate: dotnet publish tests/fixture -c Release -o out && base64 -w0 out/hello.dll > hello.dll.b64
# and copy out/hello.runtimeconfig.json next to it.
base64 -d "$here/hello.dll.b64" > "$work/hello.dll"
cp "$here/hello.runtimeconfig.json" "$work/hello.runtimeconfig.json"
chmod 644 "$work/hello.dll" "$work/hello.runtimeconfig.json"

out=$(docker run --rm -v "$work:/work:ro" "$image" /work/hello.dll) || fail "hello.dll failed: $out"
for line in 'hello from verity dotnet' "version=$expected_version" 'icu=ok' 'tzdata=ok' 'openssl=ok' 'roots=ok'; do
  printf '%s\n' "$out" | grep -qx "$line" || fail "hello.dll output lacks '$line': $out"
done
printf '%s\n' "$out" | grep -qx 'framework=.NET 9\..*' || fail "unexpected framework line: $out"

# Exit codes reach the caller.
status=0
docker run --rm -v "$work:/work:ro" "$image" /work/hello.dll --exit 7 >/dev/null 2>&1 || status=$?
[ "$status" = 7 ] || fail "exit status $status != 7"

# Negative: a missing assembly fails.
status=0
docker run --rm "$image" /work/missing.dll >/dev/null 2>&1 || status=$?
[ "$status" != 0 ] || fail 'a missing assembly exited 0'

# Negative: an app that needs the ASP.NET Core framework must not run on the runtime-only image.
cp "$work/hello.dll" "$work/web.dll"
cat > "$work/web.runtimeconfig.json" <<EOF
{"runtimeOptions":{"tfm":"net9.0","frameworks":[{"name":"Microsoft.NETCore.App","version":"9.0.0"},{"name":"Microsoft.AspNetCore.App","version":"9.0.0"}]}}
EOF
status=0
err=$(docker run --rm -v "$work:/work:ro" "$image" /work/web.dll 2>&1 >/dev/null) || status=$?
[ "$status" != 0 ] || fail 'an ASP.NET Core app ran on the runtime-only image'
printf '%s\n' "$err" | grep -q 'Microsoft.AspNetCore.App' || fail "missing framework error does not name it: $err"
