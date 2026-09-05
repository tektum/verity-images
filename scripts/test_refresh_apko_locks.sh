#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
script="$root/scripts/refresh_apko_locks.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/state" "$work/repo/images/alpha" "$work/repo/images/beta"

export APKO_LOG="$work/apko.log"
export GH_LOG="$work/gh.log"
export STATE="$work/state"
export REPOSITORY=owner/repo
BASE_SHA=$(printf '%040d' 1)
export BASE_SHA
export GH_TOKEN=refresh-token
export GITHUB_STEP_SUMMARY="$work/summary.md"

cat >"$work/bin/apko" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >>"$APKO_LOG"
config=$2
case "$1" in
  show-config)
    if [[ ! -f "$config" ]]; then
      exit 1
    fi
    ;;
  lock)
    output=""
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == --output ]]; then
        output=$2
      fi
      shift
    done
    if [[ -f "${config}.fail" ]]; then
      printf 'unable to resolve %s\n' "$config" >&2
      exit 1
    fi
    if [[ -f "${config}.next" ]]; then
      cp "${config}.next" "$output"
    else
      cp "${config%.yaml}.lock.json" "$output"
    fi
    ;;
esac
EOF

cat >"$work/bin/gh" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >>"$GH_LOG"
slug() { printf '%s' "${1//\//-}"; }
case "$*" in
  "api repos/"*"/git/commits/"*" --jq .tree.sha")
    printf 'base-tree\n'
    ;;
  "api repos/"*"/git/ref/heads/"*)
    branch=${2#*/git/ref/heads/}
    file="$STATE/branch-$(slug "$branch")"
    if [[ ! -f "$file" ]]; then
      printf '{"message":"Not Found","status":"404"}\n'
      printf 'gh: Not Found\n' >&2
      exit 1
    fi
    cat "$file"
    ;;
  "api repos/"*"/compare/"*)
    file="$STATE/compare-$(slug "${2##*...}")"
    if [[ ! -f "$file" ]]; then
      printf 'gh: Not Found\n' >&2
      exit 1
    fi
    cat "$file"
    ;;
  "api repos/"*"/contents/"*)
    path=${2#*/contents/}
    file="$STATE/blob-$(slug "${path%%\?*}")"
    if [[ ! -f "$file" ]]; then
      printf 'gh: Not Found\n' >&2
      exit 1
    fi
    cat "$file"
    ;;
  "api --method POST repos/"*"/git/trees "*)
    cat "$6" >>"$STATE/tree-bodies.json"
    printf 'new-tree\n'
    ;;
  "api --method POST repos/"*"/git/commits "*)
    printf 'new-commit\n'
    ;;
  "pr list "*)
    printf '%s\n' "${PR_OPEN:-0}"
    ;;
  "pr create "*)
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == --body-file ]]; then
        cat "$2" >>"$STATE/pr-bodies.md"
      fi
      shift
    done
    printf 'https://github.com/owner/repo/pull/1\n'
    ;;
esac
EOF
chmod +x "$work/bin/apko" "$work/bin/gh"

printf 'contents:\n  packages:\n    - busybox\n' >"$work/repo/images/alpha/apko.yaml"
printf '{\n  "alpha": "current"\n}\n' >"$work/repo/images/alpha/apko.lock.json"
printf 'contents:\n  packages:\n    - httpd\n' >"$work/repo/images/beta/apko.yaml"
printf '{\n  "beta": "current"\n}\n' >"$work/repo/images/beta/apko.lock.json"
printf 'contents:\n  packages:\n    - httpd-fips\n' >"$work/repo/images/beta/fips.apko.yaml"
printf '{\n  "beta-fips": "current"\n}\n' >"$work/repo/images/beta/fips.apko.lock.json"

cat >"$work/repo/targets.json" <<'EOF'
{
  "images": [
    {
      "context": "images/alpha",
      "branch": "apko-lock/images-alpha",
      "locks": [
        {"flavor": "plain", "config": "images/alpha/apko.yaml", "lockfile": "images/alpha/apko.lock.json"}
      ]
    },
    {
      "context": "images/beta",
      "branch": "apko-lock/images-beta",
      "locks": [
        {"flavor": "plain", "config": "images/beta/apko.yaml", "lockfile": "images/beta/apko.lock.json"},
        {"flavor": "fips", "config": "images/beta/fips.apko.yaml", "lockfile": "images/beta/fips.apko.lock.json"}
      ]
    }
  ]
}
EOF

reset() {
  : >"$APKO_LOG"
  : >"$GH_LOG"
  : >"$GITHUB_STEP_SUMMARY"
  rm -rf "$STATE"
  mkdir -p "$STATE"
  rm -f "$work/repo/images/alpha/apko.yaml".{next,fail}
  rm -f "$work/repo/images/beta/apko.yaml".{next,fail}
  rm -f "$work/repo/images/beta/fips.apko.yaml".{next,fail}
  unset PR_OPEN
}

