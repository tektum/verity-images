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

Metadata uses this schema for Wolfi images:

```yaml
name: example
track: wolfi
description: Direct technical description.
upstream: https://example.com/
versions: [1.0]
owner: tektum
enabled: true
```

Patched images omit `upstream` and `versions`; the matrix derives both from the
numeric version prefix in `source.yaml`'s image tag. Tags may have a leading `v`
or a suffix such as `-slim`, but must begin with a numeric version after the
optional `v`.

Optional `flavors` expand one source definition into tag variants; `plain` has
no suffix and other flavors use `-<flavor>`. Optional `major` adds a major tag.

Plain and FIPS flavors must stay in one image directory and use one upstream
version and source commit. Application package builds use one `melange.yaml`;
a FIPS-only image-local recipe may package only its activation entrypoint. A
flavor env file may change only cryptographic build selection. FIPS APKO inputs
may add provider or configuration packages and activation environment, but must
preserve UID/GID,
entrypoint, command, paths, ports, volumes, configuration schema, and persistent
data format. Image tests must cover those image-specific contracts and use
`scripts/test_fips.sh` for OpenSSL provider checks and inspect-level flavor
compatibility. The `fips` flavor is not a certification claim for the image or
application.

OpenSSL FIPS consumers use the signed Pages repository with the committed
`verity-apk-2026.rsa.pub` key and must pin the provider version in both APKO
configuration and lockfile. FIPS Go images add a tiny image-local entrypoint
which invokes `/usr/bin/openssl-fips-activate /usr/bin/go` and preserves both
the default Go command and explicit Go arguments. The generic activation helper
generates and verifies `fipsmodule.cnf` in `OPENSSL_FIPS_RUNTIME_DIR`, then
uses `exec` without writing to the image root filesystem.

Use lowercase image names and current upstream versions. Do not add private
repositories, credentials, or custom package feeds. Commit every Wolfi lockfile
update for review with its source change.

### Published version authority

A build artifact owns the version it publishes; metadata never carries a second
editable copy of it.

- A source-built Wolfi image derives its published version from `melange.yaml`
  `package.version`. Its `versions` entry declares only channel granularity:
  one component publishes a major channel, two publish `major.minor`, and three
  publish the exact version. An etcd bump from `3.6.14` to `3.7.1` therefore
  publishes `3.7` with no metadata edit.
- A non-numeric entry such as `latest` or `wolfi` is a literal channel and
  publishes verbatim.
- A pure APKO image has no `melange.yaml`, so its `versions` entry stays the
  authoritative channel or version. A directory whose only recipe is a flavor
  helper such as `fips.melange.yaml` is treated the same way, because that
  recipe packages activation glue rather than the runtime source.
- `major` opts in to a floating major tag. Its value is derived from the
  published version, and a declared value that names a different major fails
  `lint`, so the floating tag can never point at another major. A cross-major
  transition therefore updates `major` in the same reviewed pull request; it
  never automerges.
- A source-built image whose APK version syntax differs from upstream syntax
  declares `vars.upstream-version` in `melange.yaml`. That marker is the only
  documented exception: the `versions` entry stays authoritative and nothing is
  derived. Today only the quarantined `enabled: false` tidb definition uses it,
  where `package.version` is `9.0.0_beta1`, the checkout tag reads
  `vars.upstream-version`, and `versions` states the upstream spelling. Renovate
  updates `vars.upstream-version` with `expected-commit` for that layout, so
  reconcile all three fields in one reviewed pull request before enabling such
  an image. Without the marker, an APK-only version syntax fails `lint`.
- A nested `images/<name>/<stream>/` directory owns its stream. The derived
  version must stay inside it, so a minor or major transition renames the
  directory in a reviewed pull request instead of silently republishing another
  stream from the same path.

Transitional contract: existing numeric `versions` entries stay exactly as
written, because only their component count is load-bearing for a source-built
image. The numeric text is transition support, not the final shape: it still
reads like a version while only its granularity is used. Removing it is a
single mechanical migration that replaces each source-built entry with an
explicit granularity token and updates `parse_metadata`; land it as its own
reviewed change once no image needs the numeric form. Final contract: metadata
states granularity or a literal channel and never restates a version that
`melange.yaml` or `source.yaml` already declares. Numeric melange package names
and their APKO references remain stable legacy identities and are not part of a
version transition.

A version-authority change moves a published identity, so `main` regenerates
its matrix with `--published catalog.json` and rebuilds any image whose current
identity the published catalog does not carry yet. Until that replacement is
published, `scripts/build_catalog.py` keeps the superseded catalog entry instead
of pruning it, and prunes it only once the replacement is present.

