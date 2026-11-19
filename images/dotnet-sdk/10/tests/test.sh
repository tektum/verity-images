#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE [FLAVOR]}
here=$(cd "$(dirname "$0")" && pwd)
expected_sdk=$(sed -n 's/^  version: "\([^"]*\)".*$/\1/p' "$here/../melange.yaml" | head -n 1)
expected_runtime=$(sed -n 's/^  upstream-version: \([0-9.]*\).*$/\1/p' "$here/../melange.yaml" | head -n 1)
[ -n "$expected_sdk" ] || { printf 'package version not found\n' >&2; exit 1; }
[ -n "$expected_runtime" ] || { printf 'runtime version not found\n' >&2; exit 1; }
major=${expected_sdk%%.*}

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

# OCI contract: dotnet entrypoint, non-root user, telemetry off, container-aware environment.
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/dotnet"]' ] || fail 'unexpected entrypoint'
user=$(docker image inspect -f '{{.Config.User}}' "$image")
case "$user" in
  ''|0|root|0:*|root:*) fail "image runs as root: '$user'" ;;
esac
env=$(docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$image")
for line in DOTNET_ROOT=/usr/share/dotnet DOTNET_RUNNING_IN_CONTAINER=true DOTNET_CLI_TELEMETRY_OPTOUT=true DOTNET_NOLOGO=true; do
  printf '%s\n' "$env" | grep -qx "$line" || fail "$line is not set"
done
printf '%s\n' "$env" | grep -q '^DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=' && fail 'invariant globalization must stay off while ICU is installed'

# Exactly the pinned SDK and its bundled runtimes.
sdks=$(docker run --rm "$image" --list-sdks)
[ "$sdks" = "$expected_sdk [/usr/share/dotnet/sdk]" ] || fail "unexpected SDKs: $sdks"
runtimes=$(docker run --rm "$image" --list-runtimes)
for framework in Microsoft.AspNetCore.App Microsoft.NETCore.App; do
  printf '%s\n' "$runtimes" | grep -qx "$framework $expected_runtime \[/usr/share/dotnet/shared/$framework\]" ||
    fail "$framework $expected_runtime missing: $runtimes"
done
[ "$(docker run --rm "$image" --version)" = "$expected_sdk" ] || fail 'dotnet --version does not report the pinned SDK'

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
# As the image user, with no network: the template restores into the image's own HOME and work-dir.
out=$(docker run --rm --network none "$image" new console --output /app/hello 2>&1) || fail "dotnet new console failed as the image user: $out"
printf '%s\n' "$out" | grep -q 'Restore succeeded' || fail "template restore did not succeed offline: $out"

# The remaining steps write to a bind mount, so they run as the caller's uid with HOME inside the mount.
run() {
  docker run --rm --network none --user "$(id -u):$(id -g)" -e HOME=/src/.home -v "$work:/src" -w /src "$image" "$@"
}

# Create, restore, build and run the console template with no network: everything comes from the SDK itself.
run new console --name hello --output /src/hello >/dev/null || fail 'dotnet new console failed offline'
out=$(run run --project /src/hello/hello.csproj) || fail "template app failed: $out"
[ "$out" = 'Hello, World!' ] || fail "unexpected template output: $out"

# A program that exercises ICU, tzdata and OpenSSL, built in Release and run from its output assembly.
cat > "$work/hello/Program.cs" <<'EOF'
using System.Globalization;
using System.Security.Cryptography;
Console.WriteLine("hello from verity dotnet-sdk");
Console.WriteLine($"runtime={Environment.Version}");
Console.WriteLine(new DateTime(2024, 1, 15).ToString("MMMM", new CultureInfo("de-DE")) == "Januar" ? "icu=ok" : "icu=bad");
Console.WriteLine(TimeZoneInfo.FindSystemTimeZoneById("Europe/Berlin").Id == "Europe/Berlin" ? "tzdata=ok" : "tzdata=bad");
Console.WriteLine(Convert.ToHexString(SHA256.HashData("abc"u8)) == "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD" ? "openssl=ok" : "openssl=bad");
return args.Length > 0 ? int.Parse(args[0]) : 0;
EOF
run build /src/hello/hello.csproj --configuration Release --output /src/out >/dev/null || fail 'dotnet build failed'
out=$(run /src/out/hello.dll) || fail "built app failed: $out"
for line in 'hello from verity dotnet-sdk' "runtime=$expected_runtime" 'icu=ok' 'tzdata=ok' 'openssl=ok'; do
  printf '%s\n' "$out" | grep -qx "$line" || fail "app output lacks '$line': $out"
done
grep -q "<TargetFramework>net$major.0</TargetFramework>" "$work/hello/hello.csproj" || fail "template does not target net$major.0"

# Exit codes reach the caller.
status=0
run /src/out/hello.dll 7 >/dev/null 2>&1 || status=$?
[ "$status" = 7 ] || fail "exit status $status != 7"

# Negative: a compile error fails the build and names the error.
printf 'this is not C#\n' > "$work/hello/Broken.cs"
status=0
err=$(run build /src/hello/hello.csproj 2>&1) || status=$?
[ "$status" != 0 ] || fail 'a broken project built successfully'
printf '%s\n' "$err" | grep -q 'error CS' || fail "build failure does not report a compiler error: $err"

# Negative: an unknown command fails.
status=0
run no-such-command >/dev/null 2>&1 || status=$?
[ "$status" != 0 ] || fail 'an unknown command exited 0'
