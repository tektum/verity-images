#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
script="$root/scripts/build_candidate.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
export APKO_LOG="$work/apko.log" MELANGE_LOG="$work/melange.log"

cat >"$work/bin/melange" <<'EOF'
#!/bin/bash
set -euo pipefail
case "$1" in
  keygen)
    : >"$2"
    : >"$2.pub"
    ;;
  build)
    printf 'start %s\n' "$*" >>"$MELANGE_LOG"
    sleep 0.1
    printf 'end %s\n' "$*" >>"$MELANGE_LOG"
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == --out-dir ]]; then
        mkdir -p "$2"
        break
      fi
      shift
    done
    ;;
esac
EOF

cat >"$work/bin/apko" <<'EOF'
#!/bin/bash
set -euo pipefail
case "$1" in
  show-config)
    cat "$2" >>"$APKO_LOG"
    ;;
  lock)
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == --output ]]; then
        printf '{}\n' >"$2"
        break
      fi
      shift
    done
    ;;
  build)
    : >"$4"
    ;;
esac
EOF

cat >"$work/bin/docker" <<'EOF'
#!/bin/sh
set -eu
[ "$1" = load ]
cat >/dev/null
EOF
chmod +x "$work/bin/"*

run_candidate() {
  (
    cd "$work"
    PATH="$work/bin:$PATH" GITHUB_SHA=test "$script" "$1" "$2" "$3" wolfi 1
  )
}

mkdir -p "$work/caddy"
cat >"$work/caddy/apko.yaml" <<'EOF'
variant: plain
repository: @LOCAL_REPOSITORY@
key: @LOCAL_KEY@
godebug: @GODEBUG@
EOF
cat >"$work/caddy/fips.apko.yaml" <<'EOF'
variant: fips
repository: @LOCAL_REPOSITORY@
key: @LOCAL_KEY@
godebug: @GODEBUG@
EOF
: >"$work/caddy/melange.yaml"
printf 'GOFIPS140=v1.0.0\n' >"$work/caddy/fips.env"
run_candidate "$work/caddy" caddy-fips fips
grep -q '^variant: fips$' "$APKO_LOG"
if grep -q '^variant: plain$' "$APKO_LOG"; then
  exit 1
fi
grep -q "start build $work/caddy/melange.yaml --arch amd64.*--env-file $work/caddy/fips.env" "$MELANGE_LOG"
grep -q "start build $work/caddy/melange.yaml --arch arm64.*--env-file $work/caddy/fips.env" "$MELANGE_LOG"
[[ $(grep -c "^start .*${work}/caddy/melange.yaml" "$MELANGE_LOG") -eq 2 ]]
[[ $(grep -n "^end build $work/caddy/melange.yaml --arch amd64" "$MELANGE_LOG" | cut -d: -f1) -lt $(grep -n "^start build $work/caddy/melange.yaml --arch arm64" "$MELANGE_LOG" | cut -d: -f1) ]]
[[ -d "$work/dist/caddy-fips/packages" ]]

: >"$APKO_LOG"
: >"$MELANGE_LOG"
mkdir -p "$work/go"
printf 'variant: plain\n' >"$work/go/apko.yaml"
printf '{}\n' >"$work/go/apko.lock.json"
cat >"$work/go/fips.apko.yaml" <<'EOF'
variant: fips
contents:
  repositories:
    - https://tektum.github.io/verity-images/apk
    - https://packages.wolfi.dev/os
  keyring:
    - packages/keys/verity-apk-2026.rsa.pub
    - https://packages.wolfi.dev/os/wolfi-signing.rsa.pub
  packages:
    - openssl-fips-provider=3.1.2-r3
EOF
printf '{}\n' >"$work/go/fips.apko.lock.json"
cat >"$work/go/fips-wrapper.apko.yaml" <<'EOF'
variant: fips-wrapper
contents:
  repositories:
    - "@LOCAL_REPOSITORY@"
    - https://tektum.github.io/verity-images/apk
  keyring:
    - "@LOCAL_KEY@"
    - "@REPOSITORY_KEY@"
  packages:
    - openssl-fips-provider=3.1.2-r3
EOF
: >"$work/go/fips.melange.yaml"
run_candidate "$work/go" go-fips fips
grep -q '^variant: fips-wrapper$' "$APKO_LOG"
grep -q 'https://tektum.github.io/verity-images/apk' "$APKO_LOG"
grep -q 'openssl-fips-provider=3.1.2-r3' "$APKO_LOG"
grep -q "start build $work/go/fips.melange.yaml --arch amd64" "$MELANGE_LOG"
grep -q "start build $work/go/fips.melange.yaml --arch arm64" "$MELANGE_LOG"
[[ $(grep -c "^start .*${work}/go/fips.melange.yaml" "$MELANGE_LOG") -eq 2 ]]
[[ $(grep -n "^end build $work/go/fips.melange.yaml --arch amd64" "$MELANGE_LOG" | cut -d: -f1) -lt $(grep -n "^start build $work/go/fips.melange.yaml --arch arm64" "$MELANGE_LOG" | cut -d: -f1) ]]
if grep -q 'packages/openssl-fips-provider/melange.yaml' "$MELANGE_LOG"; then
  exit 1
fi

recipe="$root/images/caddy/melange.yaml"
grep -Fq 'install -m644 -D Caddyfile ' "$recipe"
grep -Fq 'install -m644 -D index.html ' "$recipe"
[[ -f "$root/images/caddy/Caddyfile" ]]
[[ -f "$root/images/caddy/index.html" ]]
