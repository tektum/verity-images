# Agent verification

- Read `CONTRIBUTING.md` before changing an image definition.
- Keep image pull requests image-local. Land shared workflow, matrix, catalog, or
  scanner changes in a separate prerequisite pull request.
- Run `./check` and require a zero exit status before creating or updating a
  pull request.
- Do not inspect manifests to invent alternate local check commands. `./check`
  bootstraps the pinned toolchain and is the complete local gate.
- Do not install repository tools globally.
- Leave multi-architecture image builds, scans, and smoke tests to the required
  `build` check in CI. Do not use local QEMU or other cross-architecture
  emulation.
- Report `./check` in the pull request validation section.
