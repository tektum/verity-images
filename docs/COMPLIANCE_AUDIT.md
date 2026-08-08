# Verity Images supply-chain and compliance audit

Date: 2026-07-30  
Repository commit reviewed: `91a49dc`  
Live catalog reviewed: <https://tektum.github.io/verity-images/catalog.json>  
Catalog publication reviewed: `2026-07-29T15:27:50Z`, source run `30465630534`

## Verdict: not audit-ready for regulated or audit-reliant use

The image pipeline has a strong technical core, but it is not yet an auditor-ready
system of record. The published images are signed, have SPDX attestations, and have
GitHub SLSA provenance. The release gate really does reject fixable Grype findings.
However, the public catalog and retained evidence do not form one durable,
cryptographically bound chain from reviewed source to build inputs, tests, scans,
SBOM, image digest, promotion, and later revocation.

This repository alone cannot establish FedRAMP, SOC 2, or ISO 27001 compliance.
Those programs also require organization-level policies, access reviews, personnel
controls, incident handling, risk treatment, continuous monitoring, evidence
retention, and operating-effectiveness records that are not present here.

## Remediation applied after the baseline audit

- Privileged image publication now requires `refs/heads/main`.
- Scheduled builds no longer resolve mutable upstream tags; patched digests and
  Wolfi locks are reviewed, checked-in inputs.
- Catalog publication validates workflow identity, successful trusted-main source,
  repository ownership, event type, commit ancestry, and report digest shape.
- Complete vulnerability findings are retained while any fixable finding still
  blocks release.
- Both architectures are smoke-tested before GHCR login or transport-tag push.
- The catalog schema is strict, producer/schema compatibility has a runnable check,
  and the minimum compatible Cosign version is published.
- Lint/developer tooling is locked by Devbox; release-critical apko and Syft remain
  direct checksum-pinned binaries because current Nix packages lag their versions.
- Repository settings now require action SHA pins and enable secret scanning, push
  protection, and Dependabot security updates. Secret validity checks remain
  unavailable/disabled at the repository setting.

Remaining findings below describe the reviewed baseline. The items above are fixed
in the current worktree but still require a successful protected-main run before
they become operating evidence.

## What is already good

- All 25 external GitHub Actions references currently in the workflows are pinned
  to full commit SHAs.
- Downloaded build tools are versioned and SHA-256 checked before installation.
- Workflow permissions are job-scoped; pull requests cannot authenticate to GHCR,
  publish, sign, attest, or move release tags.
- Checkout credentials are not persisted.
- `main` has an active ruleset requiring one approval, approval of the last push,
  resolved review threads, linear history, and successful `lint`, `build-gate`,
  and `apk-gate` checks.
- All 16 live catalog image digests verified with Cosign `v3.0.6`.
- All 16 live SPDX attestations verified with Cosign `v3.0.6`.
- GitHub SLSA provenance verified for all 16 live image digests, with a GitHub-hosted
  runner identity, workflow identity, source commit, invocation URL, and Rekor time.
- Both architectures receive a fixable-vulnerability scan, and the release tags are
  applied only after the vulnerability gate, smoke test, signing, SBOM attestation,
  and provenance steps succeed.
- Sampled Grype reports identify the scanned child-manifest digest and record the
  scanner/database state. The sampled database was valid and built the same day.
- Consumers are told to pull by digest rather than rely on mutable tags.

## Priority findings

### 1. High: a manual build dispatch can publish from an unreviewed ref

`workflow_dispatch` builds the full matrix, while the privileged `publish` job
excludes only pull requests. It has package, OIDC, and attestation write
permissions, but no `github.ref == 'refs/heads/main'` condition or approval-gated
release environment. A write-capable collaborator can dispatch an unreviewed branch
or tag and move version/latest tags. The documented exact-main certificate identity
detects the non-main signer for consumers that enforce it, but tag consumers and
policies scoped only to repository/workflow do not.

Evidence:

- `.github/workflows/build.yaml:3`
- `.github/workflows/build.yaml:46`
- `.github/workflows/build.yaml:134`
- `.github/workflows/build.yaml:138`
- `.github/workflows/build.yaml:197`

Required fix: require `github.ref == 'refs/heads/main'` for publication, make
non-main dispatch validation-only, and use a main-only protected environment with
required approval and self-review prevention. Add a feature-ref and tag dispatch
test that proves the publish job is skipped.

### 2. High: scheduled rebuilds can trust-launder mutable upstream inputs

Scheduled patched builds replace the reviewed source digest with the current digest
of a mutable upstream tag. Wolfi builds generate a new lock from a mutable package
repository whose signing key is fetched from that same origin. A compromised or
repointed upstream that has no known CVE can therefore be scanned, re-signed, and
promoted as a Verity image without a reviewed pin update.