refresh() {
  (cd "$work/repo" && PATH="$work/bin:$PATH" "$script" targets.json)
}

refuses() {
  local expected=$1 status=0
  refresh >"$work/output.txt" 2>&1 || status=$?
  if [[ "$status" -ne "$expected" ]]; then
    printf 'expected exit %s, got %s\n' "$expected" "$status" >&2
    cat "$work/output.txt" >&2
    exit 1
  fi
}

mutated() {
  grep -Eq 'git/trees|git/refs|pr create' "$GH_LOG"
}

# Locks that already match the signed repositories propose nothing at all.
reset
refresh >"$work/output.txt"
grep -Fxq 'proposed 0 image lock refresh(es)' "$work/output.txt"
grep -Fq 'lock images/alpha/apko.yaml --arch amd64,arm64 --output' "$APKO_LOG"
grep -Fq 'show-config images/beta/fips.apko.yaml' "$APKO_LOG"
[[ $(grep -c '^lock ' "$APKO_LOG") -eq 3 ]]
if mutated; then
  printf 'an unchanged lock still proposed a branch\n' >&2
  exit 1
fi
[[ ! -s "$GITHUB_STEP_SUMMARY" ]]

# A changed lock proposes exactly one image-local branch, commit, and pull request.
reset
printf '{\n  "alpha": "refreshed"\n}\n' >"$work/repo/images/alpha/apko.yaml.next"
refresh >"$work/output.txt"
grep -Fxq 'proposed 1 image lock refresh(es)' "$work/output.txt"
grep -Fq 'api --method POST repos/owner/repo/git/trees --input' "$GH_LOG"
grep -Fq 'chore(deps): refresh apko lock for images/alpha' "$GH_LOG"
grep -Fq 'api --method POST repos/owner/repo/git/refs -f ref=refs/heads/apko-lock/images-alpha -f sha=new-commit' "$GH_LOG"
grep -Fq 'pr create --repo owner/repo --base main --head apko-lock/images-alpha' "$GH_LOG"
grep -Fq 'images/alpha/apko.lock.json' "$STATE/pr-bodies.md"
[[ $(grep -c 'git/trees' "$GH_LOG") -eq 1 ]]
[[ $(grep -c 'pr create' "$GH_LOG") -eq 1 ]]
if grep -q 'images-beta' "$GH_LOG"; then
  printf 'an unchanged image was combined into another proposal\n' >&2
  exit 1
fi
jq -e '.base_tree == "base-tree" and (.tree | length) == 1
  and .tree[0].path == "images/alpha/apko.lock.json"
  and .tree[0].mode == "100644" and .tree[0].content == "{\n  \"alpha\": \"refreshed\"\n}\n"' \
  "$STATE/tree-bodies.json" >/dev/null
# The checkout is never mutated: the proposal exists only on the automation branch.
grep -Fxq '  "alpha": "current"' "$work/repo/images/alpha/apko.lock.json"
grep -Fq 'images/alpha' "$GITHUB_STEP_SUMMARY"

# Every changed flavor of one image lands in that image's single branch, and an existing
# branch with an open pull request is force-updated instead of duplicated.
reset
printf '{\n  "beta": "refreshed"\n}\n' >"$work/repo/images/beta/apko.yaml.next"
printf '{\n  "beta-fips": "refreshed"\n}\n' >"$work/repo/images/beta/fips.apko.yaml.next"
printf 'old-commit\n' >"$STATE/branch-apko-lock-images-beta"
PR_OPEN=1 refresh >"$work/output.txt"
grep -Fxq 'proposed 1 image lock refresh(es)' "$work/output.txt"
grep -Fq 'api --method PATCH repos/owner/repo/git/refs/heads/apko-lock/images-beta -f sha=new-commit -F force=true' "$GH_LOG"
if grep -q 'pr create' "$GH_LOG"; then
  printf 'an open pull request was duplicated\n' >&2
  exit 1
fi
jq -e '(.tree | length) == 2 and ([.tree[].path] | sort == ["images/beta/apko.lock.json", "images/beta/fips.apko.lock.json"])' \
  "$STATE/tree-bodies.json" >/dev/null

# A branch that already carries exactly this proposal, with exactly one open pull
# request, is left alone so the image is not rebuilt.
reset
printf '{\n  "alpha": "refreshed"\n}\n' >"$work/repo/images/alpha/apko.yaml.next"
printf 'old-commit\n' >"$STATE/branch-apko-lock-images-alpha"
printf 'images/alpha/apko.lock.json\n' >"$STATE/compare-apko-lock-images-alpha"
git hash-object "$work/repo/images/alpha/apko.yaml.next" >"$STATE/blob-images-alpha-apko.lock.json"
PR_OPEN=1 refresh >"$work/output.txt"
grep -Fxq 'proposed 0 image lock refresh(es)' "$work/output.txt"
grep -Fq "api repos/owner/repo/compare/${BASE_SHA}...apko-lock/images-alpha" "$GH_LOG"
if mutated; then
  printf 'an already published proposal was pushed again\n' >&2
  exit 1
