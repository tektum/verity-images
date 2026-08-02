#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
cat > "$work/bin/curl" <<'EOF'
#!/bin/bash
set -euo pipefail
cat >> "$DEPLOYMENT_LOG"
printf '\n' >> "$DEPLOYMENT_LOG"
EOF
chmod +x "$work/bin/curl"
export DEPLOYMENT_LOG=$work/deployments.jsonl
export GITHUB_REPOSITORY=owner/repo
export GITHUB_SHA=1111111111111111111111111111111111111111
export GITHUB_TOKEN=github-token
PATH="$work/bin:$PATH" "$root/scripts/notify_squawk.sh" \
  ghcr.io/owner/demo sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc

[[ $(grep -c . "$DEPLOYMENT_LOG") -eq 2 ]]
jq -e -s 'length == 2 and all(.[]; .ref == "1111111111111111111111111111111111111111" and .task == "squawk-sbom" and .auto_merge == false and .required_contexts == [] and .payload.schema_version == 1 and (.payload | keys | sort == ["image_ref","logical_image_ref","platform","schema_version","subject_digest"])) and ([.[].payload.platform] | sort == ["linux/amd64","linux/arm64"])' "$DEPLOYMENT_LOG" >/dev/null
if grep -Eq 'SQUAWK_URL|SQUAWK_AUDIENCE|DESCOPE|oidc' "$DEPLOYMENT_LOG"; then
  exit 1
fi
