# APK repository signing

The active APK repository root is `verity-apk-2026`. Its public key is
[`packages/keys/verity-apk-2026.rsa.pub`](../packages/keys/verity-apk-2026.rsa.pub).
The SHA-256 fingerprint of the DER-encoded SubjectPublicKeyInfo is:

```text
764c84bdcf9ca8530146da9976d4cac4b37ba961ad258d589e9a11fb05206698
```

The private root is available only as the `APK_REPOSITORY_PRIVATE_KEY` secret in
the protected `apk-signing` environment. Its encrypted recovery copy is held
in the approved signing-backup vault and recorded in the signing inventory.

## Signing policy

Only workflows running from `main` may use the protected environment. Every
published package version is signed once: do not replace, rebuild, or re-sign a
published package version. Publish a new version for any correction.

The `APK signing smoke` workflow is a protected, disposable sign-and-verify
check. It creates no repository, signature, or key artifact.

`Build APK repository` builds and runtime-tests the FIPS package once on each
native GitHub-hosted architecture. The resulting unsigned packages are kept for
seven days and receive GitHub artifact attestations. Only a manual dispatch from
`tektum/verity-images` at `refs/heads/main` can enter `apk-signing`; before the
key is read, it verifies the immutable source SHA, same-run artifact IDs and
digests, and attestations bound to this workflow. The job creates an
`apk-repo-vNNNN` draft release with the sole asset
`verity-apk-repository.tar.zst`; its release notes carry the archive checksum
and attestation provenance. Existing tags, releases, or asset paths are never
overwritten. A failed reservation remains as a draft and blocks retries; after
reviewing that no asset was uploaded, an operator must explicitly remove it with
`gh release delete apk-repo-vNNNN --yes --cleanup-tag` before retrying.

## Rotation and revocation

To rotate the root, generate a new key under a restrictive umask, commit its
public key and fingerprint, replace the protected environment secret, encrypt a
new backup to the authorized recovery recipient, and run the protected smoke
before any publication uses it. Retain the old public key for verification of
already-published packages.

If a root is suspected compromised, immediately disable its environment secret,
stop publication, and publish a keyless-cosign-signed revocation record and
replacement keyring with the repository trust metadata. Clients must fetch that
metadata before accepting cached trust data; the revocation record takes
precedence, and the compromised key becomes historical-only and cannot validate
new artifacts. Announce affected package versions and publish the replacement
root and new package versions. Do not repair an already-published signature in
place.
