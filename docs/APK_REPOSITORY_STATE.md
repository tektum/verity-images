# APK repository state

[`packages/repository-state.json`](../packages/repository-state.json) and
[`packages/repository-state.pin.json`](../packages/repository-state.pin.json)
are the reviewed pin contract for the published APK repository release. They
identify one immutable release asset, the archive root and manifest, the active
public key, and the package metadata for both supported architectures. A
release update must deliberately update both files in the same reviewed PR.

Validate the checked-in state with:

```sh
scripts/devbox.sh run -- check-jsonschema \
  --schemafile packages/repository-state.schema.json \
  packages/repository-state.json packages/repository-state.pin.json
python3 scripts/validate_repository_state.py
```

For a release update, run `python3 scripts/validate_repository_state.py --live`,
download the candidate asset without modifying the release, and run the same
command with `--archive PATH` to bind the independently computed archive and
manifest digests.

Renovate may open a PR when a newer `apk-repo-vNNNN` release appears. It is
globally configured to create PRs without Renovate or platform automerge. A
reviewer must complete every immutable field in both pin files, run the
validation commands, and merge the PR. No updater may push, merge, or otherwise
mutate repository state on `main`.

## Restore and rollback rehearsal

Rollback restores a previous immutable release snapshot into a local staging
tree. It is not a release rewrite: historical releases remain immutable, and
the active checked-in release remains the one named by both state files until
an approved PR deliberately updates them together.

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
: "${EVIDENCE_DIR:?set an approved external evidence directory}"
evidence_root=$(realpath "$EVIDENCE_DIR")
case "$evidence_root" in "$work"|"$work"/*) exit 1 ;; esac
evidence="$evidence_root/apk-repo-v0001"
test ! -e "$evidence"
pending=$(mktemp -d "$evidence_root/.apk-repo-v0001.XXXXXX")
state_commit=35ce4080d7385b1fa4e78a9c0f281a9fa0440899
source_commit=ed3f06217e1452683a974f52794331ab298219c2
test "$(git rev-parse apk-repo-v0001^{commit})" = "$source_commit"

gh api repos/tektum/verity-images/releases/363733856 > "$work/release.json"
gh release download apk-repo-v0001 --repo tektum/verity-images \
  --pattern verity-apk-repository.tar.zst --dir "$work"

git show "$state_commit:packages/repository-state.json" > "$work/state.json"
git show "$state_commit:packages/repository-state.pin.json" > "$work/state.pin.json"
git show "$state_commit:packages/repository-state.schema.json" > "$work/state.schema.json"
scripts/devbox.sh run -- check-jsonschema --schemafile "$work/state.schema.json" "$work/state.json" "$work/state.pin.json"
cmp "$work/state.json" "$work/state.pin.json"
tar --zstd -xOf "$archive" apk/manifest.json | jq -S . > "$work/manifest.json"
jq -S .archive.manifest "$work/state.json" > "$work/expected-manifest.json"
cmp "$work/manifest.json" "$work/expected-manifest.json"
mkdir "$pages"
PYTHONPATH=scripts python3 - "$archive" "$work/state.json" "$work/release.json" "$pages" \
  "$source_commit" <<'PY'
import hashlib
import json
import subprocess
import sys
from pathlib import Path

from apk_repository_policy import verify
from validate_repository_state import archive_paths, stage_archive, validate_archive_members

archive, state_path, release_path, pages = map(Path, sys.argv[1:5])
source_commit = sys.argv[5]
state = json.loads(state_path.read_text(encoding="utf-8"))
release = json.loads(release_path.read_text(encoding="utf-8"))
if state["release"]["targetCommit"] != source_commit:
    raise SystemExit("recovery check failed: source commit")
if release["id"] != state["release"]["id"]:
    raise SystemExit("recovery check failed: release id")
if release["tag_name"] != state["release"]["tag"]:
    raise SystemExit("recovery check failed: release tag")
if release["target_commitish"] != state["release"]["targetCommit"]:
    raise SystemExit("recovery check failed: release source commit")
if not release["immutable"] or release["draft"] or release["prerelease"]:
    raise SystemExit("recovery check failed: release is not immutable and published")
assets = release["assets"]
if len(assets) != 1:
    raise SystemExit("recovery check failed: release asset count")
asset = assets[0]
if asset["id"] != state["asset"]["id"]:
    raise SystemExit("recovery check failed: release asset id")
if asset["name"] != state["asset"]["name"]:
    raise SystemExit("recovery check failed: release asset name")
if asset["digest"] != state["asset"]["sha256"]:
    raise SystemExit("recovery check failed: release asset digest")
if validate_archive_members(state, archive) != archive_paths(state):
    raise SystemExit("recovery check failed: archive members")
with archive.open("rb") as source:
    archive_digest = f"sha256:{hashlib.file_digest(source, 'sha256').hexdigest()}"
if archive_digest != state["asset"]["sha256"]:
    raise SystemExit("recovery check failed: downloaded archive digest")
stage_archive(state, archive, pages)
keys = pages.parent / "keys"
keys.mkdir()
key_path = Path(state["key"]["path"])
(keys / key_path.name).write_bytes(
    subprocess.check_output(["git", "show", f"{source_commit}:{key_path.as_posix()}"])
)
for architecture in ("x86_64", "aarch64"):
    verify(pages / "apk" / architecture / "APKINDEX.tar.gz", keys)
for package in state["packages"]:
    verify(pages / "apk" / package["path"], keys)
PY
curl --fail --location --silent --show-error https://tektum.github.io/verity-images/catalog.json \
  -o "$pages/catalog.json"
cp docs/catalog.schema.json "$pages/catalog.schema.json"
scripts/devbox.sh run -- check-jsonschema --schemafile "$pages/catalog.schema.json" "$pages/catalog.json"
pages_bytes=$(du -sb "$pages" | cut -f1)
test "$pages_bytes" -lt 943718400
mkdir -p "$pending/pages/apk"
cp "$work/release.json" "$pending/release.json"
cp "$work/state.json" "$pending/repository-state.json"
cp "$work/state.pin.json" "$pending/repository-state.pin.json"
cp "$work/state.schema.json" "$pending/repository-state.schema.json"
printf '%s\n' "$source_commit" > "$pending/source-commit.txt"
printf '%s\n' "$pages_bytes" > "$pending/pages-size-bytes.txt"
cp "$pages/catalog.json" "$pending/pages/catalog.json"
cp "$pages/catalog.schema.json" "$pending/pages/catalog.schema.json"
cp "$pages/apk/manifest.json" "$pending/pages/apk/manifest.json"
find "$pages" -type f -printf '%P\n' | LC_ALL=C sort > "$pending/pages-files.txt"
printf 'passed\n' > "$pending/result.txt"
(
  cd "$pending"
  find . -type f ! -name SHA256SUMS -printf '%P\n' | LC_ALL=C sort | xargs -r sha256sum > SHA256SUMS
)
mv "$pending" "$evidence"
```

Only the completed `$EVIDENCE_DIR/apk-repo-v0001` directory is approval evidence;
the trap then removes the staging tree.
Its sorted `SHA256SUMS` manifest uses only relative paths and binds the release,
reviewed state contract, source commit, staged tree size, Pages inputs, and
successful result to the rehearsal.

Before a real rollback, an approver reviews the staged tree, confirms the
release and Pages checks, and explicitly approves a deployment from `main`.
After deployment, validate the published catalog, manifest, indexes, package
signatures, and release metadata. If validation fails, stop deployment and
restore the previously approved immutable snapshot through the same reviewed
procedure; do not overwrite a release or edit a deployed Pages tree in place.

## Retention and Pages size policy

Release tags and repository archives remain rollback sources until deliberately
removed under the release-retention policy; do not claim indefinite retention.
GitHub Actions artifacts use the repository default retention of 90 days unless
the workflow sets a shorter value, and no workflow can exceed the account's
configured maximum retention. Pages deployment artifacts expire after one day.
They are transient delivery inputs, not backups: recovery always starts from an
immutable release plus the current catalog and schema.

The complete Pages tree (`catalog.json`, `catalog.schema.json`, and `apk/`) must
remain below 900 MiB (943718400 bytes) before upload. Reject an oversized tree;
do not trim signed snapshot contents to make it fit.
