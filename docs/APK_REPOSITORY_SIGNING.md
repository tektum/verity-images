# APK repository signing

The active APK repository root is `verity-apk-2026`. Its public key is
[`packages/keys/verity-apk-2026.rsa.pub`](../packages/keys/verity-apk-2026.rsa.pub).
The SHA-256 fingerprint of the DER-encoded SubjectPublicKeyInfo is:

```text
764c84bdcf9ca8530146da9976d4cac4b37ba961ad258d589e9a11fb05206698
```

The private root is available only as the `APK_REPOSITORY_PRIVATE_KEY` secret in
the protected `apk-signing` environment. Its encrypted recovery copy is
`/home/omer/verity-apk-backups/verity-apk-2026.rsa.gpg`, mode `0600`, encrypted
to OpenPGP recipient `35C9A26ADAAC05CD48AD8017F36402150EB30E84`.

## Signing policy

Only workflows running from `main` may use the protected environment. Every
published package version is signed once: do not replace, rebuild, or re-sign a
published package version. Publish a new version for any correction.

The `APK signing smoke` workflow is a protected, disposable sign-and-verify
check. It creates no repository, signature, or key artifact.

## Rotation and revocation

To rotate the root, generate a new key under a restrictive umask, commit its
public key and fingerprint, replace the protected environment secret, encrypt a
new backup to the authorized recovery recipient, and run the protected smoke
before any publication uses it. Retain the old public key for verification of
already-published packages.

If a root is suspected compromised, immediately disable its environment secret,
stop publication, announce the affected package versions, and publish a new
root and package versions. Do not attempt to repair an already-published
signature in place.
