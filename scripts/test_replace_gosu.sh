#!/bin/sh
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
mkdir -p "$work/bin" "$work/apk" "$work/repo/scripts" "$work/repo/packages"

version=1.19-r0
cp "$root/scripts/replace_gosu.sh" "$work/repo/scripts/replace_gosu.sh"

# One fixture package per architecture; the payload encodes the architecture so
# the extracted binary differs the way the real per-architecture packages do.
for pair in x86_64:amd64 aarch64:arm64; do
  apk_arch=${pair%:*}
  mkdir -p "$work/payload/usr/bin"
  printf '%s' "${pair#*:}" > "$work/payload/usr/bin/gosu"
  tar -czf "$work/apk/$apk_arch.apk" -C "$work/payload" usr/bin/gosu
done
amd64_checksum=$(printf amd64 | sha256sum | cut -d' ' -f1)
arm64_checksum=$(printf arm64 | sha256sum | cut -d' ' -f1)
x86_64_package=$(sha256sum "$work/apk/x86_64.apk" | cut -d' ' -f1)
aarch64_package=$(sha256sum "$work/apk/aarch64.apk" | cut -d' ' -f1)

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
printf '%s\n' "$url" >> "$CURL_LOG"
cp "$APK_DIR/$(basename "$(dirname "$url")").apk" "$output"
EOF

cat > "$work/bin/docker" <<'EOF'
#!/bin/sh
set -eu
for argument do
  printf '%s ' "$argument" >> "$DOCKER_LOG"
done
printf '\n' >> "$DOCKER_LOG"
context=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --build-arg | --file | --platform | --tag) shift 2 ;;
    --*) shift ;;
    *)
      context=$1
      shift
      ;;
  esac
done
stat -c '%a' "$context/gosu" >> "$MODE_LOG"
sha256sum "$context/gosu" | cut -d' ' -f1 >> "$BINARY_LOG"
cat >> "$DOCKERFILE_LOG"
EOF
chmod +x "$work/bin/curl" "$work/bin/docker"

write_source() {
  cat > "$work/source.yaml" <<EOF
gosu-version: $version
gosu-amd64-sha256: $amd64_checksum
gosu-arm64-sha256: $arm64_checksum
gosu-path: $1
EOF
}

write_state() {
  cat > "$work/repo/packages/repository-state.json" <<EOF
{
  "packages": [
    {
      "architecture": "x86_64",
      "name": "gosu",
      "version": "${1:-$version}",
      "path": "x86_64/gosu-${1:-$version}.apk",
      "sha256": "${2:-$x86_64_package}"
    },
    {
      "architecture": "aarch64",
      "name": "gosu",
      "version": "${1:-$version}",
      "path": "aarch64/gosu-${1:-$version}.apk",
      "sha256": "${3:-$aarch64_package}"
    },
    {
      "architecture": "x86_64",
      "name": "openssl-fips-provider",
      "version": "3.1.2-r3",
      "path": "x86_64/openssl-fips-provider-3.1.2-r3.apk",
      "sha256": "$x86_64_package"
    }
  ]
}
EOF
}

reset_logs() {
  : > "$work/curl.log"
  : > "$work/docker.log"
  : > "$work/dockerfile.log"
  : > "$work/mode.log"
  : > "$work/binary.log"
}

run_helper() {
  APK_DIR="$work/apk" CURL_LOG="$work/curl.log" DOCKER_LOG="$work/docker.log" \
    DOCKERFILE_LOG="$work/dockerfile.log" MODE_LOG="$work/mode.log" \
    BINARY_LOG="$work/binary.log" PATH="$work/bin:$PATH" \
    "$work/repo/scripts/replace_gosu.sh" "$@"
}

