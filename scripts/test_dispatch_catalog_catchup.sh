#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin" "$work/repo"

git -C "$work/repo" init --quiet --initial-branch=main
git -C "$work/repo" -c user.email=test@example.com -c user.name=test commit --quiet --allow-empty -m base
base_sha=$(git -C "$work/repo" rev-parse HEAD)
git -C "$work/repo" -c user.email=test@example.com -c user.name=test commit --quiet --allow-empty -m head

cat > "$work/bin/gh" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%q ' "$@" >> "$GH_LOG"
printf '\n' >> "$GH_LOG"
EOF
chmod +x "$work/bin/gh"

cat > "$work/bin/curl" <<'EOF'
#!/bin/bash
set -euo pipefail
cat "$CATALOG_FIXTURE"
EOF
chmod +x "$work/bin/curl"

export GH_LOG="$work/gh.log"
export REPOSITORY=owner/repo
export GITHUB_STEP_SUMMARY="$work/summary.md"

# A valid, ancestor source commit dispatches a recovery build.
jq -n -c --arg sha "$base_sha" '{source: {commit: $sha}}' > "$work/catalog.json"
export CATALOG_FIXTURE="$work/catalog.json"
: > "$GH_LOG"
(cd "$work/repo" && PATH="$work/bin:$PATH" "$root/scripts/dispatch_catalog_catchup.sh")
grep -Fq "workflow run build.yaml --repo owner/repo --ref main -f base-sha=${base_sha}" "$GH_LOG"
grep -Fq "$base_sha" "$work/summary.md"

# A malformed source commit is refused without dispatching anything.
jq -n -c '{source: {commit: "not-a-sha"}}' > "$work/catalog.json"
: > "$GH_LOG"
if (cd "$work/repo" && PATH="$work/bin:$PATH" "$root/scripts/dispatch_catalog_catchup.sh"); then
  printf 'a malformed source commit was accepted\n' >&2
  exit 1
fi
if grep -q 'workflow run' "$GH_LOG"; then
  printf 'a malformed source commit still dispatched a build\n' >&2
  exit 1
fi

# A well-formed but unrelated commit (not an ancestor of HEAD) is refused.
empty_tree=$(git -C "$work/repo" hash-object -t tree /dev/null)
other_sha=$(git -C "$work/repo" -c user.email=test@example.com -c user.name=test \
  commit-tree -m orphan "$empty_tree")
jq -n -c --arg sha "$other_sha" '{source: {commit: $sha}}' > "$work/catalog.json"
: > "$GH_LOG"
if (cd "$work/repo" && PATH="$work/bin:$PATH" "$root/scripts/dispatch_catalog_catchup.sh"); then
  printf 'a non-ancestor commit was accepted\n' >&2
  exit 1
fi
if grep -q 'workflow run' "$GH_LOG"; then
  printf 'a non-ancestor commit still dispatched a build\n' >&2
  exit 1
fi
