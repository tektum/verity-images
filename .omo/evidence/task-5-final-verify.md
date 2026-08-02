# Task 5 Final Verification

## Verdict

APPROVED. Follow-up commit `5e92725` closes the deterministic validation gaps
found in `b7647fc48b8eb4a7e71bdc7d0cc1006015924eb5`.

## Confirmed Live Values

- Repository: `tektum/verity-images`.
- Release: `363733856`, `apk-repo-v0001`, target
  `ed3f06217e1452683a974f52794331ab298219c2`, immutable, non-draft, and
  non-prerelease.
- Asset: `498710090`, `verity-apk-repository.tar.zst`,
  `sha256:1d56b5710707b2aff9ee1e9cd0876466a6eb795fca5d0e58bb3f91c5c2922802`.
- A fresh download by asset ID hashed to
  `1d56b5710707b2aff9ee1e9cd0876466a6eb795fca5d0e58bb3f91c5c2922802` and
  passed `python3 scripts/validate_repository_state.py --archive ARCHIVE`.
- `python3 scripts/validate_repository_state.py --live` passed.

## Defect Fixes

- `packages/repository-state.pin.json` is a separately reviewed immutable
  contract. The validator rejects any state differing from it, so a release
  update must deliberately change both reviewed files.
- The contract pins release and asset IDs, tag, target commit, archive and
  manifest digests, key fingerprint, and exact package identity/path/hash for
  each architecture.
- State validation rejects architecture/path disagreement and reused package
  paths or hashes. Archive validation compares the extracted manifest to the
  reviewed contract, then validates extracted signed APKs and indexes with the
  existing repository policy.
- Renovate has global `automerge: false`, `platformAutomerge: false`,
  `automergeType: "pr"`, and `prCreation: "immediate"`; a final wildcard rule
  prevents package-rule overrides.

## Updater Policy

The regression test asserts the global policy, the wildcard rule, state-review
labels, and that no package rule can enable Renovate automerge, platform
automerge, branch automerge, or deferred/non-PR creation.

## Test Matrix

| Check | Result |
| --- | --- |
| State schema, owner/tag/asset/digest/key/root/self-hash negatives | Rejected |
| Release/asset ID substitution | Rejected |
| Package name/version/epoch substitution | Rejected |
| Architecture/path mismatch | Rejected |
| Duplicate APK path/hash reuse | Rejected |
| Forged archive and manifest digests | Rejected |
| Global Renovate automerge/platform/direct-mutation override | Rejected |
| `./scripts/devbox.sh run python3 scripts/test_repository_state.py` | Passed |
| `./check` | Passed (exit 0) |
| Live release plus downloaded asset archive | Passed |

## Live Validation

Downloaded `verity-apk-repository.tar.zst` from
`tektum/verity-images` release `apk-repo-v0001`, then ran:

```sh
./scripts/devbox.sh run python3 scripts/validate_repository_state.py \
  --live --archive /tmp/.../verity-apk-repository.tar.zst
```

The validator accepted the live release, exact asset digest, pinned manifest,
signed indexes, and both architecture-specific APKs.

## Commits And Cleanup

- `b7647fc48b8eb4a7e71bdc7d0cc1006015924eb5` initial immutable release state.
- `5e92725` immutable contract, archive validation, regression coverage, and
  global Renovate PR-only policy.
- Temporary downloaded archive was removed after validation.
- Final cleanup and clean-worktree check follow the evidence commit.

## DoneClaim

Task 5 deterministic pin, archive, and updater-policy invariants are complete.
