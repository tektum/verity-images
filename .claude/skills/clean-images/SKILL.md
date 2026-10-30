---
name: clean-images
description: Sweep open pull requests, the daily monitor, and failed main builds for CVE or lock-refresh work and drive every image to fixable=0. Use when asked to clean images, review open PRs for CVEs or refreshes, or check one image such as caddy.
---

# Clean images

Read `CONTRIBUTING.md` first. Never admin-merge or bypass branch protection.

## Sweep (do all of it, in order)

1. `git fetch origin`. Work from `origin/main`.
2. Open PRs: `gh pr list --state open --json number,title,headRefName,mergeStateStatus,reviewDecision,author`.
   For each: merge state, review decision, failing checks. A green PR that only
   lacks review is a report item, not an action.
3. Monitor, not just PRs: `gh run list --workflow monitor.yaml --limit 3`. A failed
   monitor run dispatches exact `build.yaml` rebuilds. List them from the run log
   (URLs at the tail) and read each one's `##[error]` line. An image with NO open
   PR can still be failing here; this is where caddy-type problems hide.
4. Failed `main` builds: `gh run list --workflow build.yaml --branch main`.
5. Classify every failure with `triage-image-failure`, then act.
6. Re-check: after each fix, confirm the PR opened and list what remains.

## Never miss

- Both architectures: findings are per platform; Wolfi index must carry the fix for x86_64 and aarch64.
- Stale PRs: a failure older than the last `main` advance is not evidence. Check
  commit date vs `main` and whether the daily lock refresh already ran.
- Superseding PRs: two PRs on one lock (apko.yaml pin bump plus lock refresh) means one supersedes the other.
- Do not waive or ignore a fixable finding. Report blockers with the exact package and missing version.

## Acting

- One image per PR, image-local. Shared script/workflow changes go in a separate prerequisite PR.
- Semantic commit, rebase on `origin/main` before opening a PR, report `./check` in the PR validation section.
- Force-pushing a bot branch (Renovate, Dependabot) is denied: push a new branch and open a replacement PR, or ask the bot to rebase (`@dependabot rebase`).
- Never name customers. No em dashes.

## Report

One line per PR or image: number, state, blocker or action. Name anything blocked upstream (for example Wolfi has not published the fixed version) and anything waiting only on human review.
