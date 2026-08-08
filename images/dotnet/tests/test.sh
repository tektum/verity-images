#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
good=$(mktemp -d)
bad=$(mktemp -d)
chmod 0777 "$good" "$bad"

cleanup() {
  rm -rf "$good" "$bad"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/dotnet"]' ] || fail 'unexpected OCI entrypoint'
[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = /app ] || fail 'unexpected OCI working directory'

docker run --rm --network none "$image" --list-sdks 2>&1 | grep -F '[/usr/share/dotnet/sdk]' >/dev/null || fail 'SDK not installed'
docker run --rm --network none "$image" --version 2>&1 | grep -Fx '8.0.129' >/dev/null || fail 'unexpected dotnet SDK version'

cat > "$good/App.csproj" <<'EOF'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net8.0</TargetFramework>
    <Nullable>disable</Nullable>
    <ImplicitUsings>disable</ImplicitUsings>
  </PropertyGroup>
</Project>
EOF
cat > "$good/Program.cs" <<'EOF'
using System;

class Program
{
    static void Main(string[] args)
    {
        Console.WriteLine("Hello from verity-dotnet");
        Console.WriteLine("Arguments: " + string.Join(",", args));
    }
}
EOF

output=$(docker run --rm --network none -v "$good:/app" "$image" run -- arg1 arg2)
printf '%s\n' "$output" | grep -Fx 'Hello from verity-dotnet' >/dev/null || fail 'compiled application did not print expected greeting'
printf '%s\n' "$output" | grep -Fx 'Arguments: arg1,arg2' >/dev/null || fail 'compiled application did not forward arguments'

cat > "$bad/Bad.csproj" <<'EOF'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe
  </PropertyGroup>
</Project>
EOF
cat > "$bad/Program.cs" <<'EOF'
using System;

class Program
{
    static void Main()
    {
        Console.WriteLine("should not build");
    }
}
EOF

if docker run --rm --network none -v "$bad:/app" "$image" build >/dev/null 2>&1; then
  fail 'invalid project unexpectedly succeeded'
fi

printf 'SMOKE PASS image=%s\n' "$image"
