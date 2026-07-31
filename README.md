# Verity Images

[![build](https://github.com/tektum/verity-images/actions/workflows/build.yaml/badge.svg)](https://github.com/tektum/verity-images/actions/workflows/build.yaml)
[Catalog data](https://tektum.github.io/verity-images/catalog.json)

Verity Images is an open registry of small container images rebuilt from public
inputs. The repository contains the complete build, scan, test, signing, SBOM,
and provenance pipeline. Published vulnerability reports are tied to image
digests so every claim can be checked. Attached platform SBOMs are rescanned nightly;
vulnerable image versions have automatically maintained GitHub issues.

There are no accounts, private package feeds, or long-lived signing keys. A fork
can run the same pipeline with only its GitHub workflow token.

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

The `catalog-json` workflow artifact contains every digest, scan result, and
verification command. A static user interface is intentionally deferred.

## Tracks

The Wolfi track assembles minimal images from the public Wolfi package
repository with apko. It publishes linux/amd64 and linux/arm64 images and fails
on any fixable vulnerability.

The starting Wolfi catalog includes static and wolfi-base images, Node.js
20/22/24/26, Python 3.10/3.11/3.12/3.13/3.14, Go 1.25/1.26, nginx, and Caddy.
Caddy is compiled into local plain and FIPS APK flavors with Melange before
APKO assembles the corresponding image tags. Go toolchains also publish FIPS
flavors that build with the Go Cryptographic Module v1.0.0 enabled by default.
Each language stream is built from its versioned Wolfi package. Go 1.24 is
defined but disabled because its last Wolfi package has fixable High and
Critical vulnerabilities and no fixed 1.24 release exists.

The patched track starts from a pinned upstream Debian or slim image, scans it
with Trivy, patches it with Copacetic, and records the residual vulnerability
delta. It preserves upstream compatibility and platforms.

Both tracks must have zero fixable Grype findings before publication.
Patched images also use Copa's experimental patch-level library remediation for
supported npm and pip findings before the final gate.

The patched catalog includes Debian 12 slim and Node.js 22 slim. Their source
index digests and enabled platforms are declared in each `source.yaml`.

Both tracks use the same `.github/actions/publish-image/action.yaml` tail for
the scan gate, smoke test, digest signing, SPDX attestation, provenance, and tag
promotion.

## Repository map

- `images/nginx/apko.yaml` defines the first Wolfi image.
- `scripts/gen_matrix.py` generates the workflow matrix.
- `.github/workflows/build.yaml` builds and publishes images.
- `.github/workflows/lint.yaml` validates repository policy.
- `devbox.json` locks local and CI lint tooling.
- `docs/POLICY.md` defines publication and support policy.
- `docs/MIGRATION_NOTES.md` records clean-room recon decisions.

To add an image, add one image directory with its build source, `metadata.yaml`,
and `tests/test.sh`, then open a pull request. See `CONTRIBUTING.md` for the
required fields and checks.

Licensed under `LICENSE`.
