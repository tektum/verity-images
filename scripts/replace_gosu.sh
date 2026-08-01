#!/bin/bash
set -euo pipefail

source=${1:?usage: replace_gosu.sh SOURCE ARCH BASE TARGET}
arch=${2:?usage: replace_gosu.sh SOURCE ARCH BASE TARGET}
base=${3:?usage: replace_gosu.sh SOURCE ARCH BASE TARGET}
target=${4:?usage: replace_gosu.sh SOURCE ARCH BASE TARGET}

fail() {
  printf 'invalid gosu metadata: %s\n' "$1" >&2
  exit 1
}

while IFS= read -r key; do
  case "$key" in
    gosu-version | gosu-amd64-sha256 | gosu-arm64-sha256 | gosu-path) ;;
    gosu-*) fail "unknown key $key" ;;
  esac
done < <(awk -F: '{ key = $1; gsub(/^[[:space:]]+|[[:space:]]+$/, "", key); if (key ~ /^gosu-/) print key }' "$source")

read_value() {
  local key=$1
  local count
  local value
  count=$(awk -v key="$key:" '$1 == key { count++ } END { print count + 0 }' "$source")
  [[ "$count" -eq 1 ]] || fail "$key must appear exactly once"
  value=$(awk -v key="$key:" '$1 == key && NF == 2 { print $2 }' "$source")
  [[ -n "$value" ]] || fail "$key must have one value"
  printf '%s' "$value"
}

version=$(read_value gosu-version)
amd64_checksum=$(read_value gosu-amd64-sha256)
arm64_checksum=$(read_value gosu-arm64-sha256)
gosu_path=$(read_value gosu-path)

[[ "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || fail "invalid gosu-version"
[[ "$amd64_checksum" =~ ^[0-9a-f]{64}$ ]] || fail "invalid gosu-amd64-sha256"
[[ "$arm64_checksum" =~ ^[0-9a-f]{64}$ ]] || fail "invalid gosu-arm64-sha256"
case "$gosu_path" in
  /usr/local/bin/gosu | /usr/sbin/gosu) ;;
  *) fail "unsupported gosu-path" ;;
esac
case "$arch" in
  amd64) checksum=$amd64_checksum ;;
  arm64) checksum=$arm64_checksum ;;
  *) fail "unsupported architecture $arch" ;;
esac

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curl -fsSL "https://github.com/tianon/gosu/releases/download/${version}/gosu-${arch}" \
  -o "$work/gosu"
if ! printf '%s  %s\n' "$checksum" "$work/gosu" | sha256sum -c - >/dev/null 2>&1; then
  fail "gosu-$arch checksum mismatch"
fi
chmod 0755 "$work/gosu"
docker build --platform "linux/$arch" --build-arg "BASE=$base" \
  --build-arg "GOSU_PATH=$gosu_path" --tag "$target" --file - "$work" <<'EOF'
ARG BASE=scratch
FROM ${BASE}
ARG GOSU_PATH
COPY --chown=0:0 --chmod=0755 gosu ${GOSU_PATH}
EOF
