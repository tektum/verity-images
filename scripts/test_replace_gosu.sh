#!/bin/sh
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
mkdir -p "$work/bin" "$work/archive/gosu-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

source_commit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
printf 'package main\n\nconst Version = "1.19"\n' \
  > "$work/archive/gosu-$source_commit/version.go"
tar -czf "$work/source.tar.gz" -C "$work/archive" "gosu-$source_commit"
source_checksum=$(sha256sum "$work/source.tar.gz" | cut -d' ' -f1)
builder=docker.io/library/golang@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
x_sys_version=v0.44.0

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
cp "$SOURCE_ARCHIVE" "$output"
printf '%s\n' "$url" >> "$CURL_LOG"
EOF

cat > "$work/bin/docker" <<'EOF'
#!/bin/sh
set -eu
for argument do
  printf '%s ' "$argument" >> "$DOCKER_LOG"
done
printf '\n' >> "$DOCKER_LOG"
output=
target_arch=
tag=
context=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output)
      output=${2#type=local,dest=}
      shift 2
      ;;
    --build-arg)
      case "$2" in TARGETARCH=*) target_arch=${2#TARGETARCH=} ;; esac
      shift 2
      ;;
    --tag)
      tag=$2
      shift 2
      ;;
    *)
      context=$1
      shift
      ;;
  esac
done
if [ -n "$output" ]; then
  mkdir -p "$output"
  printf '%s' "$target_arch" > "$output/gosu"
fi
if [ -n "$tag" ]; then
  stat -c '%a' "$context/gosu" >> "$MODE_LOG"
  cat >> "$DOCKERFILE_LOG"
else
  cat >> "$BUILDFILE_LOG"
fi
EOF
chmod +x "$work/bin/curl" "$work/bin/docker"

amd64_checksum=$(printf amd64 | sha256sum | cut -d' ' -f1)
arm64_checksum=$(printf arm64 | sha256sum | cut -d' ' -f1)

write_source() {
  source_path=$1
  cat > "$work/source.yaml" <<EOF
gosu-version: 1.19
gosu-source: $source_commit
gosu-source-sha256: $source_checksum
gosu-builder: $builder
gosu-x-sys-version: $x_sys_version
gosu-amd64-sha256: $amd64_checksum
gosu-arm64-sha256: $arm64_checksum
gosu-path: $source_path
EOF
}

reset_logs() {
  : > "$work/curl.log"
  : > "$work/docker.log"
  : > "$work/buildfile.log"
  : > "$work/dockerfile.log"
  : > "$work/mode.log"
}

run_helper() {
  SOURCE_ARCHIVE="$work/source.tar.gz" CURL_LOG="$work/curl.log" \
    DOCKER_LOG="$work/docker.log" BUILDFILE_LOG="$work/buildfile.log" \
    DOCKERFILE_LOG="$work/dockerfile.log" MODE_LOG="$work/mode.log" \
    PATH="$work/bin:$PATH" "$root/scripts/replace_gosu.sh" "$@"
}

run_replacement() {
  replacement_arch=$1
  replacement_path=$2
  reset_logs
  write_source "$replacement_path"
  run_helper "$work/source.yaml" "$replacement_arch" base-image target-image
  grep -Fxq "https://github.com/tianon/gosu/archive/$source_commit.tar.gz" "$work/curl.log"
  grep -Fq -- '--platform linux/amd64' "$work/docker.log"
  grep -Fq -- "--build-arg GO_BUILDER=$builder" "$work/docker.log"
  grep -Fq -- "--build-arg GOSU_X_SYS_VERSION=$x_sys_version" "$work/docker.log"
  grep -Fq -- "--build-arg TARGETARCH=$replacement_arch" "$work/docker.log"
  grep -Fq -- '--output type=local,dest=' "$work/docker.log"
  grep -Fq -- '--build-arg BASE=base-image' "$work/docker.log"
  grep -Fq -- "--build-arg GOSU_PATH=$replacement_path" "$work/docker.log"
  grep -Fq -- '--tag target-image' "$work/docker.log"
  grep -Fxq 755 "$work/mode.log"
  grep -Fq "go mod edit -require=\"golang.org/x/sys@\${GOSU_X_SYS_VERSION}\"" "$work/buildfile.log"
  grep -Fq 'GOTOOLCHAIN=local' "$work/buildfile.log"
  grep -Fq 'go build -mod=readonly -trimpath -buildvcs=false' "$work/buildfile.log"
  grep -Fq "COPY --chown=0:0 --chmod=0755 gosu \${GOSU_PATH}" "$work/dockerfile.log"
}

run_replacement amd64 /usr/sbin/gosu
run_replacement amd64 /usr/local/bin/gosu
run_replacement arm64 /usr/sbin/gosu
run_replacement arm64 /usr/local/bin/gosu

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

