#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

cat > "$work/bin/curl" <<'EOF'
#!/bin/bash
set -euo pipefail
url=
output=
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      output=$2
      shift 2
      ;;
    http*)
      url=$1
      shift
      ;;
    *) shift ;;
  esac
done
arch=${url##*-}
printf '%s' "$arch" > "$output"
printf '%s\n' "$url" >> "$CURL_LOG"
EOF

cat > "$work/bin/docker" <<'EOF'
#!/bin/bash
set -euo pipefail
context=${!#}
printf '%q ' "$@" >> "$DOCKER_LOG"
printf '\n' >> "$DOCKER_LOG"
stat -c '%a' "$context/gosu" >> "$MODE_LOG"
cat >> "$DOCKERFILE_LOG"
EOF
chmod +x "$work/bin/curl" "$work/bin/docker"

amd64_checksum=$(printf amd64 | sha256sum | cut -d' ' -f1)
arm64_checksum=$(printf arm64 | sha256sum | cut -d' ' -f1)

write_source() {
  local path=$1
  cat > "$work/source.yaml" <<EOF
gosu-version: 1.19
gosu-amd64-sha256: $amd64_checksum
gosu-arm64-sha256: $arm64_checksum
gosu-path: $path
EOF
}

run_replacement() {
  local arch=$1
  local path=$2
  : > "$work/curl.log"
  : > "$work/docker.log"
  : > "$work/dockerfile.log"
  : > "$work/mode.log"
  write_source "$path"
  CURL_LOG="$work/curl.log" DOCKER_LOG="$work/docker.log" \
    DOCKERFILE_LOG="$work/dockerfile.log" MODE_LOG="$work/mode.log" \
    PATH="$work/bin:$PATH" "$root/scripts/replace_gosu.sh" \
    "$work/source.yaml" "$arch" base-image target-image
  grep -Fxq "https://github.com/tianon/gosu/releases/download/1.19/gosu-$arch" \
    "$work/curl.log"
  grep -Fq -- "--platform linux/$arch" "$work/docker.log"
  grep -Fq -- "--build-arg BASE=base-image" "$work/docker.log"
  grep -Fq -- "--build-arg GOSU_PATH=$path" "$work/docker.log"
  grep -Fq -- "--tag target-image" "$work/docker.log"
  grep -Fxq 755 "$work/mode.log"
  grep -Fq "COPY --chown=0:0 --chmod=0755 gosu \${GOSU_PATH}" "$work/dockerfile.log"
}

run_replacement amd64 /usr/sbin/gosu
run_replacement arm64 /usr/local/bin/gosu

cat > "$work/source.yaml" <<EOF
gosu-amd64-sha256: $amd64_checksum
gosu-arm64-sha256: $arm64_checksum
gosu-path: /usr/sbin/gosu
EOF
if "$root/scripts/replace_gosu.sh" "$work/source.yaml" amd64 base target; then
  printf 'missing gosu version was accepted\n' >&2
  exit 1
fi

cat > "$work/source.yaml" <<EOF
gosu-version: 1.19
gosu-amd64-sha256: $amd64_checksum
gosu-path: /usr/sbin/gosu
EOF
if "$root/scripts/replace_gosu.sh" "$work/source.yaml" amd64 base target; then
  printf 'missing arm64 checksum was accepted\n' >&2
  exit 1
fi

cat > "$work/source.yaml" <<EOF
gosu-version: 1.19
gosu-amd64-sha256: $amd64_checksum
gosu-arm64-sha256: $arm64_checksum
gosu-path: /usr/sbin/gosu
gosu-extra: forbidden
EOF
if "$root/scripts/replace_gosu.sh" "$work/source.yaml" amd64 base target; then
  printf 'unknown gosu metadata was accepted\n' >&2
  exit 1
fi

grep -Fq "if grep -q '^gosu-' \"\${context}/source.yaml\"; then" \
  "$root/scripts/build_candidate.sh"
replacement_line=$(grep -nF 'scripts/replace_gosu.sh' "$root/scripts/build_candidate.sh" | cut -d: -f1)
sbom_line=$(grep -nF "syft \"docker:\${patched}\"" "$root/scripts/build_candidate.sh" | cut -d: -f1)
[[ "$replacement_line" -lt "$sbom_line" ]]