run_replacement() {
  replacement_arch=$1
  replacement_path=$2
  expected_apk_arch=$3
  expected_checksum=$4
  reset_logs
  write_source "$replacement_path"
  write_state
  run_helper "$work/source.yaml" "$replacement_arch" base-image target-image
  grep -Fxq "https://tektum.github.io/verity-images/apk/$expected_apk_arch/gosu-$version.apk" \
    "$work/curl.log"
  grep -Fq -- "--platform linux/$replacement_arch" "$work/docker.log"
  grep -Fq -- '--build-arg BASE=base-image' "$work/docker.log"
  grep -Fq -- "--build-arg GOSU_PATH=$replacement_path" "$work/docker.log"
  grep -Fq -- '--provenance=false' "$work/docker.log"
  grep -Fq -- '--tag target-image' "$work/docker.log"
  grep -Fxq 755 "$work/mode.log"
  grep -Fxq "$expected_checksum" "$work/binary.log"
  grep -Fq "COPY --chown=0:0 --chmod=0755 gosu \${GOSU_PATH}" "$work/dockerfile.log"
  [ "$(grep -c . "$work/docker.log")" -eq 1 ]
}

run_replacement amd64 /usr/sbin/gosu x86_64 "$amd64_checksum"
run_replacement amd64 /usr/local/bin/gosu x86_64 "$amd64_checksum"
run_replacement arm64 /usr/sbin/gosu aarch64 "$arm64_checksum"
run_replacement arm64 /usr/local/bin/gosu aarch64 "$arm64_checksum"

run_failure() {
  expected=$1
  shift
  reset_logs
  if output=$(run_helper "$@" 2>&1); then
    printf 'invalid gosu metadata was accepted\n' >&2
    exit 1
  fi
  printf '%s\n' "$output" | grep -Fq "$expected"
}

remove_field() {
  grep -v "^$1:" "$work/source.yaml" > "$work/source.tmp"
  mv "$work/source.tmp" "$work/source.yaml"
}

replace_field() {
  sed "s|^$1:.*|$1: $2|" "$work/source.yaml" > "$work/source.tmp"
  mv "$work/source.tmp" "$work/source.yaml"
}

write_state

write_source /usr/sbin/gosu
remove_field gosu-version
run_failure 'gosu-version must appear exactly once' "$work/source.yaml" amd64 base target
[ ! -s "$work/curl.log" ]

write_source /usr/sbin/gosu
remove_field gosu-arm64-sha256
run_failure 'gosu-arm64-sha256 must appear exactly once' "$work/source.yaml" amd64 base target
[ ! -s "$work/curl.log" ]

write_source /usr/sbin/gosu
replace_field gosu-version 1.19
run_failure 'invalid gosu-version' "$work/source.yaml" amd64 base target
[ ! -s "$work/curl.log" ]

write_source /usr/sbin/gosu
replace_field gosu-amd64-sha256 not-a-digest
run_failure 'invalid gosu-amd64-sha256' "$work/source.yaml" amd64 base target
[ ! -s "$work/curl.log" ]

write_source /usr/sbin/gosu
remove_field gosu-path
run_failure 'gosu-path must appear exactly once' "$work/source.yaml" amd64 base target
[ ! -s "$work/curl.log" ]

write_source /bin/gosu
run_failure 'unsupported gosu-path' "$work/source.yaml" amd64 base target
[ ! -s "$work/curl.log" ]

write_source /usr/sbin/gosu
run_failure 'unsupported architecture ppc64le' "$work/source.yaml" ppc64le base target
[ ! -s "$work/curl.log" ]

write_source /usr/sbin/gosu
printf '  gosu-extra: forbidden\n' >> "$work/source.yaml"
run_failure 'unknown key gosu-extra' "$work/source.yaml" amd64 base target
[ ! -s "$work/curl.log" ]

write_source /usr/sbin/gosu
write_state 1.18-r0
run_failure 'gosu 1.19-r0 is not pinned for x86_64' "$work/source.yaml" amd64 base target
[ ! -s "$work/curl.log" ]

write_state "$version" 0000000000000000000000000000000000000000000000000000000000000000
run_failure 'gosu package checksum mismatch' "$work/source.yaml" amd64 base target
[ -s "$work/curl.log" ]
[ ! -s "$work/docker.log" ]

