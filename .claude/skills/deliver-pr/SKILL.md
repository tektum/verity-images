---
name: deliver-pr
description: Take an image change from intent to a merged, verified publication with an explicit review loop and merge approval. Use when opening, updating, reviewing, or merging any pull request in this repository.
---

# Deliver a PR

A PR is delivered only when it is merged and verified. "PR opened" is not done.
Report one terminal result: a merged PR URL and full merge SHA, or one exact
command-level blocker.

## 1. Intent (before the first commit)

State in the PR body, in this order:

- Problem: the exact failing gate, finding, or advisory (package, version, fixed version, arch, run URL).
- Change: the minimal image-local diff and why it clears the problem.
- Non-goals: what is deliberately not touched (shared files, other images, waivers).
- Open questions: decisions that belong to a human.
- Validation: `./check` result; note that multi-arch build, scan, and smoke test run in CI.

One image per PR. A shared script, workflow, matrix, catalog, or scanner change is a
separate prerequisite PR and merges first. Use a semantic commit. Never name customers.
No em dashes.

## 2. Pre-push gate

`git fetch origin`, rebase on `origin/main`, run `./check` (add
`/nix/var/nix/profiles/default/bin` to PATH if nix is missing). Zero exit required.
Never force-push a bot branch; open a replacement PR or ask the bot to rebase.

## 3. Review loop (repeat until clean)

1. Wait for `lint`, `build-gate`, `apk-gate` and every affected image validation. Triage reds with `triage-image-failure`; fix, push, wait again.
2. Wait for automated reviewers after the final push.
3. Paginated GraphQL scan of `reviewThreads`. Reply to every thread with the commit that addresses it, or the reason it does not apply. Behavior bugs get a regression test.
4. Resolve threads you answered. If the tool refuses, report the thread ids; do not work around it.
5. If `BEHIND`, cancel the obsolete run, rebase once, validate only the current head.
6. Exit the loop only when checks are green, the head is current, and unresolved threads are zero.

## 4. Merge approval

Merge only when all hold:

- required checks green on the current head;
- `reviewDecision` is `APPROVED` from a human (never self-approve, never approve a bot PR on the user's behalf);
- zero unresolved threads;
- the user asked to merge, or the project instructions require a merged terminal result and the PR is clean.

Merge through the merge queue (`gh pr merge <n> --auto`; the strategy is set by the
queue). Never use `--admin`, never bypass branch protection on `descope/*`. If
merge is blocked, report the blocker and stop. Merge prerequisite PRs before
dependents.

## 5. After merge

Verify, then report: GHCR digest, signature, SBOM, provenance, and a public catalog
entry with the matching source SHA and `fixable=0`. If the `main` publish fails, rely
on the automatic catch-up before manual recovery. Re-run `clean-images` so nothing
reappears. Archive the agent and workspace only when this task owns them.
