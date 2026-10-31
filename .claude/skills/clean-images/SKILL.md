---
name: clean-images
description: Sweep open pull requests, the daily monitor, and failed main builds for CVE or lock-refresh work and drive every image to fixable=0. Use when asked to clean images, review open PRs for CVEs or refreshes, or check one image such as caddy.
---

# Clean images

Read `CONTRIBUTING.md` first. Never admin-merge or bypass branch protection.

## Sweep (do all of it, in order)

1. `git fetch origin`. Work from `origin/main`.
2. Open PRs: `gh pr list --state open --limit 500 --json number,title,headRefName,mergeStateStatus,reviewDecision,author`.
   For each: merge state, review decision, failing checks. A green PR that only
   lacks review is a report item, not an action.
3. Monitor, not just PRs: `gh run list --workflow monitor.yaml --limit 3`. Read the
   "Finding-aware vulnerability remediation" step summary of every recent run, green
   or red. It lists exact `build.yaml` rebuilds, queued `apko-lock-refresh.yaml` and
   `local-package-revision.yaml` proposals, and "Blocked or unsupported findings"
   (package, required version, missing architectures); a red run usually means
   blocked findings. Check the dispatched runs and the PRs they open. An image with NO
   open PR can still be failing here; this is where caddy-type problems hide.
4. Failed `main` builds: `gh run list --workflow build.yaml --branch main --limit 200`.
5. Classify every failure with `triage-image-failure`, then act.
6. Re-check: after each fix, confirm the PR opened and list what remains.

## Process loop (every PR, until merged)

Repeat per PR; do not stop at "PR opened".

1. Rebase on `origin/main`; run `./check` (add `/nix/var/nix/profiles/default/bin` to PATH if nix is missing). Zero exit required.
2. Push, then wait for required checks `lint`, `build-gate`, `apk-gate` plus every affected image validation. Read failures with `triage-image-failure`; fix, push, repeat.
3. After the final push wait for automated reviewers. Fetch review threads with a paginated GraphQL scan; reply to every thread, apply valid ones with a regression test for behavior bugs, then resolve. Require zero unresolved threads.
4. If `main` advanced and up-to-date policy requires it (`BEHIND`), cancel the obsolete run, rebase once, validate only the current head.
5. When checks are green, threads are resolved and the diff is reviewed and sound, approve PRs you did not author if review is the only blocker, then merge via the normal path (`gh pr merge <n> --auto`, merge queue). Never `--admin` or bypass branch protection.
6. After merge, verify completion: GHCR digest, signature, SBOM, provenance, and a public catalog entry with the matching source SHA and `fixable=0`. If `main` publish fails, keep the catalog source-run failure loud, then rely on the automatic catch-up. Use manual delta recovery only when the automatic path cannot complete.
7. Follow `deliver-pr` for intent, review loop and merge approval.
8. Re-run the sweep. Done only when no open PR, monitor summary, or `main` build still reports the image.

Merge prerequisites (shared script/workflow PRs) before dependent image PRs.

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

One line per PR or image: number, state, blocker or action. Name anything blocked upstream (for example Wolfi has not published the fixed version).
