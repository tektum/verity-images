# Publication policy

## Build and monitoring cadence

Pushes to `main` rebuild affected published images. Pull requests build, scan, and
smoke-test affected images but never authenticate to GHCR, publish, sign,
attest, or move tags.

A daily scheduled workflow (`.github/workflows/monitor.yaml`) re-evaluates every
image in the published catalog at 03:17 UTC and also supports manual dispatch.
It verifies each image's attested per-platform SPDX SBOM against the publication
identity and scans that SBOM with the pinned Grype version. It pulls no image
layer, rescans no image, and rebuilds no image.

The catalog is sharded eight ways by logical image stream. Each shard publishes
its own code scanning category, so a failed shard leaves its previous alerts
untouched instead of retiring them.

Only findings with a published fix become code scanning alerts, the same rule
used by the publication gate. A package-level fix is a remediation candidate,
not proof that rebuilding unchanged inputs can ship it.

GitHub closes alerts when a later complete shard upload no longer reports the
finding. A failed or incomplete shard never closes an alert. Retiring a digest
is not a security fix.

The permanent, pinned [Image Dashboard](https://github.com/tektum/verity-images/issues/1091)
is a read-only image-level view derived from monitor reports. It updates only
after all eight shards complete against one coherent catalog and inventory. A
failed or incomplete scan preserves the previous complete dashboard snapshot.
The dashboard has no remediation controls, and issue edits trigger no builds,
updates, or other work.

Dashboard rows reflect findings with published fixes in the latest complete
scan. A row can disappear after a replacement passes the zero-fixable gate or
because advisory/fix metadata changes; issue state alone never proves a repair.
A missing, closed, or malformed dashboard issue fails the update; monitoring
never creates a replacement.

## Update cadence

Image sources, image-local Go and Cargo pins, and committed APKO locks are
reviewed inputs. They are not advanced merely because newer versions exist.
An APKO lock refresh is explicit and targets exactly one image.

Human-directed vulnerability repairs use a targeted rebuild when the reviewed
inputs can consume the candidate fix, or an image-local pull request when a
source, package, language dependency, recipe, or lock must change.
Infrastructure dependency maintenance is separate and does not advance image
inputs.

The monitor automatically routes a Wolfi Go-module finding to an exact rebuild only
when the stream's exact Melange recipe invokes the reviewed `go/remediate` pipeline.
It does not infer dependency edits for other recipes or language package types.
Blocked findings are scoped to their shared recipe or pure-APKO input set so an
independent flavor can still take its safe remediation route.

An operator starts an exact rebuild from `main` with an Image Dashboard stream
identifier such as `nats@2`:

```sh
gh workflow run build.yaml --ref main -f image=nats@2
```

The dispatch must identify exactly one enabled `NAME@VERSION` stream. It is
mutually exclusive with changed-image recovery, bypasses a matching recent
receipt only for that stream, and still uses the normal build, smoke test,
zero-fixable scan, publication, signing, attestation, and catalog flow. A
missing or ambiguous stream fails before any image job starts. A failed gate
publishes nothing; it never converts a finding into an exception.

## Vulnerability gates

Grype scans the same Syft-generated per-platform SPDX SBOMs that publication
later attests, before any registry push. Patched-image upstream comparisons use
the same Syft-to-Grype path. Scan JSON is kept as a workflow artifact and later
consumed by the catalog.

- Every image fails on any fixable vulnerability reported by Grype, regardless
  of severity or track. Unfixed findings remain in the report and catalog.
- Patched images record upstream and final scan results and may publish only
  when the final scan contains zero fixable vulnerabilities.

No image is admitted on the basis of improvement alone. A residual CVE delta is
evidence for diagnosis, not an exception to the publication gate.

A zero-fixable result only counts for software the scanner can see. Melange stamps
its binaries with a package note that makes Syft report the main software of a
source-built image under the local package name, so the Grype feeds match nothing.
`scripts/scan_identity.py` runs after Syft for every image built from an
image-local `melange.yaml` and fails the build unless `metadata.yaml` declares a
`scan-identity` (a CPE vendor and product or a purl type and name, versioned from
the recipe and appended to the platform SBOM), Syft natively reports a versioned
main component in a file the local package owns, or the image is on the shrink-only
allowlist `scripts/scan_identity_allowlist.d/` (one file per image; a follow-up pull
request deletes only its image's file). The injected package lives in the
attested SBOM, so the daily monitor scans exactly what the gate scanned. A declared
identity is asserted, not discovered: a wrong CPE or module path blinds the gate
for that image, so it needs the same review as a recipe change. Allowlisted images
predate the rule and are not covered for their main software until their
image-local follow-up lands. The exception is `no-feed` (kubernetes-reflector, opensearch-dashboards,
sonar-scanner-cli): no CPE, GHSA or OSV record exists for their main software, so
the gate covers dependencies and OS packages only, permanently. A pure APKO image
whose Wolfi package the feeds miss may opt in with `scan-identity` and
`scan-package`; the identity is then versioned from that package's locked
version in the same SBOM, so it cannot drift from what ships. See
[CONTRIBUTING.md](../CONTRIBUTING.md#scan-identity).

Patched images enable Copa's experimental patch-level library remediation.
When vulnerabilities affect npm's own bundled dependency tree, the source may
pin a complete npm distribution upgrade instead of replacing internals
independently. Its smoke test must exercise npm. Neither path weakens the final
Grype gate.

Trivy is used only to produce the Copacetic patch report. It never generates an
SBOM.

## Tags and platforms

Each successful version publication moves a version tag and either a dated tag
or, when declared by the image metadata, a major-version tag:

- `:<version>`
- `:<version>-<YYYYMMDD>` or `:<major>`

The highest enabled version for each image also moves `:latest`. Older streams
never overwrite `:latest` when rebuilt.

Non-default flavors suffix every tag, for example `:2-fips`, `:2.11-fips`, and
`:latest-fips`.

The `fips` suffix means only that the flavor's declared cryptographic mechanism
is enabled and its repository checks passed. It does not claim that an
application or container is CMVP validated. The shared OpenSSL provider recipe
uses the unmodified OpenSSL 3.1.2 inputs associated with certificate 4985, but
that certificate does not list Wolfi or Linux arm64 as tested operational
environments.

The provider APK contains `fips.so`, its package-time checksum, a static OpenSSL
configuration template, and an activation wrapper. It does not contain a
machine-generated `fipsmodule.cnf`. Each consuming container runs
`openssl fipsinstall` in an explicitly writable runtime directory before the
application starts, verifies the generated configuration and module, then
executes the original application argv. The image root filesystem may remain
read-only. APKO consumers use `https://tektum.github.io/verity-images/apk`, the
committed `verity-apk-2026.rsa.pub` key, and the pinned
`openssl-fips-provider=3.1.2-r3` package; they do not rebuild the provider.
FIPS Go images add a local entrypoint package that invokes the generic helper
before `/usr/bin/go`, so both `docker run IMAGE` and `docker run IMAGE version`
activate FIPS before Go starts.

Tags are mutable discovery aids. Consumers should pin
`ghcr.io/tektum/<image>@sha256:<digest>`.

Wolfi images publish for linux/amd64 and linux/arm64. Patched images preserve
the platforms available from their pinned upstream digest.

Source-built Wolfi images compile their arm64 packages in a separate native arm64
job of the same `build.yaml` run and commit, then merge them with the amd64
packages in the image job. The two package sets are signed by distinct ephemeral
Melange keys that exist only for that run and are never published; apko trusts both
for the candidate build. This changes where arm64 compiles, not what is published:
the image index, its signature identity, and the per-platform SBOMs and scans are
produced and verified exactly as for any other image.

## Signing identity

Every image index is signed by digest with keyless cosign. Publication runs in
the reusable workflow `.github/workflows/publish.yaml`, called by `build.yaml`
on `main`. The Fulcio certificate of every digest published from this change
onward therefore names `publish.yaml`:

```text
identity: https://github.com/tektum/verity-images/.github/workflows/publish.yaml@refs/heads/main
issuer: https://token.actions.githubusercontent.com
```

Digests published before that change were signed by `build.yaml` and keep
that identity; they are not re-signed. The catalog `policy.certificateIdentity`
is the current signer and `policy.certificateIdentityRegexp` accepts both. Each
catalog entry carries the exact verification commands for its own digest.

Use Cosign 3.0.6 or newer to verify these OCI-stored signatures and
attestations.

Verify any published digest, old or new, with:

```sh
cosign verify \
  --certificate-identity-regexp '^https://github\.com/tektum/verity-images/\.github/workflows/(build|publish)\.yaml@refs/heads/main$' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  ghcr.io/tektum/IMAGE@sha256:DIGEST
```

Use `--certificate-identity` with the `publish.yaml` value above to require the
current signer. Use `cosign verify-attestation --type spdxjson` with the same
flags for the SBOM.

The workflow uses only `GITHUB_TOKEN` plus GitHub's short-lived OIDC identity.
It requires no PAT or stored signing secret.

## SBOM and provenance

SPDX JSON is the only SBOM format. Every published platform SBOM is generated
with Syft against the built image for both tracks. One SBOM per platform is
attached to the corresponding image digest. Trivy is never an SBOM generator.

The public Rekor log rejects a request body above 24 MiB, and the attestation
base64-encodes the SBOM, so the largest SBOM that can be attested is about
18 MiB. `scripts/trim_sbom.py` runs in the publish action before the
vulnerability gate. An SBOM larger than 12 MiB (`MAX_SBOM_BYTES`) loses its
per-file entries: the SPDX `files` array and every relationship, `hasFiles`
entry, and `documentDescribes` entry that names a removed file. Every package,
CPE, purl, package relationship, and the document metadata stay, including the
scan-identity packages. The document `comment` records the removal and the
original file count. An SBOM at or under 12 MiB is never rewritten. Grype
matches packages, so the gate, the attestation, and the daily monitor all scan
the same trimmed document and find the same vulnerabilities as the full SBOM.
An SBOM that is still over the limit after the trim fails the publish.

Melange-backed Wolfi images also retain package-level provenance and a metadata
subpackage containing the resolved `go.mod` and `go.sum` used by the build.

Every pushed digest receives SLSA build provenance through
`actions/attest-build-provenance` and GitHub artifact attestations. The build,
push, and attestation all run inside `publish.yaml`, a reusable workflow, with
`attestations: write`, `contents: read`, `id-token: write`, and
`packages: write` on both the caller and the callee, as GitHub's guide for SLSA
v1 Build Level 3 requires. Verify the provenance and that this workflow made it:

```sh
gh attestation verify oci://ghcr.io/tektum/IMAGE@sha256:DIGEST \
  --repo tektum/verity-images \
  --signer-workflow tektum/verity-images/.github/workflows/publish.yaml
```

Only digests published after the reusable workflow landed satisfy
`--signer-workflow`; earlier digests carry provenance from `build.yaml` and
verify with `--repo` alone.

SLSA Build L3 limits, and what each now covers (see [BUILDER.md](BUILDER.md) for the
builder assessment and consumer verification policy):

- Provenance lists the Git commit as its only resolved dependency. Partly closed:
  the signed runner-environment attestation enumerates the apko lock or resolved
  upstream digest, the tool archive digests, and downloaded native arm64 package
  digests. They are not in the provenance `resolvedDependencies`, and Wolfi
  repository state is covered only through the lock's package pins.
- Builds run on self-hosted RunsOn runners, so the provenance reports
  `runnerEnvironment: self-hosted`. Partly closed: each digest carries a signed
  runner-environment attestation (fresh, IMDSv2-only instance bound to the job's
  runner). One instance per job is a documented RunsOn property and the stack
  settings are owner-asserted; neither is verified by this repository.
- Signing and the image build share one job. The reusable workflow keeps the
  signer identity out of the caller's control, but build steps in that job can
  reach the OIDC token, so they could also forge the runner attestation. A
  separate builder job would be needed to remove that exposure. Open.
- A builder assessment and consumer verification policy are published in
  [BUILDER.md](BUILDER.md). Closed.

Wolfi builds use and upload the reviewed, checked-in apko lock. Melange-backed
builds are the exception: their ephemeral package signature produces a
build-specific lock, so they upload that lock together with the recipe, package
provenance, and resolved dependency metadata. Patched builds use only the
checked-in source digest and record it in immutable build metadata. Schedules,
pushes, and pull requests all use reviewed inputs. Upstream and Wolfi package
updates require a pull request that changes the pin, recipe, or lock.

## Support

Images track current upstream versions on a best-effort basis. There is no SLA,
old-version maintenance, or guarantee that upstream vulnerabilities can be
fixed immediately.