fi

# A branch carrying a stale extra path proposes more than the current delta, so it is
# reset to a fresh commit that holds exactly the current lock paths.
reset
printf '{\n  "beta": "refreshed"\n}\n' >"$work/repo/images/beta/apko.yaml.next"
printf 'old-commit\n' >"$STATE/branch-apko-lock-images-beta"
printf 'images/beta/apko.lock.json\nimages/beta/fips.apko.lock.json\n' \
  >"$STATE/compare-apko-lock-images-beta"
git hash-object "$work/repo/images/beta/apko.yaml.next" >"$STATE/blob-images-beta-apko.lock.json"
PR_OPEN=1 refresh >"$work/output.txt"
grep -Fxq 'proposed 1 image lock refresh(es)' "$work/output.txt"
grep -Fq 'api --method PATCH repos/owner/repo/git/refs/heads/apko-lock/images-beta -f sha=new-commit -F force=true' "$GH_LOG"
jq -e '(.tree | length) == 1 and .tree[0].path == "images/beta/apko.lock.json"' \
  "$STATE/tree-bodies.json" >/dev/null

# An identical branch whose pull request was closed is not stranded: the pull request is
# recreated without a redundant commit or ref update.
reset
printf '{\n  "alpha": "refreshed"\n}\n' >"$work/repo/images/alpha/apko.yaml.next"
printf 'old-commit\n' >"$STATE/branch-apko-lock-images-alpha"
printf 'images/alpha/apko.lock.json\n' >"$STATE/compare-apko-lock-images-alpha"
git hash-object "$work/repo/images/alpha/apko.yaml.next" >"$STATE/blob-images-alpha-apko.lock.json"
refresh >"$work/output.txt"
grep -Fxq 'proposed 1 image lock refresh(es)' "$work/output.txt"
grep -Fq 'pr create --repo owner/repo --base main --head apko-lock/images-alpha' "$GH_LOG"
grep -Fq 'images/alpha/apko.lock.json' "$STATE/pr-bodies.md"
if grep -Eq -- '--method (POST|PATCH) repos/owner/repo/git/' "$GH_LOG"; then
  printf 'a recreated pull request also rewrote the branch\n' >&2
  exit 1
fi
# Several open pull requests for one changed automation branch is rejected before
# the ref can be force-updated.
reset
printf '{\n  "alpha": "refreshed"\n}\n' >"$work/repo/images/alpha/apko.yaml.next"
printf 'old-commit\n' >"$STATE/branch-apko-lock-images-alpha"
git hash-object "$work/repo/images/alpha/apko.yaml.next" >"$STATE/blob-images-alpha-apko.lock.json"
PR_OPEN=2 refuses 1
grep -Fq 'has 2 open pull requests for branch "apko-lock/images-alpha"' "$work/output.txt"
if mutated; then
  printf 'an anomalous branch was still mutated\n' >&2
  exit 1
fi

# A failed lock command fails the run loudly, proposes nothing for that image, and still
# refreshes the other images.
reset
: >"$work/repo/images/alpha/apko.yaml.fail"
printf '{\n  "beta": "refreshed"\n}\n' >"$work/repo/images/beta/apko.yaml.next"
refuses 1
grep -Fq '::error title=Lock refresh failed::images/alpha: apko could not lock images/alpha/apko.yaml.' "$work/output.txt"
grep -Fq 'pr create --repo owner/repo --base main --head apko-lock/images-beta' "$GH_LOG"
if grep -q 'images-alpha' "$GH_LOG"; then
  printf 'a failed lock still proposed a branch\n' >&2
  exit 1
fi

# The workflow token is refused: a pull request it creates never starts the required checks.
reset
GH_TOKEN="" refuses 2
grep -Fq 'APKO_LOCK_REFRESH_TOKEN' "$work/output.txt"
grep -Fq 'contents:write and pull-requests:write' "$work/output.txt"
[[ ! -s "$GH_LOG" ]]

# An unusable base commit or a branch outside the automation namespace is refused.
reset
BASE_SHA=main refuses 2
grep -Fq 'is not a full commit SHA' "$work/output.txt"
[[ ! -s "$GH_LOG" ]]

reset
jq '.images[0].branch = "main"' "$work/repo/targets.json" >"$work/repo/base-branch-targets.json"
mv "$work/repo/base-branch-targets.json" "$work/repo/targets.json"
refuses 2
grep -Fq 'resolved to unusable refresh branch "main"' "$work/output.txt"
if mutated; then
  printf 'a base-branch target still mutated the repository\n' >&2
  exit 1
fi

printf 'passed scripts/test_refresh_apko_locks.sh\n'
