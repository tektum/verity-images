#!/bin/bash
set -euo pipefail

# Regenerate committed pure APKO locks and propose one image-local branch and pull
# request per changed image. Publication keeps consuming the reviewed committed lock,
# so this script only proposes an update: it never builds, publishes, resolves
# packages for a build, combines images, or writes to the base branch.

targets=${1:?usage: refresh_apko_locks.sh TARGETS_JSON}
repository=${REPOSITORY:?REPOSITORY is required}
base_sha=${BASE_SHA:?BASE_SHA is required}
base_branch=${BASE_BRANCH:-main}
architectures=${APKO_ARCHITECTURES:-amd64,arm64}
run_url=${RUN_URL:-}

if [[ ! "$base_sha" =~ ^[0-9a-f]{40}$ ]]; then
  printf '::error title=Lock refresh refused::BASE_SHA "%s" is not a full commit SHA.\n' "$base_sha"
  exit 2
fi

if [[ -z "${GH_TOKEN:-}" ]]; then
  printf '::error title=Lock refresh credential missing::Store a GitHub App installation token or fine-grained token with contents:write and pull-requests:write in the APKO_LOCK_REFRESH_TOKEN repository secret. The workflow token is refused because a pull request it creates never starts the required lint, build-gate, and apk-gate checks.\n'
  exit 2
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

base_tree=$(gh api "repos/${repository}/git/commits/${base_sha}" --jq .tree.sha)
entries="$work/entries.jsonl"
summary="$work/summary.md"
proposals="$work/proposals.md"
: > "$proposals"
failures=0
proposed=0

# True when the automation branch's diff against the base branch is exactly this
# proposal: the same lock paths, the same contents, and nothing else. A branch that
# still carries a stale extra path is not identical, so the caller resets it to a
# fresh commit on the current base instead of leaving that path proposed.
proposal_published() {
  local branch=$1 entries=$2 entry path blob published desired changed
  desired=$(jq -r .path "$entries" | sort)
  if ! changed=$(gh api "repos/${repository}/compare/${base_sha}...${branch}" \
    --jq '.files[].filename' 2>/dev/null); then
    return 1
  fi
  [[ "$(sort <<<"$changed")" == "$desired" ]] || return 1
  while IFS= read -r entry; do
    path=$(jq -r .path <<<"$entry")
    blob=$(jq -r .blob <<<"$entry")
    published=$(gh api "repos/${repository}/contents/${path}?ref=${branch}" --jq .sha 2>/dev/null || true)
    [[ "$published" == "$blob" ]] || return 1
  done < "$entries"
}

open_pull_requests() {
  gh pr list --repo "$repository" --head "$1" --state open --json number --jq length
}

create_pull_request() {
  local branch=$1 context=$2 summary=$3 message=$4 body="$work/body.md"
  {
    printf 'Automated pure APKO lock refresh for "%s".\n\nRefreshed locks:\n\n' "$context"
    cat "$summary"
    printf '\nEach lock was regenerated with the repository-pinned apko against the signed\n'
    printf 'package repositories declared in the image configuration, so publication keeps\n'
    printf 'consuming a reviewed committed lock instead of resolving packages during a build.\n'
    printf '\nReview the package deltas, then merge. Only this image rebuilds.\n'
    if [[ -n "$run_url" ]]; then
      printf '\nProposed by %s\n' "$run_url"
    fi
  } > "$body"
  gh pr create --repo "$repository" --base "$base_branch" --head "$branch" \
    --title "$message" --body-file "$body"
}

mapfile -t images < <(jq -c '.images[]' "$targets")
for image in "${images[@]}"; do
  context=$(jq -r .context <<<"$image")
  branch=$(jq -r .branch <<<"$image")
  if [[ "$branch" == "$base_branch" || "$branch" != apko-lock/* ]]; then
    printf '::error title=Lock refresh refused::%s resolved to unusable refresh branch "%s".\n' \
      "$context" "$branch"
    exit 2
  fi
  message="chore(deps): refresh apko lock for ${context}"
  : > "$entries"
  : > "$summary"
  locked=0
  while IFS= read -r lock; do
    flavor=$(jq -r .flavor <<<"$lock")
    config=$(jq -r .config <<<"$lock")
    lockfile=$(jq -r .lockfile <<<"$lock")
    candidate="$work/candidate.json"
    if ! apko show-config "$config" >/dev/null || ! apko lock "$config" \
      --arch "$architectures" --output "$candidate"; then
      printf '::error title=Lock refresh failed::%s: apko could not lock %s.\n' "$context" "$config"
      locked=1
      break
    fi
    if cmp -s "$candidate" "$lockfile"; then
      continue
    fi
    jq -nc --arg path "$lockfile" --arg blob "$(git hash-object "$candidate")" \
      --rawfile content "$candidate" \
      '{path:$path,mode:"100644",type:"blob",content:$content,blob:$blob}' >> "$entries"
    printf -- '- %s (%s flavor)\n' "$lockfile" "$flavor" >> "$summary"
  done < <(jq -c '.locks[]' <<<"$image")

  if [[ "$locked" -ne 0 ]]; then
    failures=1
    continue
  fi
  if [[ ! -s "$entries" ]]; then
    continue
  fi

  head_sha=$(gh api "repos/${repository}/git/ref/heads/${branch}" --jq .object.sha 2>/dev/null || true)
  open=0
  if [[ -n "$head_sha" ]]; then
    open=$(open_pull_requests "$branch")
    if [[ "$open" -gt 1 ]]; then
      printf '::error title=Lock refresh refused::%s has %s open pull requests for branch "%s".\n' \
        "$context" "$open" "$branch"
      failures=1
      continue
    fi
    if proposal_published "$branch" "$entries"; then
      if [[ "$open" -eq 1 ]]; then
        continue
      fi
      # The branch already carries this proposal but lost its pull request, so the
      # pull request is recreated without a redundant commit or ref update.
      create_pull_request "$branch" "$context" "$summary" "$message"
      printf -- '- %s on %s\n' "$context" "$branch" >> "$proposals"
      proposed=$((proposed + 1))
      continue
    fi
  fi

  jq -s --arg base "$base_tree" '{base_tree:$base,tree:map({path,mode,type,content})}' \
    "$entries" > "$work/tree.json"
  tree_sha=$(gh api --method POST "repos/${repository}/git/trees" --input "$work/tree.json" --jq .sha)
  commit_sha=$(gh api --method POST "repos/${repository}/git/commits" \
    -f "message=${message}" -f "tree=${tree_sha}" -f "parents[]=${base_sha}" --jq .sha)
  if [[ -n "$head_sha" ]]; then
    gh api --method PATCH "repos/${repository}/git/refs/heads/${branch}" \
      -f "sha=${commit_sha}" -F force=true --silent
  else
    gh api --method POST "repos/${repository}/git/refs" \
      -f "ref=refs/heads/${branch}" -f "sha=${commit_sha}" --silent
  fi

  if [[ "$open" -eq 0 ]]; then
    create_pull_request "$branch" "$context" "$summary" "$message"
  fi
  printf -- '- %s on %s\n' "$context" "$branch" >> "$proposals"
  proposed=$((proposed + 1))
done

printf 'proposed %d image lock refresh(es)\n' "$proposed"
if [[ "$proposed" -gt 0 ]]; then
  {
    printf '## APKO lock refresh\n\n'
    cat "$proposals"
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
fi
if [[ "$failures" -ne 0 ]]; then
  exit 1
fi
