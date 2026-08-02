# APK repository state

[`packages/repository-state.json`](../packages/repository-state.json) and
[`packages/repository-state.pin.json`](../packages/repository-state.pin.json)
are the reviewed pin contract for the published APK repository release. They
identify one immutable release asset, the archive root and manifest, the active
public key, and the package metadata for both supported architectures. A
release update must deliberately update both files in the same reviewed PR.

Validate the checked-in state with `check-jsonschema` and
`python3 scripts/validate_repository_state.py`. For a release update, run
`python3 scripts/validate_repository_state.py --live`, download the candidate
asset without modifying the release, and run the same command with
`--archive PATH` to bind the independently computed archive and manifest
digests.

Renovate may open a PR when a newer `apk-repo-vNNNN` release appears. It is
globally configured to create PRs without Renovate or platform automerge. A
reviewer must complete every immutable field in both pin files, run the
validation commands, and merge the PR. No updater may push, merge, or otherwise
mutate repository state on `main`.
