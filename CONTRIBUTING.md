# Contributing

## Add an image

Add one directory under `images/` for a Wolfi image or `patched/` for an
upstream-compatible image. Include `metadata.yaml`, `tests/test.sh`, and either
`apko.yaml` plus its reviewed `apko.lock.json`, or `source.yaml`. A Wolfi image
may instead include `melange.yaml` when it needs a locally built package; its
source commit and dependency overrides must be pinned, and its ephemeral
signed-package lock, provenance, and resolved dependency metadata are uploaded
as build evidence. The smoke test must run the built image and assert real
behavior. Open a pull request; CI generates the affected matrix, builds the
image, scans it, and runs the smoke test without publishing.

Metadata uses this schema:

```yaml
name: example
track: wolfi
description: Direct technical description.
upstream: https://example.com/
versions: [1.0]
owner: tektum
enabled: true
```

Optional `flavors` expand one source definition into tag variants; `plain` has
no suffix and other flavors use `-<flavor>`. Optional `major` adds a major tag.

Use lowercase image names and current upstream versions. Do not add private
repositories, credentials, or custom package feeds. Commit every Wolfi lockfile
update for review with its source change.

### Preflight

Before creating parallel image branches:

- Identify shared matrix, catalog, scanner, flavor, or build changes. Land those
  in one prerequisite pull request first.
- Choose the track from the compatibility contract: Wolfi owns a new runtime;
  patched preserves load-bearing upstream behavior; Melange rebuilds components
  that package-manager patching cannot fix.
- Resolve and scan both target architectures. Classify each fixable finding as a
  distro package, embedded binary, or application dependency before writing the
  image definition.
- Use the registry family in `metadata.name`; keep versions and variants in
  `versions`, `flavors`, and the directory name.
- Mark FIPS as required, not applicable, vendor-specific, or blocked before
  implementation. Plain and FIPS flavors must use the same source version and
  preserve the same user-facing runtime contract.

Do not publish or waive a fixable finding. The gate proves only that the pinned
Grype run reported zero findings with an available fix for the candidate digest
and platforms; it is not a zero-CVE claim.

### Runtime tests

The smoke test must verify the behavior the image promises, including applicable
OCI user, command, signal, paths, ports, volumes, and working directory.

- Wait for real readiness and assert response or protocol content.
- Exercise persistence and upgrades for stateful images.
- Test native extensions or plugins when the image promises them.
- Include negative cases for invalid metadata, unsupported paths, or unsupported
  architectures when the build has those boundaries.
- Make failures identify the broken assertion; avoid silent `&&` chains.
- Keep scripts executable and APKO configs, metadata, and lockfiles mode `100644`.

Run native-architecture runtime checks locally. Leave non-native builds and smoke
tests to CI; do not use local emulation.

An `enabled: false` definition is quarantined work, not supported catalog
coverage. Record its blocker and unblock condition in the pull request and
revalidate it before enabling.

### Renovate coverage

Keep external sources in one of these layouts so Renovate can open update pull
requests:

- A patched image must declare adjacent `image:` and `digest:` lines in
  `patched/<name>/source.yaml`. Keep the intended major version in the image
  tag; Renovate updates that stream and its digest but does not cross majors.
- A source-built Wolfi image must keep `package.version`, the HTTPS GitHub
  `git-checkout.repository`, `tag: v${{package.version}}`, and the full
  `expected-commit` in `images/<name>/melange.yaml`. Renovate updates the tag
  version and matching commit together.
- A workflow helper image must use `image: registry/repository:tag@sha256:...`
  in `.github/workflows/*.yaml`. A tagless digest is treated as the registry's
  `latest` tag.

If an external source cannot use one of these layouts, extend `renovate.json`
in the same pull request. Pure APKO images have no upstream OCI image version;
their reviewed `apko.lock.json` remains the update boundary.

## Style

- Use keyboard-only ASCII characters in prose, comments, and documentation.
- Pin every third-party GitHub Action to a full commit SHA with a version
  comment.
- Keep job permissions empty by default and opt in per job.
- Use shell scripts compatible with POSIX `sh`.
- Run `./check` before requesting review. It bootstraps the pinned Devbox
  toolchain and runs the same lint suite as CI.

## Review and merge

- Keep image pull requests image-local. A shared-file change needs a prerequisite
  pull request with one owner.
- Reply to every review thread before resolving it. Add a regression test for a
  review-caught behavior bug.
- After the final push, wait for automated reviews and perform a paginated scan
  that confirms zero unresolved threads.
- Require `lint`, every affected image validation, and `build-gate` to pass.
- Merge prerequisite pull requests before dependent image pull requests.

## Recommended branch protection

Protect `main` in repository settings. Require pull requests, one approving
review, resolved conversations, the `lint` and `build-gate` checks, and the
merge queue. Block force pushes and branch deletion. Repository administrators
must configure these settings because workflows cannot safely protect their own
branch.
