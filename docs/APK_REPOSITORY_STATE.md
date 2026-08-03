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

## Restore and rollback rehearsal

Rollback restores a previous immutable release snapshot into a local staging
tree. It is not a release rewrite: `apk-repo-v0001` and `apk-repo-v0002` remain
immutable, and the current checked-in state remains `apk-repo-v0002` until an
approved PR deliberately changes both state files.

The rehearsal downloads `apk-repo-v0001`, verifies its immutable release
metadata, archive digest, manifest, allowed archive members, and APK signatures
with the committed public key. It then combines that staged `apk/` tree with the
current Pages `catalog.json` and `catalog.schema.json`. It never invokes
`catalog.yaml`, `actions/deploy-pages`, `gh workflow run`, `git push`, or a
release mutation.

```sh
set -euo pipefail

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
archive="$work/verity-apk-repository.tar.zst"
pages="$work/pages"
digest=1d56b5710707b2aff9ee1e9cd0876466a6eb795fca5d0e58bb3f91c5c2922802

gh release view apk-repo-v0001 --repo tektum/verity-images \
  --json tagName,targetCommitish,isDraft,isPrerelease,isImmutable,assets > "$work/release.json"
jq -e --arg digest "sha256:$digest" '
  .tagName == "apk-repo-v0001" and
  .targetCommitish == "ed3f06217e1452683a974f52794331ab298219c2" and
  .isImmutable and (.isDraft | not) and (.isPrerelease | not) and
  (.assets | length == 1) and
  .assets[0].name == "verity-apk-repository.tar.zst" and
  .assets[0].digest == $digest
' "$work/release.json" >/dev/null
gh release download apk-repo-v0001 --repo tektum/verity-images \
  --pattern verity-apk-repository.tar.zst --dir "$work"
printf '%s  %s\n' "$digest" "$archive" | sha256sum --check --status

git show '4284b2880eec6fb03fcad18bd4f731d1f951f8ce^:packages/repository-state.json' > "$work/state.json"
tar --zstd -xOf "$archive" apk/manifest.json | jq -S . > "$work/manifest.json"
jq -S .archive.manifest "$work/state.json" > "$work/expected-manifest.json"
cmp "$work/manifest.json" "$work/expected-manifest.json"
mkdir "$pages"
PYTHONPATH=scripts python3 - "$archive" "$work/state.json" "$pages" <<'PY'
from pathlib import Path
import json
import sys

from apk_repository_policy import verify
from validate_repository_state import archive_paths, stage_archive, validate_archive_members

archive, state_path, pages = map(Path, sys.argv[1:])
state = json.loads(state_path.read_text(encoding="utf-8"))
assert validate_archive_members(state, archive) == archive_paths(state)
stage_archive(state, archive, pages)
for architecture in ("x86_64", "aarch64"):
    verify(pages / "apk" / architecture / "APKINDEX.tar.gz", Path("packages/keys"))
for package in state["packages"]:
    verify(pages / "apk" / package["path"], Path("packages/keys"))
PY
curl --fail --location --silent --show-error https://tektum.github.io/verity-images/catalog.json \
  -o "$pages/catalog.json"
cp docs/catalog.schema.json "$pages/catalog.schema.json"
scripts/devbox.sh run -- check-jsonschema --schemafile "$pages/catalog.schema.json" "$pages/catalog.json"
test "$(du -sb "$pages" | cut -f1)" -lt 943718400
```

Before a real rollback, an approver reviews the staged tree, confirms the
release and Pages checks, and explicitly approves a deployment from `main`.
After deployment, validate the published catalog, manifest, indexes, package
signatures, and release metadata. If validation fails, stop deployment and
restore the previously approved immutable snapshot through the same reviewed
procedure; do not overwrite a release or edit a deployed Pages tree in place.

## Retention and Pages size policy

Keep immutable release tags and their sole repository archive indefinitely;
they are the rollback source. Retain unsigned native build artifacts for seven
days, as configured by the release workflow. Retain catalog workflow artifacts
for seven days or the account minimum, whichever is longer; they aid diagnosis
but are not rollback sources. Pages deployment artifacts are transient delivery
inputs, not backups: recovery always starts from an immutable release plus the
current catalog and schema.

The complete Pages tree (`catalog.json`, `catalog.schema.json`, and `apk/`) must
remain below 900 MiB (943718400 bytes) before upload. Reject an oversized tree;
do not trim signed snapshot contents to make it fit.
