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

## Recovery backup inventory

The inventory identifier is `apk-signing-root-2026-recovery`. It records only
safe metadata: the encrypted artifact SHA-256, creation date, restrictive
`0600` permissions, OpenPGP recipient fingerprint, and recipient packet ID.
The encrypted artifact, plaintext key, vault location, and decrypted output
must never be committed or included in workflow logs.

An authorized operator verifies a supplied `BACKUP_FILE` without displaying its
contents:

```sh
set -euo pipefail

test "$(stat -c '%a' "$BACKUP_FILE")" = 600
sha256sum "$BACKUP_FILE"
gpg --list-packets "$BACKUP_FILE" | grep -E 'pubkey enc packet|keyid|encrypted data packet'
```

Compare the output with the external inventory record before recovery. The
recorded recipient fingerprint is `35C9...E84`; packet metadata may identify a
recipient subkey rather than that primary fingerprint.

For an approved recovery, decrypt only into a private temporary directory,
derive the public key, and compare its DER SubjectPublicKeyInfo digest to the
committed trust root:

```sh
set -euo pipefail

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
umask 077
gpg --decrypt --output "$work/repository.key" "$BACKUP_FILE"
actual=$(openssl pkey -in "$work/repository.key" -pubout -outform DER | sha256sum | awk '{print $1}')
test "$actual" = 764c84bdcf9ca8530146da9976d4cac4b37ba961ad258d589e9a11fb05206698
openssl pkey -in "$work/repository.key" -pubout -outform DER > "$work/repository.pub.der"
openssl pkey -pubin -in packages/keys/verity-apk-2026.rsa.pub -pubout -outform DER > "$work/committed.pub.der"
cmp "$work/repository.pub.der" "$work/committed.pub.der"
```

Do not install a recovered key into production during this check. For rotation,
create a new restricted key, commit its public key and fingerprint, replace the
protected environment secret, update both repository-state contract files and
every active-key fingerprint or public-key reference, create and verify a new
encrypted inventory record, run the protected smoke workflow, then publish with
the new key. Keep the old public key for historical verification and revoke it
if compromise is suspected.

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
overwritten.

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
