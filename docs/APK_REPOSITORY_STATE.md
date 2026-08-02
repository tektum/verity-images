# APK repository state

[`packages/repository-state.json`](../packages/repository-state.json) is the
reviewed pin for the published APK repository release. It identifies one
immutable release asset, the archive root and manifest, the active public key,
and the package metadata for both supported architectures.

Validate the checked-in state with `check-jsonschema` and
`python3 scripts/validate_repository_state.py`. For a release update, run
`python3 scripts/validate_repository_state.py --live`, download the candidate
asset without modifying the release, and run the same command with
`--archive PATH` to bind the independently computed archive and manifest
digests.

Renovate may open a PR when a newer `apk-repo-vNNNN` release appears. It is
configured not to automerge. A reviewer must complete every immutable field in
the state, run the validation commands, and merge the PR. No automation may
push, merge, or otherwise mutate the active state on `main`.
