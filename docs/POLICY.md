# Publication policy

## Rebuild cadence

The full enabled catalog rebuilds daily at 03:17 UTC. Pushes to `main` rebuild
affected images. Pull requests build, scan, and smoke-test affected images but
never authenticate to GHCR, publish, sign, attest, or move tags.

## Vulnerability gates

Grype scans every candidate before release tags are applied. Scan JSON is kept
as a workflow artifact and later consumed by the catalog.

- Every image fails on any fixable vulnerability reported by Grype, regardless
  of severity or track.
- Patched images record upstream and final scan results and may publish only
  when the final scan contains zero fixable vulnerabilities.

No image is admitted on the basis of improvement alone. A residual CVE delta is
evidence for diagnosis, not an exception to the publication gate.

Patched images enable Copa's experimental library remediation for supported npm
packages. Patch-level upgrades are the default. A source may explicitly allow
major upgrades only when its smoke test exercises the affected package manager.
Experimental remediation does not weaken the final Grype gate.

Trivy is used only to produce the Copacetic patch report. It never generates an
SBOM.

## Tags and platforms

Each successful version publication moves two tags:

- `:<version>`
- `:<version>-<YYYYMMDD>`

The highest enabled version for each image also moves `:latest`. Older streams
never overwrite `:latest` when rebuilt.

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
Patched images use Syft against the final patched image. SBOMs are attached to
the corresponding image digest. Trivy is never an SBOM generator.

Every pushed digest receives SLSA build provenance through
`actions/attest-build-provenance` and GitHub artifact attestations.

Wolfi builds upload the exact apko lock used by the build. Patched builds keep
the checked-in source digest and record any newly resolved upstream digest in
immutable build metadata instead of committing from a scheduled workflow.
The daily schedule resolves the current upstream tag, records both the pinned
and resolved digests, and patches the resolved digest. Pull requests and pushes
use the checked-in digest so their inputs remain reproducible.

## Support

Images track current upstream versions on a best-effort basis. There is no SLA,
old-version maintenance, or guarantee that upstream vulnerabilities can be
fixed immediately.
