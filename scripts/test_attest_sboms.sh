#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin" "$work/sboms"
printf '%s\n' '{"name":"index","packages":[{"name":"index-only"}]}' > "$work/sboms/sbom-index.spdx.json"
printf '%s\n' '{"name":"x86","packages":[{"name":"crossbeam-epoch"}]}' > "$work/sboms/sbom-amd64.spdx.json"
printf '%s\n' '{"name":"arm","packages":[{"name":"google.golang.org/grpc"}]}' > "$work/sboms/sbom-arm64.spdx.json"

cat > "$work/bin/cosign" <<'EOF'
#!/bin/bash
printf '%q ' "$@" >> "$COSIGN_LOG"
if [[ "$1" == attest ]]; then
  while [[ "$1" != --predicate ]]; do shift; done
  printf 'name=%s package=%s ' "$(jq -r .name "$2")" "$(jq -r '.packages[0].name' "$2")" >> "$COSIGN_LOG"
fi
printf '\n' >> "$COSIGN_LOG"
EOF
chmod +x "$work/bin/cosign"
export COSIGN_LOG=$work/cosign.log

PATH="$work/bin:$PATH" \
  "$root/scripts/attest_sboms.sh" ghcr.io/tektum/demo sha256:123 "$work/sboms"

[[ $(wc -l < "$COSIGN_LOG") -eq 3 ]]
grep -Fq 'sign --yes ghcr.io/tektum/demo@sha256:123' "$COSIGN_LOG"
grep -Fq 'name=x86-verity-platform-amd64' "$COSIGN_LOG"
grep -Fq 'name=arm-verity-platform-arm64' "$COSIGN_LOG"
grep -Fq 'package=crossbeam-epoch' "$COSIGN_LOG"
grep -Fq 'package=google.golang.org/grpc' "$COSIGN_LOG"
if grep -Fq 'sbom-index.spdx.json' "$COSIGN_LOG"; then
  printf 'index SBOM was attested\n' >&2
  exit 1
fi

rm "$work/sboms/sbom-arm64.spdx.json"
if PATH="$work/bin:$PATH" \
  "$root/scripts/attest_sboms.sh" ghcr.io/tektum/demo sha256:123 "$work/sboms"; then
  printf 'one platform SBOM was accepted\n' >&2
  exit 1
fi
