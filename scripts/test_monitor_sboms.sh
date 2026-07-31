#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin" "$work/bodies"

new_digest=sha256:$(printf 'new-manifest' | sha256sum | cut -d' ' -f1)
existing_digest=sha256:$(printf 'existing-manifest' | sha256sum | cut -d' ' -f1)
clean_digest=sha256:$(printf 'clean-manifest' | sha256sum | cut -d' ' -f1)
cat > "$work/catalog.json" <<EOF
{
  "schemaVersion": 2,
  "policy": {
    "certificateIdentity": "https://github.com/tektum/verity-images/.github/workflows/build.yaml@refs/heads/main",
    "certificateIssuer": "https://token.actions.githubusercontent.com"
  },
  "images": [
    {"name":"new","version":"1","digest":"$new_digest","reference":"ghcr.io/tektum/new@$new_digest"},
    {"name":"existing","version":"1","digest":"$existing_digest","reference":"ghcr.io/tektum/existing@$existing_digest"},
    {"name":"clean","version":"1","digest":"$clean_digest","reference":"ghcr.io/tektum/clean@$clean_digest"}
  ]
}
EOF

cat > "$work/expected.json" <<'EOF'
{"include":[{"name":"new","tag_version":"1"},{"name":"existing","tag_version":"1"},{"name":"clean","tag_version":"1"}]}
EOF

