# Publication policy

## Build and monitoring cadence

Pushes to `main` rebuild published images. Pull requests build, scan, and
smoke-test affected images but never authenticate to GHCR, publish, sign,
attest, or move tags.

After publication, the external [`tektum/squawk`](https://github.com/tektum/squawk)
service stores each platform SBOM once and compares its components with incremental
OSV updates. Finding deliveries open or update one issue per immutable image. They
can add or reopen findings, but their absence never closes an issue.

Resolution uses a separate authenticated reconciliation protocol. A wakeup from
the pinned Squawk GitHub App identity carries only the immutable image and source
key. The workflow exchanges a GitHub Actions OIDC token with the configured trusted
Squawk origin, fetches the latest durable checkpoint, serializes application per
source image, persists its monotonic revision on the issue, and acknowledges that
exact revision only after every issue mutation succeeds. The workflow fails closed
when the origin is unconfigured or the checkpoint is blocked, stale, incomplete,
unsupported, out of order, or bound to different OCI index children.

A security-fixed closure requires a fresh complete inventory checkpoint: both
attested linux/amd64 and linux/arm64 SBOMs, child digests verified against the
published index, complete package evaluation, a fresh advisory-feed check, and the
full current unsuppressed finding set. Historical retirement is a distinct
authoritative lifecycle event and never asserts that findings in the retired digest
were fixed. Consolidation copies unique bot finding evidence into the canonical
thread and links each untouched duplicate body and discussion before closing it.
The monitor does not pull image layers, rescan images, or rebuild images.

Operators configure the canonical API origin in the repository variable
`SQUAWK_RECONCILIATION_ORIGIN`; an unset or non-HTTPS origin blocks version 2
without falling back to payload-provided URLs. `SQUAWK_RECONCILIATION_V2_REQUIRED`
remains unset while version 1 findings drain, then is set to `true` only after the
producer has an eligible full checkpoint and the OIDC run binding has been proven
in CI. Once set, stale version 1 dispatches are rejected rather than reopening an
already reconciled image.

## Vulnerability gates

Grype records every known candidate vulnerability before any registry push. Scan
JSON is kept as a workflow artifact and later consumed by the catalog.

- Every image fails on any fixable vulnerability reported by Grype, regardless
  of severity or track. Unfixed findings remain in the report and catalog.
- Patched images record upstream and final scan results and may publish only
  when the final scan contains zero fixable vulnerabilities.

No image is admitted on the basis of improvement alone. A residual CVE delta is
evidence for diagnosis, not an exception to the publication gate.

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

## Signing identity

Every image index is signed by digest with keyless cosign. The expected Fulcio
certificate values are:

```text
identity: https://github.com/tektum/verity-images/.github/workflows/build.yaml@refs/heads/main
issuer: https://token.actions.githubusercontent.com
```

Use Cosign 3.0.6 or newer to verify these OCI-stored signatures and
attestations.

Verify a digest with:

```sh
cosign verify \
  --certificate-identity 'https://github.com/tektum/verity-images/.github/workflows/build.yaml@refs/heads/main' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  ghcr.io/tektum/IMAGE@sha256:DIGEST
```

The workflow uses only `GITHUB_TOKEN` plus GitHub's short-lived OIDC identity.
It requires no PAT or stored signing secret.

## SBOM and provenance

SPDX JSON is the only SBOM format. Wolfi images use apko's native SPDX output.
Patched images use Syft against the final patched image. One complete SBOM per
platform is attached to the corresponding image digest. Trivy is never an SBOM
generator.

Melange-backed Wolfi images also retain package-level provenance and a metadata
subpackage containing the resolved `go.mod` and `go.sum` used by the build.

Every pushed digest receives SLSA build provenance through
`actions/attest-build-provenance` and GitHub artifact attestations.

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
