#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

git clone -q "$root" "$work/repo"
cp "$root/scripts/renovate_refresh_apko_locks.sh" "$work/repo/scripts/"
mkdir -p "$work/bin"
cat > "$work/bin/apko" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$APKO_LOG"
[[ "$1" == lock ]]
output=
while (( $# > 0 )); do
  if [[ "$1" == --output ]]; then
    output=$2
    break
  fi
  shift
done
[[ -n "$output" ]]
printf '{"generated":true}\n' > "$output"
EOF
chmod +x "$work/bin/apko"

cd "$work/repo"
printf '\n' >> images/helm/apko.yaml
APKO_LOG="$work/apko.log" PATH="$work/bin:$PATH" scripts/renovate_refresh_apko_locks.sh
grep -Fx 'lock images/helm/apko.yaml --arch amd64,arm64 --output images/helm/apko.lock.json' "$work/apko.log"
grep -Fx '{"generated":true}' images/helm/apko.lock.json

git reset --hard -q HEAD
cp "$root/scripts/renovate_refresh_apko_locks.sh" scripts/
if APKO_LOG="$work/apko.log" PATH="$work/bin:$PATH" scripts/renovate_refresh_apko_locks.sh; then
  printf 'expected unchanged tree rejection\n' >&2
  exit 1
fi

printf '\n' >> images/alertmanager/apko.yaml
: > "$work/apko.log"
if APKO_LOG="$work/apko.log" PATH="$work/bin:$PATH" scripts/renovate_refresh_apko_locks.sh; then
  printf 'expected Melange-backed image rejection\n' >&2
  exit 1
fi
[[ ! -s "$work/apko.log" ]]
