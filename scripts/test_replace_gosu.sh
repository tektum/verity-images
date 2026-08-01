#!/bin/sh
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

cat > "$work/bin/curl" <<'EOF'
#!/bin/sh
set -eu
url=
output=
while [ "$#" -gt 0 ]; do
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
#!/bin/sh
set -eu
context=
for argument do
  context=$argument
done
for argument do
  printf '%s ' "$argument" >> "$DOCKER_LOG"
done
printf '\n' >> "$DOCKER_LOG"
stat -c '%a' "$context/gosu" >> "$MODE_LOG"
cat >> "$DOCKERFILE_LOG"
EOF
chmod +x "$work/bin/curl" "$work/bin/docker"

amd64_checksum=$(printf amd64 | sha256sum | cut -d' ' -f1)
arm64_checksum=$(printf arm64 | sha256sum | cut -d' ' -f1)

write_source() {
  source_path=$1
  cat > "$work/source.yaml" <<EOF
gosu-version: 1.19
gosu-amd64-sha256: $amd64_checksum
gosu-arm64-sha256: $arm64_checksum
gosu-path: $source_path
EOF
}

run_replacement() {
  replacement_arch=$1
  replacement_path=$2
  : > "$work/curl.log"
  : > "$work/docker.log"
  : > "$work/dockerfile.log"
  : > "$work/mode.log"
  write_source "$replacement_path"
  CURL_LOG="$work/curl.log" DOCKER_LOG="$work/docker.log" \
    DOCKERFILE_LOG="$work/dockerfile.log" MODE_LOG="$work/mode.log" \
    PATH="$work/bin:$PATH" "$root/scripts/replace_gosu.sh" \
    "$work/source.yaml" "$replacement_arch" base-image target-image
  grep -Fxq "https://github.com/tianon/gosu/releases/download/1.19/gosu-$replacement_arch" \
    "$work/curl.log"
  grep -Fq -- "--platform linux/$replacement_arch" "$work/docker.log"
  grep -Fq -- "--build-arg BASE=base-image" "$work/docker.log"
  grep -Fq -- "--build-arg GOSU_PATH=$replacement_path" "$work/docker.log"
  grep -Fq -- "--tag target-image" "$work/docker.log"
  grep -Fxq 755 "$work/mode.log"
  grep -Fq "COPY --chown=0:0 --chmod=0755 gosu \${GOSU_PATH}" "$work/dockerfile.log"
}

run_replacement amd64 /usr/sbin/gosu
run_replacement amd64 /usr/local/bin/gosu
run_replacement arm64 /usr/sbin/gosu
run_replacement arm64 /usr/local/bin/gosu

expect_failure() {
  expected=$1
  : > "$work/curl.log"
  : > "$work/docker.log"
  : > "$work/dockerfile.log"
  : > "$work/mode.log"
  shift
  if output=$(CURL_LOG="$work/curl.log" DOCKER_LOG="$work/docker.log" \
    DOCKERFILE_LOG="$work/dockerfile.log" MODE_LOG="$work/mode.log" \
    PATH="$work/bin:$PATH" "$root/scripts/replace_gosu.sh" "$@" 2>&1); then
    printf 'invalid gosu metadata was accepted\n' >&2
    exit 1
  fi
  printf '%s\n' "$output" | grep -Fq "$expected"
  [ ! -s "$work/docker.log" ]
}

cat > "$work/source.yaml" <<EOF
gosu-amd64-sha256: $amd64_checksum
gosu-arm64-sha256: $arm64_checksum
gosu-path: /usr/sbin/gosu
EOF
expect_failure 'gosu-version must appear exactly once' \
  "$work/source.yaml" amd64 base target

cat > "$work/source.yaml" <<EOF
gosu-version: 1.19
gosu-amd64-sha256: $amd64_checksum
gosu-path: /usr/sbin/gosu
EOF
expect_failure 'gosu-arm64-sha256 must appear exactly once' \
  "$work/source.yaml" amd64 base target

cat > "$work/source.yaml" <<EOF
gosu-version: 1.19
gosu-amd64-sha256: $amd64_checksum
gosu-arm64-sha256: $arm64_checksum
EOF
expect_failure 'gosu-path must appear exactly once' \
  "$work/source.yaml" amd64 base target

cat > "$work/source.yaml" <<EOF
gosu-version: 1.19
gosu-amd64-sha256: 0000000000000000000000000000000000000000000000000000000000000000
gosu-arm64-sha256: $arm64_checksum
gosu-path: /usr/sbin/gosu
EOF
expect_failure 'gosu-amd64 checksum mismatch' \
  "$work/source.yaml" amd64 base target

cat > "$work/source.yaml" <<EOF
gosu-version: 1.19
gosu-amd64-sha256: $amd64_checksum
gosu-arm64-sha256: $arm64_checksum
gosu-path: /usr/sbin/gosu
  gosu-extra: forbidden
EOF
expect_failure 'unknown key gosu-extra' "$work/source.yaml" amd64 base target

grep -Fq "if grep -Eq '^[[:space:]]*gosu-' \"\${context}/source.yaml\"; then" \
  "$root/scripts/build_candidate.sh"
replacement_line=$(grep -nF 'scripts/replace_gosu.sh' "$root/scripts/build_candidate.sh" | cut -d: -f1)
sbom_line=$(grep -nF "syft \"docker:\${patched}\"" "$root/scripts/build_candidate.sh" | cut -d: -f1)
[ "$replacement_line" -lt "$sbom_line" ]
