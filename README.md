# Verity Images

[![build](https://github.com/tektum/verity-images/actions/workflows/build.yaml/badge.svg)](https://github.com/tektum/verity-images/actions/workflows/build.yaml)
[Catalog data](https://tektum.github.io/verity-images/catalog.json)

Verity Images is an open registry of small container images rebuilt from public
inputs. The repository contains the complete build, scan, test, signing, SBOM,
and provenance pipeline. Published vulnerability reports are tied to image
digests so every claim can be checked. Attached platform SBOMs are rescanned nightly;
vulnerable image versions have automatically maintained GitHub issues.

Container image publication is keyless: a fork can run it with only its GitHub
workflow token. APK releases use a protected RSA signing secret; see [APK
signing](docs/APK_REPOSITORY_SIGNING.md).

## Quickstart

Pull by digest in production:

```sh
docker pull ghcr.io/tektum/nginx@sha256:DIGEST
```

Verify the keyless signature:

```sh
cosign verify \
  --certificate-identity 'https://github.com/tektum/verity-images/.github/workflows/build.yaml@refs/heads/main' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  ghcr.io/tektum/nginx@sha256:DIGEST
```

Verification requires Cosign 3.0.6 or newer because signatures and attestations
use its OCI storage format.

Fetch the SPDX JSON SBOM attestation:

```sh
cosign download attestation ghcr.io/tektum/nginx@sha256:DIGEST > attestation.json
```

The published [catalog](https://tektum.github.io/verity-images/) and its
[`catalog.json`](https://tektum.github.io/verity-images/catalog.json) expose every
digest, scan result, and verification command.

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
- `.github/workflows/build.yaml` builds and publishes images.
- `.github/workflows/lint.yaml` validates repository policy.
- `devbox.json` locks local and CI lint tooling.
- [APK signing](docs/APK_REPOSITORY_SIGNING.md) and [repository state](docs/APK_REPOSITORY_STATE.md) document APK key recovery, retention, and rollback rehearsal.
- [Catalog recovery](docs/CATALOG_RECOVERY.md) documents stale-catalog diagnosis,
  changed-image backfill, and public verification.
- `docs/POLICY.md` defines publication and support policy.
- `docs/MIGRATION_NOTES.md` records clean-room recon decisions.

To add an image, add one image directory with its build source, `metadata.yaml`,
and `tests/test.sh`, then open a pull request. See `CONTRIBUTING.md` for the
required fields and checks.

Licensed under `LICENSE`.
