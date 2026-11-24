#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*- powershell=\([0-9][0-9.]*\)-r[0-9][0-9]*$/\1/p' \
  "$(dirname "$0")/../apko.yaml")
[ -n "$expected_version" ] || { printf 'PowerShell package version not found\n' >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

cat >"$work/smoke.ps1" <<'EOF'
param(
    [Parameter(Mandatory)][string]$Name,
    [int]$Count = 3
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$items = 1..$Count | ForEach-Object { [pscustomobject]@{ Index = $_; Square = $_ * $_ } }
$sum = ($items | Measure-Object -Property Square -Sum).Sum
$roundTrip = $items | ConvertTo-Json -Compress | ConvertFrom-Json
$hash = [System.BitConverter]::ToString(
    [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($Name))
).Replace('-', '').ToLowerInvariant()

$out = Join-Path $HOME 'verity-out.txt'
Set-Content -Path $out -Value "hello $Name"
$readBack = Get-Content -Path $out -Raw

[ordered]@{
    version  = $PSVersionTable.PSVersion.ToString()
    edition  = $PSVersionTable.PSEdition
    user     = [System.Environment]::UserName
    cwd      = (Get-Location).Path
    sum      = [int]$sum
    count    = @($roundTrip).Count
    sha256   = $hash
    readBack = $readBack.Trim()
} | ConvertTo-Json -Compress
EOF

cat >"$work/throws.ps1" <<'EOF'
$ErrorActionPreference = 'Stop'
throw 'verity-intentional-failure'
EOF

cat >"$work/exit7.ps1" <<'EOF'
exit 7
EOF
chmod -R a+rX "$work"

user=$(docker image inspect --format '{{.Config.User}}' "$image")
[ "$user" = 65532 ] || fail "unexpected user: $user"
entrypoint=$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")
[ "$entrypoint" = '["/usr/bin/pwsh"]' ] || fail "unexpected entrypoint: $entrypoint"
workdir=$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")
[ "$workdir" = /home/nonroot ] || fail "unexpected working directory: $workdir"

result=$(docker run --rm -v "$work:/scripts:ro" "$image" -NoLogo -NoProfile -NonInteractive \
  -File /scripts/smoke.ps1 -Name verity -Count 4 2>&1) || fail "script failed: $result"
expected_hash=$(printf 'verity' | sha256sum | cut -d' ' -f1)
expected="{\"version\":\"${expected_version}\",\"edition\":\"Core\",\"user\":\"nonroot\",\"cwd\":\"/home/nonroot\",\"sum\":30,\"count\":4,\"sha256\":\"${expected_hash}\",\"readBack\":\"hello verity\"}"
[ "$result" = "$expected" ] || fail "unexpected script output:
  got:      $result
  expected: $expected"

# Script read from stdin, the documented non-interactive container pattern.
# TERM=dumb stops .NET from emitting keypad-mode escapes around piped output.
stdin_result=$(printf '"stdin-{0}" -f (2 + 3)\n' |
  docker run --rm -i -e TERM=dumb "$image" -NoLogo -NoProfile -NonInteractive -Command - 2>&1) ||
  fail "stdin command failed: $stdin_result"
[ "$stdin_result" = stdin-5 ] || fail "unexpected stdin output: $stdin_result"

set +e
docker run --rm -v "$work:/scripts:ro" "$image" -NoLogo -NoProfile -NonInteractive \
  -File /scripts/throws.ps1 >"$work/throws.log" 2>&1
code=$?
set -e
[ "$code" -ne 0 ] || fail 'throwing script unexpectedly succeeded'
grep -q verity-intentional-failure "$work/throws.log" ||
  fail "throw message missing: $(cat "$work/throws.log")"

set +e
docker run --rm -v "$work:/scripts:ro" "$image" -NoLogo -NoProfile -NonInteractive \
  -File /scripts/exit7.ps1 >/dev/null 2>&1
code=$?
set -e
[ "$code" -eq 7 ] || fail "script exit code not propagated: $code"

if docker run --rm "$image" -NoLogo -NoProfile -NonInteractive \
  -File /scripts/missing.ps1 >"$work/missing.log" 2>&1; then
  fail 'missing script unexpectedly succeeded'
fi
grep -q 'missing.ps1' "$work/missing.log" || fail "missing script error unclear: $(cat "$work/missing.log")"

if docker run --rm -v "$work:/scripts:ro" "$image" -NoLogo -NoProfile -NonInteractive \
  -File /scripts/smoke.ps1 >"$work/mandatory.log" 2>&1; then
  fail 'script without mandatory parameter unexpectedly succeeded'
fi

printf 'SMOKE PASS version=%s\n' "$expected_version"