Evidence:

- `.github/workflows/build.yaml:175`
- `scripts/build_candidate.sh:15`
- `scripts/build_candidate.sh:23`
- `scripts/build_candidate.sh:27`
- `scripts/build_candidate.sh:46`
- `docs/POLICY.md:78`

Required fix: make production publication require `resolvedDigest == pinnedDigest`;
run an updater that opens a reviewed PR for upstream changes. Verify an allowlisted
upstream signature/provenance before use, pin or vendor the Wolfi trust key, and
record every verified upstream identity and digest in build evidence.

### 3. Medium: manual catalog selection lacks source-run validation

The event-driven path already requires a successful `Build images` run whose
`head_branch` is `main`. The manual path is broader: it accepts an arbitrary run ID
and copies the run URL, SHA, and timestamp without checking workflow identity,
workflow file, conclusion, event, source repository, branch, or whether the SHA is
contained in protected `main`. The generator does not reject `digest: local`.

Evidence:

- `.github/workflows/catalog.yaml:17`
- `.github/workflows/catalog.yaml:45`
- `.github/workflows/catalog.yaml:67`
- `.github/workflows/build.yaml:113`
- `.github/workflows/build.yaml:117`
- `.github/workflows/build.yaml:128`
- `scripts/build_catalog.py:20`

Impact: a privileged operator can accidentally select a PR, failed run, or unrelated
run. This does not directly move GHCR release tags, but it weakens the catalog as a
trust source.

Required fix:

1. For `workflow_run`, retain and explicitly validate the trusted workflow identity
   and successful protected-`main` source run.
2. For manual selection, fetch and enforce the same invariants and verify the SHA
   is an ancestor of current protected `main`.
3. Reject reports without a syntactically valid `sha256:` image digest.
4. Add a safe integration fixture proving unrelated, failed, malformed, and
   pull-request runs are refused by the manual path.

### 4. Medium: catalog metadata lacks a signed correlation record

The catalog itself is unsigned and unattested. It names scan artifacts but does not
publish their artifact ID, URL, SHA-256 digest, expiry, scanner identity, database
digest, or an attestation binding them to the image. It does not link the attached
SBOM digest. The SPDX attestation remains available from the OCI image and verifies
with Cosign v3.0.6; the retention concern is narrower: raw scan reports and exact
input evidence are GitHub run artifacts that expire after 90 days. Once expired, an
auditor cannot reconstruct that raw scan/build evidence behind an older still-
pullable image from the catalog alone.

The top-level catalog `source` describes the run that last updated the catalog, not
the source run for each preserved image. Partial updates merge prior entries from
the unauthenticated Pages JSON, so different image entries can come from different
runs while the catalog exposes only one run and commit.

Evidence:

- `scripts/build_catalog.py:32`
- `scripts/build_catalog.py:43`
- `.github/workflows/catalog.yaml:100`
- `.github/workflows/catalog.yaml:119`
- live catalog `scanArtifact` fields
- source run `30465630534`: 33 artifacts expiring on 2026-10-27

Required fix:

- Produce the catalog only from authenticated build attestations, not the previous
  public Pages document.
- Give every image entry its own source commit, run, build time, lock/source digest,
  scan digests, scanner DB identity, SBOM digest, test-result digest, and promotion
  record.
- Sign and attest the catalog, build report, scan reports, SBOM, and test report.
- Retain raw scan and exact-input evidence for the documented image support lifetime
  plus the audit window, preferably as immutable OCI referrers rather than expiring
  workflow artifacts.

### 5. Medium: vulnerability visibility intentionally excludes every unfixed CVE

All Grype gate scans use `only-fixed: true`. This is a defensible release gate for
"zero fixable findings", but it is not a complete vulnerability report. Known
unfixed vulnerabilities disappear from the report and from the catalog. There is
no VEX, exploitability context, risk acceptance, exception owner, expiry, or POA&M.
An empty catalog scan object therefore means only "no fixable finding observed",
not "no known vulnerability".

Evidence:

- `.github/actions/publish-image/action.yaml:104`
- `.github/actions/publish-image/action.yaml:112`
- `.github/actions/publish-image/action.yaml:114`
- `.github/actions/publish-image/action.yaml:122`
- `docs/POLICY.md:14`

Required fix:

- Preserve the zero-fixable release gate, but also generate and retain a complete
  scan including unfixed findings.
- Publish normalized findings, aliases, affected package, severity, fix state,
  scanner/database identity, scan time, and child-manifest digest.
- Add VEX or a governed exception/risk record with owner, rationale, compensating
  controls, expiry, and remediation target.

### 6. High: regulated-control evidence is largely absent

