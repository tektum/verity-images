# Publication policy

## Build and monitoring cadence

Pushes to `main` rebuild published images. Pull requests build, scan, and
smoke-test affected images but never authenticate to GHCR, publish, sign,
attest, or move tags.

After publication, Squawk stores each platform SBOM once and compares its
components with incremental OSV updates. New findings dispatch the monitor
workflow, which opens or updates one issue per vulnerable image version. The
monitor does not pull image layers, rescan images, or rebuild images.

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

The notification uses only `GITHUB_TOKEN`. Keyless Cosign and GitHub attestations
also require GitHub's ephemeral OIDC token. The workflow requires no PAT, stored
signing secret, Squawk URL, Squawk credential, or Descope machine token.

## SBOM and provenance

Wolfi images use apko's native SPDX output and patched images use Syft against
the final image. The shared publish action derives CycloneDX from each platform
SPDX document and creates one commit-pinned `actions/attest` v4 GitHub SBOM
attestation against each platform digest. Trivy is never an SBOM generator.

The producer then creates one GitHub deployment per platform after Cosign
verification. Its payload contains the immutable platform and logical/index image
references, platform, and attestation subject digest. Squawk fetches the
repository attestation via a repository-scoped GitHub App token and checks the
in-toto CycloneDX schema. Squawk deliberately does not implement Sigstore
verification; independent verification is future hardening.

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