### Preflight

Before creating parallel image branches:

- Identify shared matrix, catalog, scanner, flavor, or build changes. Land those
  in one prerequisite pull request first.
- Choose `wolfi` for a new runtime and `patched` when the image must preserve
  load-bearing upstream behavior. For a Wolfi image, use Melange to rebuild
  components that package-manager patching cannot fix.
- Resolve both target architectures and inspect current vulnerability evidence
  before writing the image definition. CI performs the authoritative amd64 and
  arm64 scans, and `build-gate` aggregates their results.
- Use the registry family in `metadata.name`; keep versions and variants in
  `versions`, `flavors`, and the directory name.
- Mark FIPS as required, not applicable, vendor-specific, or blocked before
  implementation. When both plain and FIPS flavors are supported, they must use
  the same source version and preserve the same user-facing runtime contract.

Do not publish or waive a fixable finding. The gate proves only that the pinned
Grype run reported zero findings with an available fix for the candidate digest
and platforms; it is not a zero-CVE claim.

- A candidate is admissible only with a remediation hypothesis and preflight
  evidence for license and redistribution, an allowed registry, an immutable
  source bound to the canonical publisher or verified upstream signatures and
  checksums, exact amd64 and arm64 child manifests, likely zero-fixable
  feasibility, a runtime contract with a negative test, and an expected
  build-duration class.
- Patched sources are currently limited by `scripts/gen_matrix.py` to `docker.io`,
  `registry.k8s.io`, `docker.elastic.co`, and `ghcr.io`. Land any allowlist change
  as a reviewed prerequisite before admitting a candidate.
- Treat runner allocation and execution as separate budgets. Queue starvation is
  not fixed by increasing build retries or execution timeouts.

### Runtime tests

The smoke test must verify the behavior the image promises, including applicable
OCI user, command, signal, paths, ports, volumes, and working directory.

- Wait for real readiness and assert response or protocol content.
- Exercise persistence and upgrades for stateful images.
- Test native extensions or plugins when the image promises them.
- Include negative cases for invalid metadata, unsupported paths, or unsupported
  architectures when the build has those boundaries.
- Make failures identify the broken assertion; avoid silent `&&` chains.
- Keep scripts executable and APKO configs, metadata, `source.yaml`,
  `melange.yaml`, and lockfiles mode `100644`.

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
  This file is authoritative for the upstream image and published version; do
  not duplicate either field in `metadata.yaml`.
- A source-built Wolfi image must keep `package.version`, the HTTPS GitHub
  `git-checkout.repository`, `tag: v${{package.version}}`, and the full
  `expected-commit` in `images/<name>/melange.yaml`. Renovate updates the tag
  version and matching commit together, and for that layout `metadata.yaml`,
  melange package names, and APKO package references must not need an edit in
  the same pull request. A smoke test needs no edit when it derives its expected
  primary version from the image or the recipe; a test that hardcodes that
  version, or asserts a bundled tool version, still changes with the bump.
  A recipe that checks out `tag: v${{vars.upstream-version}}` instead has that
  variable as its version-bearing field, so its manager in `renovate.json`
  updates `vars.upstream-version` with `expected-commit`.
- A workflow helper image must use `image: registry/repository:tag@sha256:...`
  in `.github/workflows/*.yaml`. A tagless digest is treated as the registry's
  `latest` tag.

If an external source cannot use one of these layouts, extend `renovate.json`
in the same pull request. Pure APKO images have no upstream OCI image version;
their reviewed `apko.lock.json` remains the update boundary.

Update policy lives in `renovate.json`, not in a second copy of a version
string. A major upstream transition under `images/**/melange.yaml` opens a pull
request but never automerges. A nested `images/<name>/<stream>/` directory is
the structural signal for a parallel stream: patch updates remain automatic,
while minor and major transitions require review. Renovate still offers those
transitions instead of silently filtering them through duplicated
`allowedVersions` strings.

Explicit Go dependency overrides are different from upstream image versions.
A Go module major upgrade changes its import path and requires a source
migration, so Renovate does not update `go/bump` or versioned `go get`
overrides across majors. Same-major override updates remain eligible. Source
image major releases still open reviewable pull requests.

### Rust vulnerability remediation

A Cargo image resolves fixable crate advisories with the shared
`cargo/remediate` pipeline instead of handwritten `cargo update` pins.

