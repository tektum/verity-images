#!/bin/sh
set -eu

source=${1:?usage: replace_gosu.sh SOURCE ARCH BASE TARGET}
arch=${2:?usage: replace_gosu.sh SOURCE ARCH BASE TARGET}
base=${3:?usage: replace_gosu.sh SOURCE ARCH BASE TARGET}
target=${4:?usage: replace_gosu.sh SOURCE ARCH BASE TARGET}

fail() {
  printf 'invalid gosu metadata: %s\n' "$1" >&2
  exit 1
}

unknown_key=$(awk -F: '
  { key = $1; gsub(/^[[:space:]]+|[[:space:]]+$/, "", key) }
  key ~ /^gosu-/ && key !~ /^gosu-(version|source|source-sha256|builder|x-sys-version|amd64-sha256|arm64-sha256|path)$/ { print key; exit }
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
gosu_source=$(read_value gosu-source)
source_checksum=$(read_value gosu-source-sha256)
builder=$(read_value gosu-builder)
x_sys_version=$(read_value gosu-x-sys-version)
amd64_checksum=$(read_value gosu-amd64-sha256)
arm64_checksum=$(read_value gosu-arm64-sha256)
gosu_path=$(read_value gosu-path)

printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+(\.[0-9]+)?$' || fail "invalid gosu-version"
printf '%s\n' "$gosu_source" | grep -Eq '^[0-9a-f]{40}$' || fail "invalid gosu-source"
printf '%s\n' "$source_checksum" | grep -Eq '^[0-9a-f]{64}$' || fail "invalid gosu-source-sha256"
printf '%s\n' "$builder" | grep -Eq '^docker\.io/library/golang@sha256:[0-9a-f]{64}$' || fail "invalid gosu-builder"
printf '%s\n' "$x_sys_version" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' || fail "invalid gosu-x-sys-version"
printf '%s\n' "$amd64_checksum" | grep -Eq '^[0-9a-f]{64}$' || fail "invalid gosu-amd64-sha256"
printf '%s\n' "$arm64_checksum" | grep -Eq '^[0-9a-f]{64}$' || fail "invalid gosu-arm64-sha256"
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
trap 'rm -rf "$work"' 0
curl -fsSL "https://github.com/tianon/gosu/archive/${gosu_source}.tar.gz" \
  -o "$work/source.tar.gz"
if ! printf '%s  %s\n' "$source_checksum" "$work/source.tar.gz" \
  | sha256sum -c - >/dev/null 2>&1; then
  fail "gosu source checksum mismatch"
fi
tar -xzf "$work/source.tar.gz" -C "$work"
mv "$work/gosu-$gosu_source" "$work/source"
source_version=$(awk -F '"' '/^const Version = "/ { print $2 }' "$work/source/version.go")
[ "$source_version" = "$version" ] || fail "gosu-version does not match source"
mkdir "$work/output" "$work/install"

docker build --platform linux/amd64 --build-arg "GO_BUILDER=$builder" \
  --build-arg "GOSU_X_SYS_VERSION=$x_sys_version" \
  --build-arg "TARGETARCH=$arch" --output "type=local,dest=$work/output" \
  --file - "$work" <<'EOF'
ARG GO_BUILDER=scratch
FROM ${GO_BUILDER} AS build
WORKDIR /src
COPY source/ .
ARG GOSU_X_SYS_VERSION
ARG TARGETARCH
ENV CGO_ENABLED=0 GOOS=linux GOTOOLCHAIN=local
RUN go mod edit -require="golang.org/x/sys@${GOSU_X_SYS_VERSION}" \
 && go mod tidy \
 && GOARCH="${TARGETARCH}" go build -mod=readonly -trimpath -buildvcs=false \
    -ldflags '-d -w' -o /gosu .
FROM scratch
COPY --from=build /gosu /gosu
EOF

if ! printf '%s  %s\n' "$checksum" "$work/output/gosu" \
  | sha256sum -c - >/dev/null 2>&1; then
  fail "gosu-$arch checksum mismatch"
fi
mv "$work/output/gosu" "$work/install/gosu"
chmod 0755 "$work/install/gosu"
docker build --platform "linux/$arch" --provenance=false --build-arg "BASE=$base" \
  --build-arg "GOSU_PATH=$gosu_path" --output type=image,unpack=true \
  --tag "$target" --file - "$work/install" <<'EOF'
ARG BASE=scratch
FROM ${BASE}
ARG GOSU_PATH
COPY --chown=0:0 --chmod=0755 gosu ${GOSU_PATH}
EOF
