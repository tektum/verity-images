#!/bin/sh
set -eu

source=${1:?usage: replace_gosu.sh SOURCE ARCH BASE TARGET}
arch=${2:?usage: replace_gosu.sh SOURCE ARCH BASE TARGET}
base=${3:?usage: replace_gosu.sh SOURCE ARCH BASE TARGET}
target=${4:?usage: replace_gosu.sh SOURCE ARCH BASE TARGET}

repository_url=https://tektum.github.io/verity-images/apk
repository_state=$(cd "$(dirname "$0")/.." && pwd)/packages/repository-state.json

fail() {
  printf 'invalid gosu metadata: %s\n' "$1" >&2
  exit 1
}

unknown_key=$(awk -F: '
  { key = $1; gsub(/^[[:space:]]+|[[:space:]]+$/, "", key) }
  key ~ /^gosu-/ && key !~ /^gosu-(version|amd64-sha256|arm64-sha256|path)$/ { print key; exit }
' "$source")
[ -z "$unknown_key" ] || fail "unknown key $unknown_key"

read_value() {
  key_name=$1
  count=$(awk -v key="$key_name:" '$1 == key { count++ } END { print count + 0 }' "$source")
  [ "$count" -eq 1 ] || fail "$key_name must appear exactly once"
  value=$(awk -v key="$key_name:" '$1 == key && NF == 2 { print $2 }' "$source")
  [ -n "$value" ] || fail "$key_name must have one value"
  printf '%s' "$value"
}

version=$(read_value gosu-version)
amd64_checksum=$(read_value gosu-amd64-sha256)
arm64_checksum=$(read_value gosu-arm64-sha256)
gosu_path=$(read_value gosu-path)

printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+(\.[0-9]+)?-r[0-9]+$' || fail "invalid gosu-version"
printf '%s\n' "$amd64_checksum" | grep -Eq '^[0-9a-f]{64}$' || fail "invalid gosu-amd64-sha256"
printf '%s\n' "$arm64_checksum" | grep -Eq '^[0-9a-f]{64}$' || fail "invalid gosu-arm64-sha256"
case "$gosu_path" in
  /usr/local/bin/gosu | /usr/sbin/gosu) ;;
  *) fail "unsupported gosu-path" ;;
esac
case "$arch" in
  amd64) checksum=$amd64_checksum apk_arch=x86_64 ;;
  arm64) checksum=$arm64_checksum apk_arch=aarch64 ;;
  *) fail "unsupported architecture $arch" ;;
esac

# The pinned repository state is produced by the signed, attested APK release
# process, so the digest recorded there is the trust anchor for the download.
package_path="$apk_arch/gosu-$version.apk"
package_checksum=$(jq -r --arg architecture "$apk_arch" --arg path "$package_path" '
  [.packages[] | select(.name == "gosu" and .architecture == $architecture and .path == $path)]
  | if length == 1 then .[0].sha256 else "" end
' "$repository_state")
printf '%s\n' "$package_checksum" | grep -Eq '^[0-9a-f]{64}$' || fail "gosu $version is not pinned for $apk_arch"

work=$(mktemp -d)
trap 'rm -rf "$work"' 0
mkdir "$work/install"
curl -fsSL "$repository_url/$package_path" -o "$work/gosu.apk"
if ! printf '%s  %s\n' "$package_checksum" "$work/gosu.apk" \
  | sha256sum -c - >/dev/null 2>&1; then
  fail "gosu package checksum mismatch"
fi
tar --warning=no-unknown-keyword -xzOf "$work/gosu.apk" usr/bin/gosu > "$work/install/gosu"
if ! printf '%s  %s\n' "$checksum" "$work/install/gosu" \
  | sha256sum -c - >/dev/null 2>&1; then
  fail "gosu-$arch checksum mismatch"
fi
chmod 0755 "$work/install/gosu"

docker build --platform "linux/$arch" --provenance=false --build-arg "BASE=$base" \
  --build-arg "GOSU_PATH=$gosu_path" --tag "$target" --file - "$work/install" <<'EOF'
ARG BASE=scratch
FROM ${BASE}
ARG GOSU_PATH
COPY --chown=0:0 --chmod=0755 gosu ${GOSU_PATH}
EOF
