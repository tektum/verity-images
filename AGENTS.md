# Agent verification

- Read `CONTRIBUTING.md` before changing an image definition.
- Keep image pull requests image-local. Land shared workflow, matrix, catalog, or
  scanner changes in a separate prerequisite pull request.
- Run `./check` and require a zero exit status before creating or updating a
  pull request.
- Do not inspect manifests to invent alternate local check commands. `./check`
  bootstraps the pinned toolchain and is the complete local gate.
- Do not install repository tools globally.
- Leave multi-architecture image builds, scans, and smoke tests to CI. Required
  branch checks are `lint`, `build-gate`, and `apk-gate`. Do not use local QEMU
  or other cross-architecture emulation.
- Report `./check` in the pull request validation section.
- Execute the task before reporting it. Never finish with "I will". A terminal
  result is a merged PR URL and full merge SHA, or one exact command-level
  external blocker.
- Keep one active owner per workspace. Preserve files when replacing an agent or
  workspace. Replace a session after two non-actions.
- After a verified merge, archive the agent and workspace. Stop or remove only
  resources proven to be owned by this task.
- Never wait on obsolete validation for a `BEHIND` head. Rebase and cancel only
  when GitHub shows that the required up-to-date policy makes it necessary.