write_state
replace_field gosu-amd64-sha256 \
  0000000000000000000000000000000000000000000000000000000000000000
run_failure 'gosu-amd64 checksum mismatch' "$work/source.yaml" amd64 base target
[ -s "$work/curl.log" ]
[ ! -s "$work/docker.log" ]

# The binary is now built once per architecture by the signed APK repository,
# so no image job may compile gosu source.
for forbidden in 'go build' 'go mod tidy' 'library/golang' 'tianon/gosu'; do
  if grep -Fq "$forbidden" "$root/scripts/replace_gosu.sh" "$root/scripts/build_candidate.sh"; then
    printf 'gosu source build survives in the image pipeline: %s\n' "$forbidden" >&2
    exit 1
  fi
done

recipe="$root/packages/gosu/melange.yaml"
grep -Fq 'epoch: 1' "$recipe"
grep -Fq 'source-commit: 6456aaa0f3c854d199d0f037f068eb97515b7513' "$recipe"
grep -Fq 'expected-sha256: 33d7537d588ea49458b9509bcf4554bdf5ceacc66da71e5caa1058ea3b689c3b' "$recipe"
grep -Fq 'go-version: go1.27.1' "$recipe"
grep -Fq 'x-sys-version: v0.44.0' "$recipe"
grep -Fq 'toolchain_sha256=63d339f0da5ab53635a56f2490a7984dfe12dfcff22ad749f63edaf590168445' "$recipe"
grep -Fq 'toolchain_sha256=3450b45a3f9ee8568792736a5c5e70a1f2e9b36c35a8f74958c03e51d7d92bec' "$recipe"
grep -Fq 'expected=8db7d29ba324c44235b2407ec826f955a7025da25f2832cdab8e0cbcbcbc6025' "$recipe"
grep -Fq 'expected=420aa319c70e55403461e67ea2f1b50159b7b8c07317567c5c62397f2abdc859' "$recipe"
grep -Fq 'go build -mod=readonly -trimpath -buildvcs=false' "$recipe"
grep -Fq 'GOTOOLCHAIN=local' "$recipe"
checksum_output_line=$(grep -nFx '      sha256sum gosu' "$recipe" | cut -d: -f1)
binary_gate_line=$(grep -nF " \"\$expected\" | sha256sum -c -" "$recipe" | cut -d: -f1)
[ "$checksum_output_line" -eq "$((binary_gate_line - 1))" ]
consumers="postgres-15-trixie postgres-16-trixie postgres-17-trixie postgres-18-trixie rabbitmq-4"
for consumer in $consumers; do
  consumer_source="$root/patched/$consumer/source.yaml"
  grep -Fxq "gosu-version: $version" "$consumer_source"
  grep -Fxq "gosu-amd64-sha256: 8db7d29ba324c44235b2407ec826f955a7025da25f2832cdab8e0cbcbcbc6025" \
    "$consumer_source"
  grep -Fxq "gosu-arm64-sha256: 420aa319c70e55403461e67ea2f1b50159b7b8c07317567c5c62397f2abdc859" \
    "$consumer_source"
  [ "$(grep -c '^gosu-' "$consumer_source")" -eq 4 ]
done
grep -Fxq 'gosu-path: /usr/sbin/gosu' "$root/patched/rabbitmq-4/source.yaml"
for consumer in postgres-15-trixie postgres-16-trixie postgres-17-trixie postgres-18-trixie; do
  grep -Fxq 'gosu-path: /usr/local/bin/gosu' "$root/patched/$consumer/source.yaml"
done

grep -Fq "if grep -Eq '^[[:space:]]*gosu-' \"\${context}/source.yaml\"; then" \
  "$root/scripts/build_candidate.sh"
replacement_line=$(grep -nF 'scripts/replace_gosu.sh' "$root/scripts/build_candidate.sh" | cut -d: -f1)
sbom_line=$(grep -nF "syft \"docker:\${patched}\"" "$root/scripts/build_candidate.sh" | cut -d: -f1)
[ "$replacement_line" -lt "$sbom_line" ]