cat > "$work/bin/cosign" <<'EOF'
#!/bin/bash
reference=${!#}
name=${reference#ghcr.io/tektum/}
name=${name%@*}
index=$(printf '{"predicate":{"name":"%s-index","creationInfo":{"created":"2026-02-01T00:00:00Z"},"packages":[{"name":"source","externalRefs":[{"referenceType":"purl","referenceLocator":"pkg:github/tektum/%s"}]}]}}' "$name" "$name" | base64 -w0)
old=$(printf '{"predicate":{"name":"%s-amd64-doc","creationInfo":{"created":"2026-01-01T00:00:00Z"},"packages":[{"name":"old","externalRefs":[{"referenceType":"purl","referenceLocator":"pkg:apk/wolfi/old"}]}]}}' "$name" | base64 -w0)
amd64=$(printf '{"predicate":{"name":"%s-verity-platform-amd64","creationInfo":{"created":"2026-02-01T00:00:00Z"},"packages":[{"name":"%s-amd64","externalRefs":[{"referenceType":"purl","referenceLocator":"pkg:apk/wolfi/%s?arch=x86_64"}]}]}}' "$name" "$name" "$name" | base64 -w0)
arm64=$(printf '{"predicate":{"name":"%s-verity-platform-arm64","creationInfo":{"created":"2026-02-01T00:00:00Z"},"packages":[{"name":"%s-arm64","externalRefs":[{"referenceType":"purl","referenceLocator":"pkg:apk/wolfi/%s?arch=aarch64"}]}]}}' "$name" "$name" "$name" | base64 -w0)
printf '{"payload":"%s"}\n{"payload":"%s"}\n{"payload":"%s"}\n' "$index" "$old" "$amd64"
if [[ "${ONE_PLATFORM:-false}" != true ]]; then
  printf '{"payload":"%s"}\n' "$arm64"
fi
EOF

cat > "$work/bin/docker" <<'EOF'
#!/bin/bash
for argument in "$@"; do
  [[ "$argument" == ghcr.io/*:* ]] && reference=$argument
done
name=${reference#ghcr.io/tektum/}
name=${name%%:*}
printf '%s-manifest' "$name"
EOF

cat > "$work/bin/grype" <<'EOF'
#!/bin/bash
sbom=${1#sbom:}
name=$(jq -er '.packages[0].name' "$sbom")
while [[ $# -gt 0 ]]; do
  if [[ "$1" == --file ]]; then
    output=$2
    break
  fi
  shift
done
if [[ "${MALFORMED:-false}" == true && "$name" == existing-amd64 ]]; then
  printf '%s\n' '{"matches":{}}' > "$output"
  exit
fi
if [[ "$name" == clean-* ]]; then
  printf '%s\n' '{"matches":[]}' > "$output"
else
  cat > "$output" <<'JSON'
{"matches":[{"artifact":{"name":"openssl","version":"1"},"vulnerability":{"id":"CVE-TEST","severity":"High","fix":{"versions":["2"]}}}]}
JSON
fi
EOF

cat > "$work/bin/gh" <<'EOF'
#!/bin/bash
printf '%q ' "$@" >> "$GH_LOG"
printf '\n' >> "$GH_LOG"
if [[ "$1" == api ]]; then
  if [[ "${DUPLICATE:-false}" == true ]]; then
    printf '%s\n' '[[{"number":8,"title":"[CVE] existing:1","state":"closed","body":"<!-- sbom-cve-monitor -->","user":{"login":"github-actions[bot]"}},{"number":10,"title":"[CVE] existing:1","state":"open","body":"<!-- sbom-cve-monitor -->","user":{"login":"github-actions[bot]"}}]]'
  else
    printf '%s\n' '[[{"number":8,"title":"[CVE] existing:1","state":"closed","body":"<!-- sbom-cve-monitor -->","user":{"login":"github-actions[bot]"}},{"number":7,"title":"[CVE] clean:1","state":"open","body":"<!-- sbom-cve-monitor -->","user":{"login":"github-actions[bot]"}},{"number":6,"title":"[CVE] clean:1","state":"open","body":"<!-- sbom-cve-monitor -->","user":{"login":"someone"}},{"number":9,"title":"[CVE] retired:1","state":"open","body":"<!-- sbom-cve-monitor -->","user":{"login":"github-actions[bot]"}}]]'
  fi
elif [[ "$1 $2" == "issue create" || "$1 $2" == "issue edit" ]]; then
  for ((index=1; index <= $#; index++)); do
    if [[ "${!index}" == --body-file ]]; then
      body_index=$((index + 1))
      cp "${!body_index}" "$GH_BODY_DIR/${1}-${2}-${3}.md"
    fi
  done
fi
EOF

chmod +x "$work/bin/cosign" "$work/bin/docker" "$work/bin/grype" "$work/bin/gh"
export GH_BODY_DIR="$work/bodies"
export GH_LOG="$work/gh.log"
export GITHUB_REPOSITORY=owner/repo
export GITHUB_STEP_SUMMARY="$work/summary.md"
export RUN_URL=https://example.test/run
PATH="$work/bin:$PATH" "$root/scripts/monitor_sboms.sh" "$work/catalog.json" "$work/expected.json"

grep -Fq 'issue create --repo owner/repo --title \[CVE\]\ new:1' "$GH_LOG"
grep -Fq 'issue reopen 8 --repo owner/repo' "$GH_LOG"
grep -Fq 'issue edit 8 --repo owner/repo' "$GH_LOG"
grep -Fq 'issue close 7 --repo owner/repo' "$GH_LOG"
grep -Fq 'issue close 9 --repo owner/repo' "$GH_LOG"
grep -Fq '| new:1 | 1 | {"high":1} |' "$GITHUB_STEP_SUMMARY"
grep -Fq 'CVE-TEST' "$work/bodies/issue-create---repo.md"

cp "$work/catalog.json" "$work/tampered.json"
jq '.policy.certificateIdentity = "https://attacker.example/workflow"' \
  "$work/catalog.json" > "$work/tampered.json"
if PATH="$work/bin:$PATH" \
  "$root/scripts/monitor_sboms.sh" "$work/tampered.json" "$work/expected.json"; then
  printf 'tampered catalog was accepted\n' >&2
  exit 1
fi

: > "$GH_LOG"
stale=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
jq --arg digest "$stale" '
  .images[0].digest = $digest |
  .images[0].reference = ("ghcr.io/tektum/new@" + $digest)
' "$work/catalog.json" > "$work/stale.json"
if PATH="$work/bin:$PATH" \
  "$root/scripts/monitor_sboms.sh" "$work/stale.json" "$work/expected.json"; then
  printf 'stale catalog digest was accepted\n' >&2
  exit 1
fi
if grep -Eq '^issue (create|edit|reopen|close)' "$GH_LOG"; then
  printf 'stale catalog digest changed issues\n' >&2
  exit 1
fi

: > "$GH_LOG"
if MALFORMED=true PATH="$work/bin:$PATH" \
  "$root/scripts/monitor_sboms.sh" "$work/catalog.json" "$work/expected.json"; then
  printf 'malformed Grype output was accepted\n' >&2
  exit 1
fi
if grep -Eq '^issue (create|edit|reopen|close)' "$GH_LOG"; then
  printf 'malformed Grype output changed issues\n' >&2
  exit 1
fi

: > "$GH_LOG"
if ONE_PLATFORM=true PATH="$work/bin:$PATH" \
  "$root/scripts/monitor_sboms.sh" "$work/catalog.json" "$work/expected.json" \
  >/dev/null 2>&1; then
  printf 'one platform attestation was accepted\n' >&2
  exit 1
fi
if grep -Eq '^issue (create|edit|reopen|close)' "$GH_LOG"; then
  printf 'one platform attestation changed issues\n' >&2
  exit 1
fi

: > "$GH_LOG"
if DUPLICATE=true PATH="$work/bin:$PATH" \
  "$root/scripts/monitor_sboms.sh" "$work/catalog.json" "$work/expected.json"; then
  printf 'duplicate managed issues were accepted\n' >&2
  exit 1
fi
if grep -Eq '^issue (create|edit|reopen|close)' "$GH_LOG"; then
  printf 'duplicate managed issues changed issues\n' >&2
  exit 1
fi
