# Verity Images

[![build](https://github.com/tektum/verity-images/actions/workflows/build.yaml/badge.svg)](https://github.com/tektum/verity-images/actions/workflows/build.yaml)
[Catalog](https://verity.supply/)
[Catalog data](https://verity.supply/catalog.json)
[Trust and verification](https://verity.supply/trust.html)
[Image Dashboard](https://github.com/tektum/verity-images/issues/1091)

Free, minimal container images that publish the evidence behind every digest.
No account, no paid tier, no pull token: `docker pull verity.supply/<image>`.

Verity Images is an open registry of about a hundred small container images
rebuilt from public inputs: minimal images assembled from Wolfi packages, plus a
patched track that keeps selected upstream images (for example `postgres` and
`node` slim variants) compatible while removing fixable vulnerabilities. This
repository is the whole pipeline: build, scan, smoke test, signing, SBOM,
provenance, and the catalog.

## What you can check

- **The gate is 0 fixable vulnerabilities at publish time, not 0 CVE.** Grype
  scans every candidate. A finding with an available fix fails the build and
  publishes nothing; there is no exception path. Findings with no upstream fix
  stay visible on each catalog record.
- **Every digest is re-checked daily.** The attested SPDX SBOM of every
  published digest is re-evaluated against the current vulnerability database.
  A finding that becomes fixable appears as a code scanning alert in this repository.
- **Keyless signatures, SBOMs, and provenance.** Images are signed with cosign
  through GitHub OIDC, carry one SPDX SBOM per platform on the index digest, and
  SLSA build provenance. Digests published through the reusable `publish.yaml`
  workflow follow the SLSA Build L3 pattern and also carry a signed
  runner-environment attestation from a single-use runner. See
  [docs/BUILDER.md](docs/BUILDER.md).
- **Every claim ships with its command.** Each record in
  [`catalog.json`](https://verity.supply/catalog.json) carries the exact verify
  commands for its own digest.
- **Forkable.** Image publication is keyless: a fork can run it with only its
  GitHub workflow token. APK releases use a protected RSA signing secret; see
  [APK signing](docs/APK_REPOSITORY_SIGNING.md).

## What it is not

- No SLA and no old-version maintenance; see `docs/POLICY.md`.
- FIPS flavors enable the OpenSSL 3.1.2 FIPS provider, Go FIPS mode, or both.
  They are not CMVP validated.
- Digests published before the reusable workflow carry `build.yaml` provenance
  until they are rebuilt, and signing still shares a job with the build. The
  open gaps are tracked in `docs/COMPLIANCE_AUDIT.md`.
- A small catalog. If an image is missing, open an issue or a pull request.

## Quickstart

Pick a digest from the [catalog](https://verity.supply/) and pull by digest:

```sh
docker pull verity.supply/nginx@sha256:DIGEST
```

Verify the keyless signature (Cosign 3.0.6 or newer):

```sh
cosign verify \
  --certificate-identity-regexp '^https://github\.com/tektum/verity-images/\.github/workflows/(build|publish)\.yaml@refs/heads/main$' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  verity.supply/nginx@sha256:DIGEST
```

Verify the SPDX SBOM attestation the same way with
`cosign verify-attestation --type spdxjson`, or download it with
`cosign download attestation verity.supply/nginx@sha256:DIGEST`.

Verify SLSA build provenance. `gh attestation verify` uses GitHub's attestation
API, so it takes the canonical `ghcr.io` reference:

```sh
gh attestation verify oci://ghcr.io/tektum/nginx@sha256:DIGEST \
  --repo tektum/verity-images \
  --signer-workflow tektum/verity-images/.github/workflows/publish.yaml
```

`--signer-workflow` applies to digests published through `publish.yaml`. Drop it
for older digests, whose provenance was signed by `build.yaml`. Each catalog
record carries the exact command for its own digest.

`verity.supply/<image>` is a read-only alias for `ghcr.io/tektum/<image>`; both
serve the same digests. The builder assessment, the runner-environment
attestation, and the full consumer verification policy are in
[docs/BUILDER.md](docs/BUILDER.md).

## Tracks

The Wolfi track assembles minimal images from the public Wolfi package
repository with apko. It publishes linux/amd64 and linux/arm64 images and fails
on any fixable vulnerability.

The Wolfi catalog covers minimal bases, language runtimes, web servers,
databases, infrastructure tools, and other common services. Some images also
publish FIPS flavors built from image-local Melange packages. The corresponding
plain and FIPS flavors share one upstream version and preserve the same runtime
contract. Disabled definitions remain quarantined until their documented
vulnerability or compatibility blocker is resolved.

Source-built images compile their arm64 packages on a native arm64 runner and
their amd64 packages on an amd64 runner, then assemble one multi-architecture
image. This replaced hours of emulated compilation with minutes; see
[Native arm64 compile](CONTRIBUTING.md#native-arm64-compile).

The patched track starts from a pinned upstream image, scans it with Trivy,
patches it with Copacetic, and records the residual vulnerability delta. It
preserves upstream compatibility across linux/amd64 and linux/arm64.

Both tracks must have zero fixable Grype findings before publication.
Patched images also use Copa's experimental patch-level library remediation for
supported npm and pip findings before the final gate.

Patched definitions cover compatible upstream applications and base images.
Each `source.yaml` pins the upstream index digest and both enabled platforms.

Both tracks use the same `.github/actions/publish-image/action.yaml` tail for
the scan gate, smoke test, digest signing, SPDX attestation, provenance, and tag
promotion.

## Repository map

- `images/nginx/apko.yaml` is a representative Wolfi image definition.
- `scripts/gen_matrix.py` generates the workflow matrix.
- `.github/workflows/build.yaml` plans and validates images and calls the reusable publisher.
- `.github/workflows/publish.yaml` builds, signs, attests, and publishes images.
- `.github/workflows/lint.yaml` validates repository policy.
- `devbox.json` locks local and CI lint tooling.
- [APK signing](docs/APK_REPOSITORY_SIGNING.md) and [repository state](docs/APK_REPOSITORY_STATE.md) document APK key recovery, retention, and rollback rehearsal.
- [Catalog recovery](docs/CATALOG_RECOVERY.md) documents stale-catalog diagnosis,
  changed-image backfill, and public verification.
- `docs/POLICY.md` defines publication and support policy.
- `docs/BUILDER.md` assesses the builder and defines consumer verification.
- `docs/MIGRATION_NOTES.md` records clean-room recon decisions.

To add an image, add one image directory with its build source, `metadata.yaml`,
and `tests/test.sh`, then open a pull request. See `CONTRIBUTING.md` for the
required fields and checks.

Licensed under `LICENSE`.