The repository has `SECURITY.md` and `CONTRIBUTING.md`, but no control matrix,
system boundary, threat model, risk register, POA&M, access-review evidence,
incident-response record, change-management evidence package, vendor assessment,
retention policy, rollback/revocation procedure, exception register, or continuous
monitoring report.

The support policy explicitly provides no SLA. There are no documented severity-
based remediation deadlines, EOL/deprecation policy, emergency rebuild process,
revocation mechanism, or customer notification commitment.

Required fix: create an evidence owner and operating cadence for every applicable
control. Do not claim FedRAMP, SOC 2, or ISO 27001 from CI configuration alone.

## Material findings

### 7. Medium: public transport tags exist before scans and smoke tests pass

The composite action pushes predictable `build-...` architecture tags and an index
before Grype evaluation and smoke testing. Release tags remain gated, but failed
candidates stay publicly retrievable and are not cleaned up.

Evidence:

- `.github/actions/publish-image/action.yaml:70`
- `.github/actions/publish-image/action.yaml:104`
- `.github/actions/publish-image/action.yaml:158`
- `.github/actions/publish-image/action.yaml:205`

Fix: scan/test local candidates before public push, use a private staging registry,
or make failed transport references inaccessible and garbage-collect them.

### 8. Medium: provenance omits important resolved materials

GitHub provenance identifies the repository commit and workflow, but sampled
statements expose only that Git commit as a resolved dependency. The actual apko
lock, Wolfi repository state, patched upstream index/child digests, tool archive
digests, scanner DB, generated SBOM, and test results are not enumerated as
materials.

Scheduled patched builds intentionally resolve a mutable upstream tag instead of
the reviewed digest. Wolfi builds resolve packages from a mutable repository and
generate a new lock during the run. Those exact inputs exist in 90-day artifacts,
but they are not durably bound into the provenance.

Evidence:

- `.github/workflows/build.yaml:175`
- `scripts/build_candidate.sh:15`
- `scripts/build_candidate.sh:27`
- `scripts/build_candidate.sh:31`
- `docs/POLICY.md:78`

Fix: attest a richer build manifest containing every resolved input and evidence
digest. Add reproducibility or rebuild comparison for representative images.

### 9. Low: repository security policy is not enforced at the platform boundary

Current action references are pinned, but repository settings allow all actions and
do not require SHA pinning. Secret scanning, push protection, validity checks, and
Dependabot security updates are disabled. There is no CODEOWNERS rule for release
files. The main ruleset requires only one approval and permits organization admins
and a repository role to bypass through pull requests.

Fix: enforce SHA pinning/allowlisting in repository settings, enable secret scanning
and push protection, automate pinned dependency updates, require release-path code
owners, and use two-person review without unilateral release-path bypass where the
assurance target requires it.

### 10. Medium: the schema neither constrains nor validates the trust-critical data

The JSON Schema mostly lists required property names. It does not constrain nested
types, digest patterns, URI formats, track values, scan shapes, verification
commands, uniqueness, or unexpected properties. The publication workflow does not
run a JSON Schema validator; it uses a small `jq` expression instead.

Evidence:

- `docs/catalog.schema.json:10`
- `docs/catalog.schema.json:18`
- `.github/workflows/catalog.yaml:115`

Fix: make the schema strict, validate it in CI and publication, and add semantic
checks for unique image/version pairs, digest-reference equality, trusted URLs,
per-track scan shape, and evidence bindings.

### 11. Low: hardening and runtime tests are functional, not security baselines

Fifteen of sixteen sampled amd64 image configs default to root or leave the user
unset; only `static:wolfi` declares user `65532`. None publishes a healthcheck.
This may be appropriate for generic base/toolchain images, but it is not a hardened
default and should not be marketed as one.

All 17 smoke tests exercise only amd64 and use no rootless, read-only filesystem,
capability, seccomp, network, PID, or memory constraints. Arm64 is scanned but not
smoke-tested. There is no CIS/STIG/SCAP configuration assessment, FIPS-validated
cryptography evidence, malware scan, embedded-secret scan, or license-policy gate.

Fix: publish an explicit security baseline and conformance report, test both
architectures, offer non-root/hardened variants or document why root is required,
and add the controls required by the claimed deployment environment.

### 12. Low: lifecycle, rollback, and raw-evidence retention controls are undefined

Mutable release tags and dated tags exist, but no immutable promotion ledger,
rollback runbook, signature/attestation revocation policy, compromised-image status,
deprecation metadata, raw-evidence retention rule, or emergency customer
notification path is published. `docs/POLICY.md` explicitly disclaims an SLA.

Fix: define support windows, severity-based remediation SLAs, EOL dates, rollback
and revocation procedures, and machine-readable image status in the catalog.

## Lower-severity evidence defects