write_source /usr/sbin/gosu
remove_field gosu-version
run_failure 'gosu-version must appear exactly once' "$work/source.yaml" amd64 base target
[ ! -s "$work/docker.log" ]

write_source /usr/sbin/gosu
remove_field gosu-source-sha256
run_failure 'gosu-source-sha256 must appear exactly once' "$work/source.yaml" amd64 base target
[ ! -s "$work/docker.log" ]

write_source /usr/sbin/gosu
sed 's/^gosu-source:.*/gosu-source: mutable/' "$work/source.yaml" > "$work/source.tmp"
mv "$work/source.tmp" "$work/source.yaml"
run_failure 'invalid gosu-source' "$work/source.yaml" amd64 base target
[ ! -s "$work/docker.log" ]

write_source /usr/sbin/gosu
sed 's|^gosu-builder:.*|gosu-builder: docker.io/library/golang:latest|' \
  "$work/source.yaml" > "$work/source.tmp"
mv "$work/source.tmp" "$work/source.yaml"
run_failure 'invalid gosu-builder' "$work/source.yaml" amd64 base target
[ ! -s "$work/docker.log" ]

write_source /usr/sbin/gosu
sed 's/^gosu-x-sys-version:.*/gosu-x-sys-version: latest/' \
  "$work/source.yaml" > "$work/source.tmp"
mv "$work/source.tmp" "$work/source.yaml"
run_failure 'invalid gosu-x-sys-version' "$work/source.yaml" amd64 base target
[ ! -s "$work/docker.log" ]

write_source /usr/sbin/gosu
remove_field gosu-arm64-sha256
run_failure 'gosu-arm64-sha256 must appear exactly once' "$work/source.yaml" amd64 base target
[ ! -s "$work/docker.log" ]

write_source /usr/sbin/gosu
remove_field gosu-path
run_failure 'gosu-path must appear exactly once' "$work/source.yaml" amd64 base target
[ ! -s "$work/docker.log" ]

write_source /usr/sbin/gosu
sed 's|^gosu-path:.*|gosu-path: /bin/gosu|' "$work/source.yaml" > "$work/source.tmp"
mv "$work/source.tmp" "$work/source.yaml"
run_failure 'unsupported gosu-path' "$work/source.yaml" amd64 base target
[ ! -s "$work/docker.log" ]

write_source /usr/sbin/gosu
run_failure 'unsupported architecture ppc64le' "$work/source.yaml" ppc64le base target
[ ! -s "$work/docker.log" ]

write_source /usr/sbin/gosu
sed 's/^gosu-version:.*/gosu-version: 1.18/' "$work/source.yaml" > "$work/source.tmp"
mv "$work/source.tmp" "$work/source.yaml"
run_failure 'gosu-version does not match source' "$work/source.yaml" amd64 base target
[ ! -s "$work/docker.log" ]

write_source /usr/sbin/gosu
sed 's/^gosu-source-sha256:.*/gosu-source-sha256: 0000000000000000000000000000000000000000000000000000000000000000/' \
  "$work/source.yaml" > "$work/source.tmp"
mv "$work/source.tmp" "$work/source.yaml"
run_failure 'gosu source checksum mismatch' "$work/source.yaml" amd64 base target
[ ! -s "$work/docker.log" ]

write_source /usr/sbin/gosu
sed 's/^gosu-amd64-sha256:.*/gosu-amd64-sha256: 0000000000000000000000000000000000000000000000000000000000000000/' \
  "$work/source.yaml" > "$work/source.tmp"
mv "$work/source.tmp" "$work/source.yaml"
run_failure 'gosu-amd64 checksum mismatch' "$work/source.yaml" amd64 base target
grep -Fq -- '--build-arg TARGETARCH=amd64' "$work/docker.log"
if grep -Fq -- '--tag target' "$work/docker.log"; then
  printf 'checksum mismatch reached final image build\n' >&2
  exit 1
fi

write_source /usr/sbin/gosu
printf '  gosu-extra: forbidden\n' >> "$work/source.yaml"
run_failure 'unknown key gosu-extra' "$work/source.yaml" amd64 base target
[ ! -s "$work/docker.log" ]

grep -Fq "if grep -Eq '^[[:space:]]*gosu-' \"\${context}/source.yaml\"; then" \
  "$root/scripts/build_candidate.sh"
replacement_line=$(grep -nF 'scripts/replace_gosu.sh' "$root/scripts/build_candidate.sh" | cut -d: -f1)
sbom_line=$(grep -nF "syft \"docker:\${patched}\"" "$root/scripts/build_candidate.sh" | cut -d: -f1)
[ "$replacement_line" -lt "$sbom_line" ]
