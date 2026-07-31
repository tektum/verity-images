# Migration notes

This repository is a clean-room rebuild. No source or Git history was imported
from `verity-org`. Recon was performed against the public repositories and refs
available on 2026-07-29.

## Public repository inventory

- [`verity-org/verity`](https://github.com/verity-org/verity/tree/44e540acf421063c4cfdef5d7db208fdaa5c0055)
  was the active image and pipeline repository. It held 335 image manifests and
  98 configured upstream images for Copa remediation.
- [`verity-org/integer`](https://github.com/verity-org/integer/tree/47445c54bf928b3328234836f8482d95cab8fec4)
  was the archived predecessor for minimal Wolfi images. Its 76 manifests were
  carried into the active Verity catalog.
- [`verity-org/copacetic`](https://github.com/verity-org/copacetic/tree/78d74120ec5ba079c60a573dee2f4e642b9a2a7a)
  was a fork of `project-copacetic/copacetic`, the patching tool used by Verity.
- [`verity-org/wolfi-dev-os`](https://github.com/verity-org/wolfi-dev-os/tree/3bc1a15922962c2ffbc0844b7f98672b79c5fd71)
  was a fork of the Wolfi package repository and included apko, melange, and
  signing configuration.
- [`verity-org/.github`](https://github.com/verity-org/.github/tree/786d4a6f7ff04df6188d82bf3b1320dae65f6c2d)
  provided shared setup and lint automation, not image publication.

## Pipeline inventory

### Patched images

[`orchestrator.yaml`](https://github.com/verity-org/verity/blob/44e540acf421063c4cfdef5d7db208fdaa5c0055/.github/workflows/orchestrator.yaml)
ran nightly at 02:00 UTC and called
[`patch-image.yaml`](https://github.com/verity-org/verity/blob/44e540acf421063c4cfdef5d7db208fdaa5c0055/.github/workflows/patch-image.yaml).
The workflow selected upstream tags from `copa-config.yaml`, scanned with Trivy,
patched with Copa, pushed to GHCR, signed the resulting digest with keyless
cosign, generated a CycloneDX SBOM with Syft, and created an attestation. It
also wrote reports and a preflight manifest to a dedicated `reports` branch
through the GitHub Contents API.

### Wolfi images

The Integer workflow chain was
`integer-orchestrator.yaml` -> `integer-orchestrator-reusable.yaml` ->
`integer-build-shard.yaml` -> `integer-build-image-reusable.yaml`. It synced
package streams at 01:30 UTC, built at 03:00 UTC, and published at 04:00 UTC.
The build used melange for custom packages and apko for multi-architecture
images, ran a Trivy publish gate, pushed to GHCR, created provenance, signed
with keyless cosign, and attached an apko-generated SPDX SBOM.

The legacy `verity-org/integer` repository used the same broad model with a
smaller 76-image catalog and separate build and catalog schedules.

### Signing and software bills of materials

Both tracks signed immutable image digests with keyless cosign. The Copa track
used Syft to generate CycloneDX JSON. The Integer track used apko to generate
SPDX JSON. Trivy was used for vulnerability reports and gates, not SBOM
generation, in the public revisions inspected.

## Defects checked during recon

### README workflow filename

The reported pre-launch defect was that README content named a pipeline
workflow whose filename did not match the repository tree. An exhaustive search
of all publicly reachable history in `verity-org/verity` and
`verity-org/integer`, including renamed and deleted workflow paths, found no
public commit containing that mismatch. The current Verity README refers only
to a workflow identity prefix, not a workflow filename.

The rebuild still prevents this class of defect by running
`scripts/check_readme_refs.py` in CI. Any README path must exist in the checked
out tree. This is the construction-time guard required even though the affected
pre-launch revision is not publicly recoverable.

### SBOM inconsistency

The reported defect described inconsistent Trivy and Syft SBOM output. Public
history confirms an inconsistency, but not that tool pairing:

- Copa commit [`81c1c355`](https://github.com/verity-org/verity/commit/81c1c35508905e1b470ba21eecc6e71d68407c6a)
  generated CycloneDX JSON with Syft. Trivy produced vulnerability JSON only.
- Integer commit [`7a438983`](https://github.com/verity-org/integer/commit/7a438983939f40b0a214164ce0cd31523357b1a6)
  attached apko-generated SPDX JSON. Trivy was the vulnerability gate only.
- Integer commit [`4807764d`](https://github.com/verity-org/integer/commit/4807764d5fd5c2c7cea34715c8f393a5d5a8fc38)
  later fixed SBOM path and attestation mechanics without changing the SPDX
  format or making Trivy an SBOM generator.

The rebuild removes the inconsistency by committing to SPDX JSON for both
tracks. Wolfi uses apko's native SPDX output. Patched images use Syft SPDX JSON.
Trivy does not generate an SBOM.

## Concepts carried forward

- Reviewed rebuilds: source pins and package locks change through `main`, while
  nightly SBOM scans detect newly disclosed vulnerabilities without rebuilding.
- Separate minimal and compatible tracks: serves distinct consumer needs
  without weakening either contract.
- Digest-first signing and attestations: verification must identify immutable
  content, not a movable tag.
- Multi-architecture Wolfi images: amd64 and arm64 are common deployment
  targets and apko supports both directly.
- Trivy-to-Copa patch reports: Copa consumes scanner findings to produce a
  measurable upstream-to-patched CVE delta.
- Keyless GitHub OIDC signing: avoids long-lived signing secrets.
- Nightly off-peak monitoring: a single 03:17 UTC SBOM scan avoids a round-hour
  traffic spike and opens or updates remediation issues.
- Human-friendly version and date tags: supports discovery while documentation
  directs production consumers to digests.
- Reports tied to image digests: makes vulnerability claims independently
  checkable.
- Melange package builds: images that need dependency remediation or build
  flavors use pinned source commits, explicit overrides, package provenance,
  and preserved resolved dependency metadata.

## Concepts deliberately dropped

- The 335-image catalog: expansion remains review-driven so every image keeps a
  clear owner, source pin, runtime test, and vulnerability gate.
- The Wolfi and Copacetic forks: upstream public releases are sufficient and
  remove fork maintenance.
- Helm chart generation and integration: charts are outside the image registry
  mission.
- APK repository publication: Melange may create ephemeral signed repositories
  during a build, but no reusable package repository or signing key is published.
- A reports branch and commit-back loop: source digests and resolved packages
  are recorded in immutable build artifacts, avoiding `contents: write` and
  scheduled self-commits.
- CycloneDX output: one SPDX JSON contract is simpler for consumers to verify.
- Per-image workflow families and sharding: one generated matrix and one shared
  publish action are enough for the v1 catalog.

## Melange build model

Melange is a first-class source-build path, not a Caddy exception. Future images
may use it for dependency remediation, custom packages, or build flavors. Every
recipe must pin its upstream commit and dependency overrides, emit package
provenance, preserve resolved dependency metadata, and feed its signed ephemeral
repository into APKO. Final images remain subject to the same zero-fixable-CVE,
SBOM, keyless-signature, and SLSA provenance controls as package-only images.

Flavor tags are discovery aliases only. Production consumers remain directed to
signed image digests.

## Rebuild decisions

- Patched upstream digest updates are recorded in build metadata, not committed
  to `source.yaml`. Each checked-in source remains pinned, and each publication run
  records the resolved digest it actually used. This avoids write permission
  and workflow loops while preserving reproducibility.
- Wolfi streams may use reviewed public packages or reviewed Melange recipes.
  Package revisions and locally built package digests are recorded by each build.
- Images publish to flat names such as `ghcr.io/tektum/nginx`. The v1 names do
  not collide with existing repository names, and flat references are easier
  to consume.
