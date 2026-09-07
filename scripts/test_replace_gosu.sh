#!/bin/sh
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
mkdir -p "$work/bin" "$work/packages" "$work/archive/apk" "$work/repo/scripts" "$work/repo/packages"

version=1.19-r1
release_tag=apk-repo-v0006
asset_name=verity-apk-repository.tar.zst
tar_bin=$(command -v tar)
cp "$root/scripts/replace_gosu.sh" "$work/repo/scripts/replace_gosu.sh"

# One fixture package per architecture; the payload encodes the architecture so
# the extracted binary differs the way the real per-architecture packages do.
for pair in x86_64:amd64 aarch64:arm64; do
  apk_arch=${pair%:*}
  mkdir -p "$work/payload/usr/bin" "$work/archive/apk/$apk_arch"
  printf '%s' "${pair#*:}" > "$work/payload/usr/bin/gosu"
  tar -czf "$work/packages/$apk_arch.apk" -C "$work/payload" usr/bin/gosu
  cp "$work/packages/$apk_arch.apk" "$work/archive/apk/$apk_arch/gosu-$version.apk"
done
amd64_checksum=$(printf amd64 | sha256sum | cut -d' ' -f1)
arm64_checksum=$(printf arm64 | sha256sum | cut -d' ' -f1)
x86_64_package=$(sha256sum "$work/packages/x86_64.apk" | cut -d' ' -f1)
aarch64_package=$(sha256sum "$work/packages/aarch64.apk" | cut -d' ' -f1)
tar --zstd -cf "$work/$asset_name" -C "$work/archive" apk
archive_checksum=$(sha256sum "$work/$asset_name" | cut -d' ' -f1)

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
cp "$ARCHIVE" "$output"
EOF

cat > "$work/bin/tar" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$TAR_LOG"
exec "$REAL_TAR" "$@"
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
chmod +x "$work/bin/curl" "$work/bin/tar" "$work/bin/docker"

write_source() {
  cat > "$work/source.yaml" <<EOF
gosu-version: $version
gosu-amd64-sha256: $amd64_checksum
gosu-arm64-sha256: $arm64_checksum
gosu-path: $1
EOF
}

write_state() {
  state_version=${1:-$version}
  state_archive_checksum=${2:-$archive_checksum}
  state_x86_64_package=${3:-$x86_64_package}
  state_aarch64_package=${4:-$aarch64_package}
  cat > "$work/repo/packages/repository-state.json" <<EOF
{
  "repository": "tektum/verity-images",
  "release": {"tag": "$release_tag"},
  "asset": {
    "name": "$asset_name",
    "sha256": "sha256:$state_archive_checksum"
  },
  "archive": {
    "root": "apk",
    "sha256": "sha256:$state_archive_checksum"
  },
  "packages": [
    {
      "architecture": "x86_64",
      "name": "gosu",
      "version": "$state_version",
      "path": "x86_64/gosu-$state_version.apk",
      "sha256": "$state_x86_64_package"
    },
    {
      "architecture": "aarch64",
      "name": "gosu",
      "version": "$state_version",
      "path": "aarch64/gosu-$state_version.apk",
      "sha256": "$state_aarch64_package"
    }
  ]
}
EOF
}

reset_logs() {
  : > "$work/curl.log"
  : > "$work/tar.log"
  : > "$work/docker.log"
  : > "$work/dockerfile.log"
  : > "$work/mode.log"
  : > "$work/binary.log"
}