- The pipeline installs the pinned `cargo-audit` crate version into a temporary
  tool root and uses `cargo audit --json` only to discover advisories. Omnibump
  is the only dependency graph mutation engine; `cargo audit fix` and raw
  `cargo update` are not remediation paths.
- The checkout is untrusted input, so the audit runs from a controlled directory
  outside it with its own `HOME` and `CARGO_HOME`, an explicit advisory database
  path and URL, and an absolute lockfile path. A repository-local
  `.cargo/audit.toml` therefore cannot ignore advisories, lower the severity
  threshold, or redirect the database, and the reported `settings` are validated
  so any override fails the build. Yanked-crate checking is off because it is a
  diagnostic that would reintroduce a registry trust surface.
- Audit exit status 0 means clean and 1 means valid findings. Any other status,
  a missing or malformed report, or an output that contradicts the status is a
  scanner failure and surfaces the audit's stderr.
- Only `vulnerabilities.list` drives mutation. Unmaintained, unsound, and yanked
  warnings are printed once as diagnostics.
- Each finding contributes the lowest exact version satisfying the advisory's
  patched requirements, including across a SemVer boundary, honoring bare,
  caret, tilde, and exact upper bounds plus disjoint ranges. An `unaffected`
  floor is only a fallback when no patched release is reachable upward, because
  an unaffected range often names releases years older than the fix.
- Candidates are requested as explicit `crate@current=fixed` pins per vulnerable
  locked version. This keeps duplicate compatibility lines distinct while all
  pins for a pass reach omnibump in one coordinated invocation with
  `--fail-on-unapplied-pins`; the audit then reruns to a bounded fixed point.
- Only a finding with no fixed or newer-unaffected release is reported as
  non-blocking. These all fail loudly: a fix that requires a downgrade, a fix
  behind a strict `>` bound that names no exact release, any move from a stable
  release to a prerelease, a prerelease move outside its existing major/minor
  train, an unsupported or unsatisfiable requirement, a known fix that omnibump
  cannot land, a downgraded locked instance, a pass with no lock progress, and
  pass-limit exhaustion. A strict bound means a fix demonstrably exists that
  this pipeline will not guess at, so the recipe owns that decision.
- Crate identity carries its lock source. A finding that maps to one name and
  version from several sources, to a replaced entry, or to a non-registry source
  fails instead of claiming remediation.
- The recipe passes `features` matching its own build feature selection, so
  omnibump resolves the graph the build compiles. Remediation ends with locked
  `cargo metadata` and `cargo fetch` verification; the recipe still owns its
  `--locked` build.
- The recipe environment provides the Rust toolchain, and the pipeline declares
  its own omnibump and Python runtime. Editing the shared implementation
  invalidates every consuming image fingerprint and validates against one
  consuming image. The final `fixable=0` image gate is unchanged and remediation
  records no extra evidence artifact.
- `scripts/test_cargo_omnibump_contract.py` proves the real omnibump Rust CLI
  contract in a digest-pinned ephemeral container: flag support, a direct
  SemVer-boundary update, a transitive update, a pin the graph refuses, and two
  unsatisfied compatibility lines for one crate landing from explicit pins in
  one invocation. It reports SKIPPED when no container runtime or registry is
  reachable locally, and fails instead of skipping under `CI`.

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
- On pull requests, require `lint`, every affected image and APK validation,
  `build-gate`, and `apk-gate` to pass.
- Classify auxiliary checks from branch protection. Do not treat every red check
  as a required check.
- If `main` advances during a long PR build and up-to-date protection requires a
  new head, cancel the obsolete run, rebase once, and validate only the current
  head.
- The merge queue reruns `lint` and validates the changed-image and APK
  matrices, but intentionally skips artifact builds. `main` rebuilds and
  publishes affected images after merge.
- Merge prerequisite pull requests before dependent image pull requests.
- Completion requires the GHCR digest, signature, SBOM, and provenance, plus a
  public catalog entry with the matching source SHA and `fixable=0`. For a stale
  catalog, first rely on the automatic catch-up dispatched from the validated
  live catalog source SHA after a failed `main` build. Catalog source-run failure
  must remain loud. Use the documented manual delta recovery only when the
  automatic path cannot complete.

## Recommended branch protection

Protect `main` in repository settings. Require pull requests, one approving
review, resolved conversations, the `lint`, `build-gate`, and `apk-gate` checks,
and the merge queue. Block force pushes and branch deletion. Repository
administrators must configure these settings because workflows cannot safely
protect their own branch.
