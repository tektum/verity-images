#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin" "$work/repo"

git_commit() {
  git -C "$work/repo" -c user.email=test@example.com -c user.name=test commit --quiet --allow-empty -m "$1"
}
git -C "$work/repo" init --quiet --initial-branch=main
git_commit base
base_sha=$(git -C "$work/repo" rev-parse HEAD)
git_commit head

cat > "$work/bin/gh" <<'EOF2'
#!/bin/bash
set -euo pipefail
printf '%q ' "$@" >> "$GH_LOG"
printf '\n' >> "$GH_LOG"
if [ "$1" = api ]; then
  cat "$RUNS_FIXTURE"
fi
EOF2
chmod +x "$work/bin/gh"

export GH_LOG="$work/gh.log"
export REPOSITORY=owner/repo
export GITHUB_STEP_SUMMARY="$work/summary.md"
export RUNS_FIXTURE="$work/runs.json"

runs() {
  jq -n -c --arg sha "$1" '{workflow_runs: [{
    event: "push", head_branch: "main", status: "completed", conclusion: "success",
    head_repository: {full_name: "owner/repo"}, head_sha: $sha,
    created_at: "2026-11-09T00:00:00Z", html_url: "https://github.com/owner/repo/actions/runs/1"}]}'
}

# The newest successful main push run that is an ancestor of HEAD is the base.
runs "$base_sha" > "$RUNS_FIXTURE"
: > "$GH_LOG"
(cd "$work/repo" && PATH="$work/bin:$PATH" "$root/scripts/dispatch_catalog_catchup.sh")
grep -Fq "workflow run build.yaml --repo owner/repo --ref main -f base-sha=${base_sha}" "$GH_LOG"
grep -Fq "$base_sha" "$work/summary.md"

# The published catalog source commit is not consulted at all.
if grep -q 'catalog.json' "$GH_LOG"; then
  printf 'catch-up read the catalog source commit\n' >&2
  exit 1
fi

# A malformed run head is refused without dispatching anything.
runs "not-a-sha" > "$RUNS_FIXTURE"
: > "$GH_LOG"
if (cd "$work/repo" && PATH="$work/bin:$PATH" "$root/scripts/dispatch_catalog_catchup.sh"); then
  printf 'a malformed base commit was accepted\n' >&2
  exit 1
fi
if grep -q 'workflow run' "$GH_LOG"; then
  printf 'a malformed base commit still dispatched a build\n' >&2
  exit 1
fi

# A well-formed but unrelated commit (not an ancestor of HEAD) is refused.
empty_tree=$(git -C "$work/repo" hash-object -t tree /dev/null)
other_sha=$(git -C "$work/repo" -c user.email=test@example.com -c user.name=test \
  commit-tree -m orphan "$empty_tree")
runs "$other_sha" > "$RUNS_FIXTURE"
: > "$GH_LOG"
if (cd "$work/repo" && PATH="$work/bin:$PATH" "$root/scripts/dispatch_catalog_catchup.sh"); then
  printf 'a non-ancestor commit was accepted\n' >&2
  exit 1
fi
if grep -q 'workflow run' "$GH_LOG"; then
  printf 'a non-ancestor commit still dispatched a build\n' >&2
  exit 1
fi