run_helper() {
  ARCHIVE="$work/$asset_name" CURL_LOG="$work/curl.log" TAR_LOG="$work/tar.log" \
    REAL_TAR="$tar_bin" DOCKER_LOG="$work/docker.log" DOCKERFILE_LOG="$work/dockerfile.log" \
    MODE_LOG="$work/mode.log" BINARY_LOG="$work/binary.log" PATH="$work/bin:$PATH" \
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
  grep -Fxq "https://github.com/tektum/verity-images/releases/download/$release_tag/$asset_name" \
    "$work/curl.log"
  if grep -Fq 'tektum.github.io/verity-images/apk' "$work/curl.log"; then
    printf 'mutable Pages URL was requested\n' >&2
    exit 1
  fi
  [ "$(grep -c . "$work/curl.log")" -eq 1 ]
  [ "$(grep -c . "$work/tar.log")" -eq 2 ]
  grep -Fq -- "--zstd -xOf" "$work/tar.log"
  grep -Fq -- "apk/$expected_apk_arch/gosu-$version.apk" "$work/tar.log"
  grep -Fq -- '-xzOf' "$work/tar.log"
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

replace_state() {
  jq "$1" "$work/repo/packages/repository-state.json" > "$work/repository-state.tmp"
  mv "$work/repository-state.tmp" "$work/repo/packages/repository-state.json"
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
write_state
replace_state '.repository = "tektum/verity-images/../../attacker"'
run_failure 'unsupported immutable release repository' "$work/source.yaml" amd64 base target
[ ! -s "$work/curl.log" ]
[ ! -s "$work/tar.log" ]
[ ! -s "$work/docker.log" ]

write_state
replace_state '.release.tag = "apk-repo-v0006/../../latest"'
run_failure 'invalid immutable release tag' "$work/source.yaml" amd64 base target
[ ! -s "$work/curl.log" ]
[ ! -s "$work/tar.log" ]
[ ! -s "$work/docker.log" ]

write_state
replace_state '.asset.name = "../verity-apk-repository.tar.zst"'
run_failure 'unsupported immutable release asset' "$work/source.yaml" amd64 base target
[ ! -s "$work/curl.log" ]
[ ! -s "$work/tar.log" ]
[ ! -s "$work/docker.log" ]

write_state
replace_state '.archive.root = "../apk"'
run_failure 'unsupported immutable release archive root' "$work/source.yaml" amd64 base target
[ ! -s "$work/curl.log" ]
[ ! -s "$work/tar.log" ]
[ ! -s "$work/docker.log" ]

write_source /usr/sbin/gosu
write_state
jq 'del(.packages[] | select(.architecture == "x86_64"))' \
  "$work/repo/packages/repository-state.json" > "$work/repository-state.tmp"
mv "$work/repository-state.tmp" "$work/repo/packages/repository-state.json"
run_failure "gosu $version is not pinned for x86_64" "$work/source.yaml" amd64 base target
[ ! -s "$work/curl.log" ]
[ ! -s "$work/tar.log" ]
[ ! -s "$work/docker.log" ]

write_state "$version" 0000000000000000000000000000000000000000000000000000000000000000
run_failure 'release archive checksum mismatch' "$work/source.yaml" amd64 base target
[ -s "$work/curl.log" ]
[ ! -s "$work/tar.log" ]
[ ! -s "$work/docker.log" ]

write_state "$version" "$archive_checksum" \
  0000000000000000000000000000000000000000000000000000000000000000
run_failure 'gosu package checksum mismatch' "$work/source.yaml" amd64 base target
[ -s "$work/curl.log" ]
[ "$(grep -c . "$work/tar.log")" -eq 1 ]
[ ! -s "$work/docker.log" ]

write_state
replace_field gosu-amd64-sha256 \
  0000000000000000000000000000000000000000000000000000000000000000
run_failure 'gosu-amd64 checksum mismatch' "$work/source.yaml" amd64 base target
[ -s "$work/curl.log" ]
[ "$(grep -c . "$work/tar.log")" -eq 2 ]
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
grep -Fq 'expected=80240f7a59b9f73624ea615a583f7a11f26fd6f49585eed84ff000692c0fe0d3' "$recipe"
grep -Fq 'expected=0b7e07759394360077fc6138729e86339468f6305a37448c1de3849eb725a4be' "$recipe"
grep -Fq 'go build -mod=readonly -trimpath -buildvcs=false' "$recipe"
grep -Fq 'GOTOOLCHAIN=local' "$recipe"
consumers="postgres-15-trixie postgres-16-trixie postgres-17-trixie postgres-18-trixie rabbitmq-4"
for consumer in $consumers; do
  consumer_source="$root/patched/$consumer/source.yaml"
  grep -Fxq "gosu-version: $version" "$consumer_source"
  grep -Fxq "gosu-amd64-sha256: 80240f7a59b9f73624ea615a583f7a11f26fd6f49585eed84ff000692c0fe0d3" \
    "$consumer_source"
  grep -Fxq "gosu-arm64-sha256: 0b7e07759394360077fc6138729e86339468f6305a37448c1de3849eb725a4be" \
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