- The catalog and README omit a minimum Cosign version. All 16 signatures and SBOM
  attestations pass with the workflow's Cosign `v3.0.6`, while the same advertised
  commands fail with Cosign `v2.6.1` because of storage/format compatibility. Pin or
  state the supported verifier version and test the published commands.
- GitHub provenance succeeds, but the workflow log warns that the artifact metadata
  storage record was not created because `artifact-metadata:write` is absent. Add the
  permission if that record is part of the evidence design.
- OCI source, revision, version, and license labels are absent from all sampled image
  configs; patched images also omit the creation label. Add labels as useful
  discovery metadata, but do not treat labels as a substitute for attestations.
- No consumer-side admission policy is supplied. Provide a sample policy that
  rejects mutable tags, untrusted builders/workflows, stale evidence, failed policy,
  and revoked digests.

## Framework assessment

| Framework | Assessment | Principal gaps |
|---|---|---|
| SLSA v1.2 Build | Strong L2/L3 foundations, but do not claim a level yet | Resolved build materials are incomplete; no published builder assessment or verification policy; catalog/evidence are outside the chain |
| SLSA v1.2 Source | Version control and continuous rules exist; not Source L4 | One approval rather than two trusted persons; bypass actors; no source-verification summary attestation |
| OWASP SCVS | Partial | Good SBOM/signing; incomplete vulnerability inventory, no VEX, no durable evidence binding, no component/license policy or verifier enforcement |
| NIST SSDF 1.1 | Partial | Protect/build/release practices exist; preparation, archival, risk acceptance, response, provenance completeness, and recurrence evidence are incomplete |
| FedRAMP / NIST 800-53 | Not evidenced | RA-5, SI-2, SI-7, CM-2, CM-8, SA-10, SA-12 and continuous-monitoring evidence are incomplete; no POA&M, control implementation, FIPS/STIG boundary, or operating evidence |
| SOC 2 | Not evidenced | Technical change and vulnerability controls are partial; no CC6/CC7/CC8 operating-effectiveness evidence, access reviews, incident evidence, vendor oversight, or retention |
| ISO 27001:2022 | Not evidenced | Partial A.8.8/A.8.9/A.8.19/A.8.25-A.8.32 implementation; missing ISMS scope, risk treatment, ownership, audit, incident, supplier, and evidence-retention records |

## Minimum path to an auditor-credible release

### P0: must complete before calling the catalog trustworthy

1. Restrict privileged image publication to protected `main`; make manual
   non-main dispatches validation-only.
2. Require reviewed, verified upstream digests for production; do not promote a
   scheduled resolution of a mutable upstream tag directly.
3. Lock catalog publication to trusted successful `main` build runs and reject PR,
   unrelated, failed, or malformed reports.
4. Make the catalog, scans, SBOMs, tests, build inputs, and promotion record immutable,
   signed, digest-linked, per-image, and retained for the audit/support lifetime.
5. Publish the complete vulnerability inventory, not only fixable findings, with a
   governed VEX/exception/POA&M process.
6. Remove or isolate public pre-gate transport images.

### P1: required for serious supply-chain assurance

1. Enrich provenance with all resolved materials and evidence digests.
2. Enforce action allowlisting/SHA pinning, enable secret protections, automate
   updates, and strengthen release-path review.
3. Enforce a strict catalog schema and end-to-end evidence verification in CI.
4. Define lifecycle, remediation SLA, EOL, rollback, and revocation behavior.
5. Test arm64 and publish a documented runtime-hardening baseline.

### P2: required for FedRAMP, SOC 2, or ISO 27001 claims

1. Establish the system boundary, control owners, risk register, policies, and
   evidence retention.
2. Produce recurring access, change, vulnerability, incident, vendor, backup,
   continuity, and internal-audit evidence.
3. Obtain independent assessment of both design and operating effectiveness.

## Verification performed

- Parsed the live 16-entry catalog in a browser.
- Independently verified 16/16 signatures and 16/16 SPDX attestations with the
  workflow's Cosign `v3.0.6`.
- Independently verified GitHub SLSA provenance for 16/16 image digests.
- Confirmed the Cosign `v2.6.1` compatibility failure rather than misreporting the
  artifacts as absent.
- Inspected source run `30465630534`, its jobs, logs, 33 artifacts, hashes, and
  expiry dates.
- Downloaded representative Wolfi and patched scan/SBOM artifacts and checked image
  manifest binding, scanner metadata, database freshness, and SBOM generation data.
- Queried live repository rulesets, Actions policy, workflow token defaults,
  security features, and Pages environment protection.
- Inspected all published amd64 image configs and all repository smoke tests.

Not performed: destructive catalog-trigger exploitation, production registry
mutation, organization-level policy review, personnel/access review, or an
independent FedRAMP/SOC 2/ISO certification assessment.
