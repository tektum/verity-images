#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cosign_version=3.0.6
cosign_sha256=c956e5dfcac53d52bcf058360d579472f0c1d2d9b69f55209e256fe7783f4c74
cosign_bin=$work/cosign
curl -fsSL "https://github.com/sigstore/cosign/releases/download/v${cosign_version}/cosign-linux-amd64" -o "$cosign_bin"
printf '%s  %s\n' "$cosign_sha256" "$cosign_bin" | sha256sum -c -
chmod +x "$cosign_bin"
[[ $($cosign_bin version | awk '/GitVersion:/ { print $2 }') == "v${cosign_version}" ]]
mkdir "$work/bin" "$work/sboms"
printf '%s\n' '{"name":"index"}' > "$work/sboms/sbom-index.spdx.json"
printf '%s\n' '{"name":"x86","packages":[{"name":"demo","versionInfo":"1","externalRefs":[{"referenceType":"purl","referenceLocator":"pkg:npm/demo@1"}]}]}' > "$work/sboms/sbom-x86_64.spdx.json"
printf '%s\n' '{"name":"arm","packages":[{"name":"demo","versionInfo":"1","externalRefs":[{"referenceType":"purl","referenceLocator":"pkg:npm/demo@1"}]}]}' > "$work/sboms/sbom-aarch64.spdx.json"

cat > "$work/bin/cosign" <<'EOF'
#!/bin/bash
printf '%q ' "$@" >> "$COSIGN_LOG"
if [[ "$1" == attest ]]; then
  while [[ "$1" != --predicate ]]; do shift; done
  printf 'name=%s ' "$(jq -r .name "$2")" >> "$COSIGN_LOG"
fi
printf '\n' >> "$COSIGN_LOG"
EOF
chmod +x "$work/bin/cosign"
export COSIGN_LOG=$work/cosign.log

PATH="$work/bin:$PATH" \
  "$root/scripts/attest_sboms.sh" ghcr.io/tektum/demo sha256:123 "$work/sboms"

[[ $(wc -l < "$COSIGN_LOG") -eq 5 ]]
grep -Fq 'sign --yes ghcr.io/tektum/demo@sha256:123' "$COSIGN_LOG"
grep -Fq 'name=x86-verity-platform-amd64' "$COSIGN_LOG"
grep -Fq 'name=arm-verity-platform-arm64' "$COSIGN_LOG"
grep -Fq 'attest --yes --type cyclonedx' "$COSIGN_LOG"
jq -e '.bomFormat == "CycloneDX" and .components[0].purl == "pkg:npm/demo@1"' \
  "$work/sboms/sbom-amd64.cyclonedx.json" >/dev/null
jq -e '.bomFormat == "CycloneDX" and .components[0].purl == "pkg:npm/demo@1"' \
  "$work/sboms/sbom-arm64.cyclonedx.json" >/dev/null
if grep -Fq 'sbom-index.spdx.json' "$COSIGN_LOG"; then
  printf 'index SBOM was attested\n' >&2
  exit 1
fi

rm "$work/sboms/sbom-aarch64.spdx.json"
if PATH="$work/bin:$PATH" \
  "$root/scripts/attest_sboms.sh" ghcr.io/tektum/demo sha256:123 "$work/sboms"; then
  printf 'one platform SBOM was accepted\n' >&2
  exit 1
fi

for format in spdx cyclonedx; do
  predicate=$work/$format.json
  bundle=$work/$format.bundle.json
  printf '{"format":"%s","component":"demo"}\n' "$format" > "$predicate"
  COSIGN_PASSWORD='' "$cosign_bin" generate-key-pair --output-key-prefix "$work/$format" >/dev/null
  "$cosign_bin" signing-config create --no-default-fulcio --no-default-oidc --no-default-rekor --no-default-tsa --out "$work/signing-config.json"
  COSIGN_PASSWORD='' "$cosign_bin" sign-blob --yes --key "$work/$format.key" --signing-config "$work/signing-config.json" --bundle "$bundle" "$predicate" >/dev/null
  COSIGN_PASSWORD='' "$cosign_bin" verify-blob --insecure-ignore-tlog --key "$work/$format.pub" --bundle "$bundle" "$predicate" >/dev/null
  printf 'tampered\n' >> "$predicate"
  if COSIGN_PASSWORD='' "$cosign_bin" verify-blob --insecure-ignore-tlog --key "$work/$format.pub" --bundle "$bundle" "$predicate" >/dev/null 2>&1; then
    printf 'tampered %s predicate verified\n' "$format" >&2
    exit 1
  fi
done
