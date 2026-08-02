#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
for arch in amd64 arm64; do
  printf '{"_type":"https://in-toto.io/Statement/v1","subject":[{"name":"ghcr.io/owner/demo","digest":{"sha256":"%s"}}]}' "${arch:0:1}" > "$work/$arch.statement"
  payload=$(base64 -w0 "$work/$arch.statement")
  jq -nc --arg payload "$payload" '{dsseEnvelope:{payload:$payload}}' > "$work/$arch.bundle"
done
cat > "$work/bin/curl" <<'EOF'
#!/bin/bash
set -euo pipefail
if [[ "$*" == *"/deployments"* ]]; then
  cat >> "$DEPLOYMENT_LOG"
  printf '\n' >> "$DEPLOYMENT_LOG"
else
  printf '%s\n' "$*" >> "$OIDC_LOG"
  printf '{"value":"oidc-token"}\n'
fi
EOF
chmod +x "$work/bin/curl"
export ACTIONS_ID_TOKEN_REQUEST_TOKEN=request-token
export ACTIONS_ID_TOKEN_REQUEST_URL='https://oidc.test/token?x=1'
export DEPLOYMENT_LOG=$work/deployments.jsonl
export GITHUB_REF=refs/heads/main
export GITHUB_REPOSITORY=owner/repo
export GITHUB_REPOSITORY_ID=123
export GITHUB_SHA=1111111111111111111111111111111111111111
export GITHUB_TOKEN=github-token
export OIDC_LOG=$work/oidc.log
PATH="$work/bin:$PATH" "$root/scripts/notify_squawk.sh" \
  ghcr.io/owner/demo sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  "$work/amd64.bundle" sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  "$work/arm64.bundle" sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc

[[ $(grep -c . "$DEPLOYMENT_LOG") -eq 2 ]]
jq -e -s 'length == 2 and all(.[]; .ref == "refs/heads/main" and .task == "squawk-sbom" and .auto_merge == false and .required_contexts == [] and .payload.schema_version == 1 and .payload.oidc_token == "oidc-token") and ([.[].payload.platform] | sort == ["linux/amd64","linux/arm64"])' "$DEPLOYMENT_LOG" >/dev/null
[[ $(wc -l < "$OIDC_LOG") -eq 2 ]]
grep -Fq 'audience=urn%3Asquawk%3Av1%3A123%3A1111111111111111111111111111111111111111%3Alinux%252Famd64' "$OIDC_LOG"
if grep -Eq 'SQUAWK_URL|SQUAWK_AUDIENCE|DESCOPE' "$DEPLOYMENT_LOG" "$OIDC_LOG"; then
  exit 1
fi
