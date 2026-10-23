#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
script="$root/scripts/build_candidate.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
export APKO_LOG="$work/apko.log" APKO_ARGS_LOG="$work/apko-args.log" MELANGE_LOG="$work/melange.log" SYFT_LOG="$work/syft.log"

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
printf '%s\n' "$*" >>"$APKO_ARGS_LOG"
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
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == --sbom-path ]]; then
        mkdir -p "$2"
        printf '%s\n' '{"name":"apko-index","packages":[]}' >"$2/sbom-index.spdx.json"
        printf '%s\n' '{"name":"apko-amd64","packages":[]}' >"$2/sbom-x86_64.spdx.json"
        printf '%s\n' '{"name":"apko-arm64","packages":[]}' >"$2/sbom-aarch64.spdx.json"
        break
      fi
      shift
    done
    ;;
esac
EOF

cat >"$work/bin/docker" <<'EOF'
#!/bin/sh
set -eu
[ "$1" = load ]
cat >/dev/null
EOF

cat >"$work/bin/syft" <<'EOF'
#!/bin/bash
set -euo pipefail
image=${1#docker:}
arch=${image##*-}
[[ "${SYFT_FAIL_ARCH:-}" != "$arch" ]]
[[ "$2" == -o && "$3" == spdx-json=* ]]
output=${3#spdx-json=}
jq -n --arg image "$image" --arg arch "$arch" '{
  name: $image,
  packages: [
    {name: "crossbeam-epoch", externalRefs: [{referenceType: "purl", referenceLocator: "pkg:cargo/crossbeam-epoch@0.9.20"}]},
    {name: "google.golang.org/grpc", externalRefs: [{referenceType: "purl", referenceLocator: "pkg:golang/google.golang.org/grpc@v1.83.2"}]}
  ],
  creationInfo: {comment: ("syft-final-image-" + $arch)}
}' >"$output"
printf '%s %s\n' "$image" "$output" >>"$SYFT_LOG"
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
variant: caddy
repository: @LOCAL_REPOSITORY@
key: @LOCAL_KEY@
godebug: @GODEBUG@
EOF
: >"$work/caddy/melange.yaml"
printf 'GOFIPS140=v1.0.0\n' >"$work/caddy/fips.env"
run_candidate "$work/caddy" caddy plain
for arch in amd64 arm64; do
  sbom="$work/dist/caddy/sbom/sbom-${arch}.spdx.json"
  [[ -f "$sbom" ]]
  [[ $(jq -r '.creationInfo.comment' "$sbom") == "syft-final-image-${arch}" ]]
  jq -e '.packages | map(.name) | contains(["crossbeam-epoch", "google.golang.org/grpc"])' "$sbom" >/dev/null
done
[[ $(find "$work/dist/caddy/sbom" -maxdepth 1 -name 'sbom-*.spdx.json' | wc -l) -eq 2 ]]
[[ -f "$work/dist/caddy/apko-sbom/sbom-index.spdx.json" ]]
[[ -f "$work/dist/caddy/apko-sbom/sbom-x86_64.spdx.json" ]]
[[ -f "$work/dist/caddy/apko-sbom/sbom-aarch64.spdx.json" ]]
if grep -R -q 'apko-' "$work/dist/caddy/sbom"; then
  printf 'APKO-native SBOM replaced a signed platform inventory\n' >&2
  exit 1
fi
grep -q '^variant: caddy$' "$APKO_LOG"
grep -q '^godebug: fips140=off$' "$APKO_LOG"

: >"$APKO_LOG"
: >"$MELANGE_LOG"
run_candidate "$work/caddy" caddy-fips fips
grep -q '^variant: caddy$' "$APKO_LOG"
grep -q '^godebug: fips140=only$' "$APKO_LOG"
grep -q "start build $work/caddy/melange.yaml --arch amd64.*--env-file $work/caddy/fips.env" "$MELANGE_LOG"
grep -q "start build $work/caddy/melange.yaml --arch arm64.*--env-file $work/caddy/fips.env" "$MELANGE_LOG"
grep -q -- "--pipeline-dir $root/pipelines" "$MELANGE_LOG"
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
grep -q -- "--pipeline-dir $root/pipelines" "$MELANGE_LOG"
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

traefik="$root/images/traefik"
grep -Fxq 'flavors: [plain, fips]' "$traefik/metadata.yaml"
grep -Fxq 'GOFIPS140=v1.0.0' "$traefik/fips.env"
[[ $(find "$traefik" -name '*melange.yaml' | wc -l) -eq 1 ]]
if grep -q 'openssl-fips-provider' "$traefik"/{apko.yaml,melange.yaml,metadata.yaml,fips.env}; then
  exit 1
fi

grep -Fq 'post-patch.Dockerfile' "$script"
# A stream migrated to Wolfi no longer carries a patched post-patch definition.
mariadb="$root/patched/mariadb-12.3-ubi10/post-patch.Dockerfile"
if [[ -d "$root/patched/mariadb-12.3-ubi10" ]]; then
  [[ -f "$mariadb" ]]
  grep -Fq 'microdnf update -y libarchive p11-kit p11-kit-trust perl-DBI' "$mariadb"
  grep -Fxq 'USER mysql' "$mariadb"
fi

grep -Fq "docker image history \"\$image\"" "$script"
grep -Fq "docker image save \"\$image\" --output \"\$archive\"" "$script"
grep -Fq '/run/containerd/containerd.sock' "$script"
grep -Fq 'images import' "$script"
grep -Fq -- "--platform \"linux/\$image_arch\" --snapshotter overlayfs \"\$archive\"" "$script"
unpack_line=$(grep -nF 'images import' "$script" | cut -d: -f1)
scan_line=$(grep -nF 'trivy image --image-src docker --scanners vuln --pkg-types library' "$script" | cut -d: -f1)
[[ "$unpack_line" -lt "$scan_line" ]]

if SYFT_FAIL_ARCH=arm64 run_candidate "$work/caddy" syft-failure plain; then
  printf 'Wolfi candidate accepted a failed platform SBOM scan\n' >&2
  exit 1
fi
[[ -f "$work/dist/syft-failure/sbom/sbom-amd64.spdx.json" ]]
[[ ! -e "$work/dist/syft-failure/sbom/sbom-arm64.spdx.json" ]]

# Native arm64 job: compile only arm64, export its job-local public key, stop before apko.
: >"$MELANGE_LOG"
: >"$APKO_ARGS_LOG"
(cd "$work" && PATH="$work/bin:$PATH" GITHUB_SHA=test NATIVE_ARM64_ONLY=true "$script" "$work/caddy" native-arm64 plain wolfi 1)
[[ $(grep -c "^start " "$MELANGE_LOG") -eq 1 ]]
grep -q -- '--arch arm64' "$MELANGE_LOG"
if grep -q -- '--arch amd64' "$MELANGE_LOG"; then
  printf 'native arm64 job compiled amd64\n' >&2
  exit 1
fi
[[ -f "$work/dist/native-arm64/packages/melange-arm64.rsa.pub" ]]
# An APKINDEX signature embeds the signing key's name, so apko can only resolve the
# appended key when it was generated under a name distinct from the amd64 key.
grep -q -- '--signing-key [^ ]*/melange-arm64.rsa ' "$MELANGE_LOG"
[[ ! -e "$work/dist/native-arm64/packages/melange.rsa.pub" ]]
[[ ! -s "$APKO_ARGS_LOG" ]]

# Image job with prebuilt arm64: compile only amd64, merge the arm64 tree, trust its key.
: >"$MELANGE_LOG"
: >"$APKO_ARGS_LOG"
mkdir -p "$work/prebuilt/aarch64"
: >"$work/prebuilt/aarch64/caddy.apk"
: >"$work/prebuilt/melange-arm64.rsa.pub"
(cd "$work" && PATH="$work/bin:$PATH" GITHUB_SHA=test PREBUILT_ARM64="$work/prebuilt" "$script" "$work/caddy" merged plain wolfi 1)
[[ $(grep -c "^start " "$MELANGE_LOG") -eq 1 ]]
grep -q -- '--arch amd64' "$MELANGE_LOG"
if grep -q -- '--arch arm64' "$MELANGE_LOG"; then
  printf 'image job emulated the prebuilt arm64 compile\n' >&2
  exit 1
fi
[[ -f "$work/dist/merged/packages/aarch64/caddy.apk" ]]
[[ $(grep -c -- '--keyring-append dist/merged/packages/melange-arm64.rsa.pub' "$APKO_ARGS_LOG") -eq 2 ]]
if grep -q -- '--keyring-append [^ ]*/melange.rsa.pub' "$APKO_ARGS_LOG"; then
  printf 'prebuilt arm64 key collides with the amd64 key name\n' >&2
  exit 1
fi
grep -q '^lock ' "$APKO_ARGS_LOG"
grep -q '^build ' "$APKO_ARGS_LOG"
