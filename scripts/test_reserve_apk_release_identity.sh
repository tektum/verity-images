#!/bin/bash
set -euo pipefail
trap 'printf "test failure at line %s\n" "$LINENO" >&2' ERR

root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
reserver="$root/.github/scripts/reserve-apk-release-identity.sh"
real_timeout=$(command -v timeout)
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM
source_sha=0123456789012345678901234567890123456789

make_package() {
  local path=$1 architecture=$2 payload=${3:-same} name=${4:-openssl-fips-provider}
  PYTHONPATH="$root/scripts" python3 - "$path" "$architecture" "$payload" "$name" <<'PY'
import sys
from pathlib import Path

from apk_test_fixtures import entry, signed_shape, unsigned_package

Path(sys.argv[1]).write_bytes(
    signed_shape(unsigned_package(sys.argv[2], (entry("payload", sys.argv[3].encode()),), name=sys.argv[4]))
)
PY
}

make_repository() {
  local destination=$1 payload=${2:-same} architecture package path digest
  mkdir -p "$destination/apk/x86_64" "$destination/apk/aarch64"
  for architecture in x86_64 aarch64; do
    path="$architecture/openssl-fips-provider-3.1.2-r3.apk"
    package="$destination/apk/$path"
    make_package "$package" "$architecture" "$payload"
    digest=$(/usr/bin/sha256sum "$package" | cut -d' ' -f1)
    jq -cn --arg architecture "$architecture" --arg path "$path" --arg sha256 "$digest" \
      '{architecture:$architecture,path:$path,sha256:$sha256}' >> "$destination/packages.jsonl"
  done
  jq -s '{architectures:["x86_64","aarch64"],fingerprint:("7" * 64),packages:sort_by(.architecture)}' \
    "$destination/packages.jsonl" > "$destination/apk/manifest.json"
  tar --zstd --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
    -C "$destination" -cf "$destination/repository.tar.zst" apk
}

make_base_state() {
  local repository=$1 state_dir=$2 manifest_sha package_entries
  mkdir -p "$state_dir"
  manifest_sha=$(/usr/bin/sha256sum "$repository/apk/manifest.json" | cut -d' ' -f1)
  package_entries=$(jq -c '[.packages[] | . + {name:"openssl-fips-provider",version:"3.1.2-r3",epoch:3}]' "$repository/apk/manifest.json")
  jq -n --arg target "$source_sha" --arg manifest_sha "$manifest_sha" --argjson packages "$package_entries" '
    {
      schemaVersion:1,
      repository:"tektum/verity-images",
      release:{id:363781736,tag:"apk-repo-v0002",targetCommit:$target,immutable:true},
      asset:{id:498881369,name:"verity-apk-repository.tar.zst",sha256:"sha256:7d6783ffae959a9761fc61cf10b7888a14813e2e24887ff8315fa52f8a68e79a"},
      archive:{
        root:"apk",
        sha256:"sha256:7d6783ffae959a9761fc61cf10b7888a14813e2e24887ff8315fa52f8a68e79a",
        manifestSha256:$manifest_sha,
        manifest:{architectures:["x86_64","aarch64"],fingerprint:("7" * 64),packages:($packages | map({architecture,path,sha256}))}
      },
      key:{path:"packages/keys/verity-apk-2026.rsa.pub",fingerprint:("7" * 64)},
      packages:$packages
    }
  ' > "$state_dir/repository-state.json"
  cp "$state_dir/repository-state.json" "$state_dir/repository-state.pin.json"
}

legacy_release() {
  local tag=$1 release_id=$2 asset_id=$3 digest=$4
  jq -cn --arg tag "$tag" --arg target "$source_sha" --argjson release_id "$release_id" --argjson asset_id "$asset_id" --arg digest "sha256:$digest" '
    {id:$release_id,tag_name:$tag,target_commitish:$target,draft:false,prerelease:false,immutable:true,body:"legacy",assets:[{id:$asset_id,name:"verity-apk-repository.tar.zst",state:"uploaded",digest:$digest}]}
  '
}

write_tools() {
  mkdir -p "$work_dir/bin"
  cat > "$work_dir/bin/sha256sum" <<'SH'
#!/bin/bash
case "$1" in
  */498710090.tar.zst) printf '1d56b5710707b2aff9ee1e9cd0876466a6eb795fca5d0e58bb3f91c5c2922802  %s\n' "$1" ;;
  */498881369.tar.zst) printf '7d6783ffae959a9761fc61cf10b7888a14813e2e24887ff8315fa52f8a68e79a  %s\n' "$1" ;;
  *) exec /usr/bin/sha256sum "$@" ;;
esac
SH
  cat > "$work_dir/bin/python3" <<'PY'
#!/bin/bash
printf 'python3 %s\n' "$*" >> "$COMMAND_LOG"
exit 0
PY
  cat > "$work_dir/bin/git" <<'GIT'
#!/bin/bash
printf 'git %s\n' "$*" >> "$COMMAND_LOG"
case "$1" in
  diff) [[ ${DIRTY_STATE:-0} -eq 0 ]] ;;
  rev-list) printf '%s\n' "$SOURCE_SHA" ;;
  ls-remote) exit 2 ;;
  *) exit 64 ;;
esac
GIT
  cat > "$work_dir/bin/gh" <<'GH'
#!/bin/bash
set -euo pipefail
printf 'gh %s\n' "$*" >> "$COMMAND_LOG"
value_after() {
  local wanted=$1 previous= argument
  shift
  for argument in "$@"; do
    if [[ "$previous" == "$wanted" ]]; then printf '%s' "$argument"; return; fi
    previous=$argument
  done
  return 1
}
if [[ ${GH_HANG:-0} -eq 1 ]]; then sleep 2; fi
case "$1:$2" in
  api:--paginate)
    [[ ${GH_BAD_JSON:-0} -eq 0 ]] || { printf 'misleading success output\n'; exit 0; }
    if [[ ${GH_DELAYED_VISIBILITY:-0} -eq 1 && -f "$GH_RELEASES.delay" ]]; then
      rm "$GH_RELEASES.delay"
      jq 'map(select(.tag_name != "apk-repo-v0003")) | [.[0:1],.[1:]]' "$GH_RELEASES"
    else
      jq '[.[0:1],.[1:]]' "$GH_RELEASES"
    fi
    ;;
  api:repos/*/git/ref/tags/*)
    if [[ ${GH_INTERRUPT:-0} -eq 1 ]]; then kill -TERM "${INTERRUPT_TARGET:?}"; fi
    [[ ${GH_TAG_MISSING:-0} -eq 0 ]] || exit 1
    if [[ ${GH_TAG_TYPE:-commit} == tag ]]; then
      jq -cn '{object:{type:"tag",sha:("a" * 40)}}'
    else
      jq -cn --arg sha "${GH_TAG_SHA:-$SOURCE_SHA}" '{object:{type:"commit",sha:$sha}}'
    fi
    ;;
  api:repos/*/git/tags/*)
    jq -cn --arg sha "${GH_TAG_SHA:-$SOURCE_SHA}" '{sha:("a" * 40),object:{type:"commit",sha:$sha}}'
    ;;
  api:repos/*/releases/assets/*)
    asset_id=${2##*/}
    cp "$GH_ARCHIVES/$asset_id.tar.zst" /dev/stdout
    ;;
  release:create)
    tag=$3
    notes=$(value_after --notes "$@")
    target=$(value_after --target "$@")
    jq --arg tag "$tag" --arg body "$notes" --arg target "$target" \
      '. + [{id:9000,tag_name:$tag,target_commitish:$target,draft:true,prerelease:false,immutable:false,body:$body,assets:[]}]' \
      "$GH_RELEASES" > "$GH_RELEASES.next"
    mv "$GH_RELEASES.next" "$GH_RELEASES"
    [[ ${GH_CREATE_LOSER:-0} -eq 0 ]] || exit 1
    [[ ${GH_DELAYED_VISIBILITY:-0} -eq 0 ]] || touch "$GH_RELEASES.delay"
    if [[ ${GH_RACE:-0} -eq 1 ]]; then
      jq --arg target "$target" '. + [{id:9001,tag_name:"apk-repo-v0004",target_commitish:$target,draft:true,prerelease:false,immutable:false,body:"competing",assets:[]}]' \
        "$GH_RELEASES" > "$GH_RELEASES.next"
      mv "$GH_RELEASES.next" "$GH_RELEASES"
    fi
    ;;
  release:edit)
    tag=$3
    if notes=$(value_after --notes "$@" 2>/dev/null); then
      jq --arg tag "$tag" --arg body "$notes" 'map(if .tag_name == $tag then .body=$body else . end)' "$GH_RELEASES" > "$GH_RELEASES.next"
    elif [[ " $* " == *' --draft=false '* ]]; then
      jq --arg tag "$tag" 'map(if .tag_name == $tag then .draft=false | .immutable=true else . end)' "$GH_RELEASES" > "$GH_RELEASES.next"
    else
      exit 64
    fi
    mv "$GH_RELEASES.next" "$GH_RELEASES"
    ;;
  release:delete)
    tag=$3
    jq --arg tag "$tag" 'map(select(.tag_name != $tag))' "$GH_RELEASES" > "$GH_RELEASES.next"
    mv "$GH_RELEASES.next" "$GH_RELEASES"
    ;;
  *) exit 64 ;;
esac
GH
  cat > "$work_dir/bin/timeout" <<'TIMEOUT'
#!/bin/bash
set -euo pipefail
duration=$1
shift
if [[ ${GH_INTERRUPT:-0} -eq 1 ]]; then
  trap '' TERM
  target=$PPID
  if [[ " $* " == *'/git/ref/tags/'* ]]; then
    target=$(ps -o ppid= -p "$PPID" | tr -d ' ')
  fi
  INTERRUPT_TARGET=$target "$@"
else
  exec "$REAL_TIMEOUT" "$duration" "$@"
fi
TIMEOUT
  chmod +x "$work_dir/bin/sha256sum" "$work_dir/bin/python3" "$work_dir/bin/git" "$work_dir/bin/gh" "$work_dir/bin/timeout"
}

reset_releases() {
  jq -s '.' \
    <(legacy_release apk-repo-v0001 363733856 498710090 1d56b5710707b2aff9ee1e9cd0876466a6eb795fca5d0e58bb3f91c5c2922802) \
    <(legacy_release apk-repo-v0002 363781736 498881369 7d6783ffae959a9761fc61cf10b7888a14813e2e24887ff8315fa52f8a68e79a) \
    > "$work_dir/releases.json"
  : > "$work_dir/commands.log"
}

write_inputs() {
  local output=$1 mode=$2 repository=$3 origin=${4:-}
  if [[ "$mode" == migration ]]; then
    jq -n --arg x "$repository/apk/x86_64/openssl-fips-provider-3.1.2-r3.apk" \
      --arg a "$repository/apk/aarch64/openssl-fips-provider-3.1.2-r3.apk" '
      {mode:"migration",packages:[
        {architecture:"x86_64",path:"x86_64/openssl-fips-provider-3.1.2-r3.apk",file:$x},
        {architecture:"aarch64",path:"aarch64/openssl-fips-provider-3.1.2-r3.apk",file:$a}
      ]}
    ' > "$output"
  else
    jq -n --arg x "$repository/apk/x86_64/openssl-fips-provider-3.1.2-r3.apk" \
      --arg a "$repository/apk/aarch64/openssl-fips-provider-3.1.2-r3.apk" --argjson origin "$origin" '
      {mode:"replacement",identity:{name:"openssl-fips-provider",version:"3.1.2-r3",epoch:3},packages:[
        {architecture:"x86_64",path:"x86_64/openssl-fips-provider-3.1.2-r3.apk",file:$x,origin:($origin + {bundlePath:"bundles/openssl-fips-provider/x86_64.json"})},
        {architecture:"aarch64",path:"aarch64/openssl-fips-provider-3.1.2-r3.apk",file:$a,origin:($origin + {bundlePath:"bundles/openssl-fips-provider/aarch64.json"})}
      ]}
    ' > "$output"
  fi
}

run_script() {
  COMMAND_LOG="$work_dir/commands.log" GH_ARCHIVES="$work_dir/assets" GH_RELEASES="$work_dir/releases.json" \
    SOURCE_SHA="$source_sha" REAL_TIMEOUT="$real_timeout" PATH="$work_dir/bin:$PATH" GH_TIMEOUT_SECONDS="${GH_TIMEOUT_SECONDS:-1}" \
    DIRTY_STATE="${DIRTY_STATE:-0}" GH_BAD_JSON="${GH_BAD_JSON:-0}" GH_HANG="${GH_HANG:-0}" \
    GH_RACE="${GH_RACE:-0}" GH_INTERRUPT="${GH_INTERRUPT:-0}" GH_CREATE_LOSER="${GH_CREATE_LOSER:-0}" \
    GH_DELAYED_VISIBILITY="${GH_DELAYED_VISIBILITY:-0}" \
    GH_VISIBILITY_RETRY_SECONDS=0 \
    GH_TAG_MISSING="${GH_TAG_MISSING:-0}" GH_TAG_SHA="${GH_TAG_SHA:-$source_sha}" GH_TAG_TYPE="${GH_TAG_TYPE:-commit}" \
    "$reserver" "$@"
}

reserve() {
  run_script reserve tektum/verity-images "$1" "$source_sha" "$work_dir/state/repository-state.json" "$2"
}

expect_failure() {
  local before
  before=$(grep -c '^gh release create\|^gh release edit .*--draft=false\|^gh release upload' "$work_dir/commands.log" || true)
  set +e
  "$@" >/dev/null 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  [[ $(grep -c '^gh release create\|^gh release edit .*--draft=false\|^gh release upload' "$work_dir/commands.log" || true) -eq $before ]]
  ! grep -Eq 'APK_REPOSITORY_PRIVATE_KEY|prepare-apk-signing-key|release upload' "$work_dir/commands.log"
}

expect_failure_after_create() {
  set +e
  "$@" >/dev/null 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  ! grep -Eq 'APK_REPOSITORY_PRIVATE_KEY|prepare-apk-signing-key|release upload|release edit .*--draft=false' "$work_dir/commands.log"
}

set_release_state() {
  local tag=$1 archive=$2 draft=${3:-false} digest
  digest="sha256:$(/usr/bin/sha256sum "$archive" | cut -d' ' -f1)"
  jq --arg tag "$tag" --arg digest "$digest" --argjson draft "$draft" '
    map(if .tag_name == $tag then
      .draft=$draft | .prerelease=false | .immutable=($draft | not) |
      .published_at=(if $draft then null else "2026-08-05T00:00:00Z" end) |
      .assets=[{id:9100,name:"verity-apk-repository.tar.zst",state:"uploaded",digest:$digest}]
    else . end)
  ' "$work_dir/releases.json" > "$work_dir/releases.next"
  mv "$work_dir/releases.next" "$work_dir/releases.json"
}

mkdir -p "$work_dir/assets"
make_repository "$work_dir/legacy"
cp "$work_dir/legacy/repository.tar.zst" "$work_dir/assets/498710090.tar.zst"
cp "$work_dir/legacy/repository.tar.zst" "$work_dir/assets/498881369.tar.zst"
make_base_state "$work_dir/legacy" "$work_dir/state"
write_tools
write_inputs "$work_dir/migration.json" migration "$work_dir/legacy"

# Given a final manifest containing replacement and reused packages, when completion runs, then final origins are preserved while unsigned inputs remain separately bound.
reset_releases
mkdir -p "$work_dir/mixed-input/x86_64" "$work_dir/mixed-input/aarch64" "$work_dir/mixed-final/apk/x86_64" "$work_dir/mixed-final/apk/aarch64"
for architecture in x86_64 aarch64; do
  cp "$work_dir/legacy/apk/$architecture/openssl-fips-provider-3.1.2-r3.apk" "$work_dir/mixed-final/apk/$architecture/"
  replacement="$work_dir/mixed-input/$architecture/new-package-3.1.2-r3.apk"
  make_package "$replacement" "$architecture" replacement new-package
  cp "$replacement" "$work_dir/mixed-final/apk/$architecture/"
done
jq -n --arg source "$source_sha" \
  --arg x "$work_dir/mixed-input/x86_64/new-package-3.1.2-r3.apk" \
  --arg a "$work_dir/mixed-input/aarch64/new-package-3.1.2-r3.apk" \
  --arg xsha "$(/usr/bin/sha256sum "$work_dir/mixed-input/x86_64/new-package-3.1.2-r3.apk" | cut -d' ' -f1)" \
  --arg asha "$(/usr/bin/sha256sum "$work_dir/mixed-input/aarch64/new-package-3.1.2-r3.apk" | cut -d' ' -f1)" '
  def origin($id;$sha): {type:"build-input",sourceCommit:$source,workflowRef:"workflow@ref",runId:20,
    artifactId:$id,artifactSha256:("sha256:"+$sha),unsignedSha256:$sha};
  {mode:"replacement",identity:{name:"new-package",version:"3.1.2-r3",epoch:3},packages:[
    {architecture:"x86_64",path:"x86_64/new-package-3.1.2-r3.apk",file:$x,origin:origin(21;$xsha)},
    {architecture:"aarch64",path:"aarch64/new-package-3.1.2-r3.apk",file:$a,origin:origin(22;$asha)}]}
' > "$work_dir/mixed-inputs.json"
reserve apk-repo-v0003 "$work_dir/mixed-inputs.json" > "$work_dir/mixed-reservation.json"
jq -nS --slurpfile base "$work_dir/legacy/apk/manifest.json" --slurpfile state "$work_dir/state/repository-state.json" \
  --slurpfile reservation "$work_dir/mixed-reservation.json" '
  def legacy($package): $package + {name:"openssl-fips-provider",version:"3.1.2-r3",epoch:3,origin:{
    type:"legacy-snapshot",releaseId:$state[0].release.id,releaseTag:$state[0].release.tag,
    targetCommit:$state[0].release.targetCommit,assetId:$state[0].asset.id,assetSha256:$state[0].asset.sha256,
    manifestSha256:$state[0].archive.manifestSha256,sourcePath:$package.path}};
  def replacement($package):
    ($reservation[0].unsignedPackages[] | select(.architecture == $package.architecture)) as $unsigned |
    $package + {name:"new-package",version:"3.1.2-r3",epoch:3,origin:{
      type:"attested-build",sourceCommit:$unsigned.origin.sourceCommit,buildWorkflowId:30,
      buildRunId:$unsigned.origin.runId,buildArtifactId:$unsigned.origin.artifactId,
      buildArtifactSha256:$unsigned.origin.artifactSha256,unsignedSha256:$unsigned.sha256,
      signingWorkflowId:30,signingRunId:31,bundlePath:("bundles/new-package/"+$package.architecture+".json"),
      bundleSha256:("b" * 64)}};
  (([$base[0].packages[] | legacy(.)]) +
  (["aarch64","x86_64"] | map(. as $architecture | replacement({architecture:$architecture,
    path:($architecture+"/new-package-3.1.2-r3.apk"),
    sha256:($reservation[0].unsignedPackages[] | select(.architecture == $architecture) | .sha256)})))) as $packages |
  {schemaVersion:2,architectures:["aarch64","x86_64"],fingerprint:("7" * 64),packages:($packages | sort_by(.name,.version,.epoch,.architecture,.path))}
' > "$work_dir/mixed-final/apk/manifest.json"
tar --zstd --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner -C "$work_dir/mixed-final" \
  -cf "$work_dir/mixed-final/repository.tar.zst" apk
run_script complete tektum/verity-images apk-repo-v0003 "$source_sha" "$work_dir/mixed-reservation.json" \
  "$work_dir/mixed-final/repository.tar.zst" > "$work_dir/mixed-complete.json"
jq -e '
  (.unsignedPackages | length) == 2 and all(.unsignedPackages[]; .origin.type == "build-input") and
  (.packages | length) == 4 and
  all(.packages[] | select(.name == "new-package"); .origin.type == "attested-build") and
  all(.packages[] | select(.name == "openssl-fips-provider"); .origin.type == "legacy-snapshot")
' "$work_dir/mixed-complete.json" >/dev/null

# Given immutable v0001/v0002, when exact v0002 bytes are reserved and completed, then markers round-trip canonically.
reset_releases
reserve apk-repo-v0003 "$work_dir/migration.json" > "$work_dir/reservation.json"
jq -e '.schemaVersion == 2 and .status == "reserved" and .operation.mode == "migration" and (.base.stateSha256 | test("^[0-9a-f]{64}$"))' \
  "$work_dir/reservation.json" >/dev/null
run_script complete tektum/verity-images apk-repo-v0003 "$source_sha" "$work_dir/reservation.json" \
  "$work_dir/legacy/repository.tar.zst" > "$work_dir/complete.json"
jq -e '.schemaVersion == 2 and .status == "complete" and (.packages == (.packages | sort_by(.name,.version,.epoch,.architecture,.path)))' \
  "$work_dir/complete.json" >/dev/null
jq -e '.[2].body | contains("apk-release-complete") and (contains("apk-release-reserved") | not)' "$work_dir/releases.json" >/dev/null
[[ $(grep -c 'python3 .*apk_repository_policy.py' "$work_dir/commands.log") -ge 4 ]]

# Given an existing complete marker with equivalent but noncanonical JSON, when a later release is reserved, then it fails before creation.
complete_marker=$(jq -r '.[2].body' "$work_dir/releases.json" | sed -n 's/^<!-- apk-release-complete: \(.*\) -->$/\1/p')
noncanonical_marker=${complete_marker//,/, }
[[ "$complete_marker" != "$noncanonical_marker" ]]
jq --arg marker "$noncanonical_marker" '
  .[2].body |= (
    split("\n") |
    map(if startswith("<!-- apk-release-complete: ") then "<!-- apk-release-complete: \($marker) -->" else . end) |
    join("\n")
  )
' "$work_dir/releases.json" > "$work_dir/releases.next"
mv "$work_dir/releases.next" "$work_dir/releases.json"
expect_failure reserve apk-repo-v0004 "$work_dir/migration.json"

# Given a complete v0003 ledger, when v0004 reuses exact bytes, paths, and origins, then reservation succeeds.
reset_releases
reserve apk-repo-v0003 "$work_dir/migration.json" > "$work_dir/reservation.json"
run_script complete tektum/verity-images apk-repo-v0003 "$source_sha" "$work_dir/reservation.json" \
  "$work_dir/legacy/repository.tar.zst" > /dev/null
set_release_state apk-repo-v0003 "$work_dir/legacy/repository.tar.zst"
reserve apk-repo-v0004 "$work_dir/migration.json" > /dev/null

# Given a repeated identity, when bytes or paths change, then reservation fails before creation.
reset_releases
make_repository "$work_dir/collision" changed
write_inputs "$work_dir/collision.json" migration "$work_dir/collision"
expect_failure reserve apk-repo-v0003 "$work_dir/collision.json"
origin=$(jq -cn --arg source "$source_sha" '{type:"attested-build",sourceCommit:$source,buildWorkflowId:1,buildRunId:2,buildArtifactId:3,buildArtifactSha256:("sha256:"+("4"*64)),unsignedSha256:("5"*64),signingWorkflowId:6,signingRunId:7,bundleSha256:("8"*64)}')
write_inputs "$work_dir/path-collision.base.json" replacement "$work_dir/legacy" "$origin"
jq '.packages[0].path="x86_64/renamed.apk"' "$work_dir/path-collision.base.json" > "$work_dir/path-collision.json"
expect_failure reserve apk-repo-v0003 "$work_dir/path-collision.json"

# Given a future complete marker, when origins change, then its authoritative ledger blocks reservation.
reset_releases
reserve apk-repo-v0003 "$work_dir/migration.json" > "$work_dir/reservation.json"
run_script complete tektum/verity-images apk-repo-v0003 "$source_sha" "$work_dir/reservation.json" \
  "$work_dir/legacy/repository.tar.zst" > /dev/null
set_release_state apk-repo-v0003 "$work_dir/legacy/repository.tar.zst"
write_inputs "$work_dir/replacement.json" replacement "$work_dir/legacy" "$origin"
expect_failure reserve apk-repo-v0004 "$work_dir/replacement.json"

# Given a complete marker, when its release postcondition is incomplete or unpublished, then it is not authoritative.
reset_releases
reserve apk-repo-v0003 "$work_dir/migration.json" > "$work_dir/reservation.json"
run_script complete tektum/verity-images apk-repo-v0003 "$source_sha" "$work_dir/reservation.json" \
  "$work_dir/legacy/repository.tar.zst" >/dev/null
set_release_state apk-repo-v0003 "$work_dir/legacy/repository.tar.zst"
cp "$work_dir/releases.json" "$work_dir/published-complete.json"
for mutation in \
  '.[2].draft=true | .[2].immutable=false' \
  '.[2].published_at=null' \
  '.[2].prerelease=true' \
  '.[2].immutable=false' \
  '.[2].assets=[]' \
  '.[2].assets += [.[2].assets[0]]' \
  '.[2].assets[0].name="other.tar.zst"' \
  '.[2].assets[0].state="new"' \
  '.[2].assets[0].digest="sha256:"+("0"*64)'; do
  jq "$mutation" "$work_dir/published-complete.json" > "$work_dir/releases.json"
  expect_failure reserve apk-repo-v0004 "$work_dir/migration.json"
done

# Given untrusted release notes, when markers are malformed, duplicated, or incomplete, then scanning fails closed.
for body in \
  '<!-- apk-release-complete: bad -->' \
  '<!-- apk-release-reserved: {} -->' \
  $'<!-- apk-release-complete: {} -->\n<!-- apk-release-complete: {} -->'; do
  reset_releases
  jq --arg body "$body" '.[1].body=$body' "$work_dir/releases.json" > "$work_dir/releases.next"
  mv "$work_dir/releases.next" "$work_dir/releases.json"
  expect_failure reserve apk-repo-v0003 "$work_dir/migration.json"
done
reset_releases
jq '.[1].body="untrusted $(touch SHOULD_NOT_EXIST)"' "$work_dir/releases.json" > "$work_dir/releases.next"
mv "$work_dir/releases.next" "$work_dir/releases.json"
reserve apk-repo-v0003 "$work_dir/migration.json" >/dev/null
[[ ! -e SHOULD_NOT_EXIST ]]
reset_releases
jq '.[1].body="<!-- apk-release-reserved: {} -->" | .[1].draft=false' "$work_dir/releases.json" > "$work_dir/releases.next"
mv "$work_dir/releases.next" "$work_dir/releases.json"
expect_failure reserve apk-repo-v0003 "$work_dir/migration.json"

# Given a legacy seed, when API metadata, immutability, digest, or asset cardinality changes, then verification fails.
for mutation in \
  '.[0].immutable=false' \
  '.[0].draft=true' \
  '.[0].assets=[]' \
  '.[0].assets[0].digest="sha256:"+("0"*64)' \
  '.[0].assets[0].name="other.tar.zst"'; do
  reset_releases
  jq "$mutation" "$work_dir/releases.json" > "$work_dir/releases.next"
  mv "$work_dir/releases.next" "$work_dir/releases.json"
  expect_failure reserve apk-repo-v0003 "$work_dir/migration.json"
done

# Given stale or untrusted local and API state, when reservation starts, then it fails closed within the call bound.
reset_releases
printf '\n' >> "$work_dir/state/repository-state.json"
expect_failure reserve apk-repo-v0003 "$work_dir/migration.json"
cp "$work_dir/state/repository-state.pin.json" "$work_dir/state/repository-state.json"
expect_failure reserve apk-repo-v0004 "$work_dir/migration.json"
DIRTY_STATE=1 expect_failure reserve apk-repo-v0003 "$work_dir/migration.json"
DIRTY_STATE=0 GH_BAD_JSON=1 expect_failure reserve apk-repo-v0003 "$work_dir/migration.json"
GH_BAD_JSON=0 GH_HANG=1 GH_TIMEOUT_SECONDS=0.1 expect_failure reserve apk-repo-v0003 "$work_dir/migration.json"

# Given an empty owned draft, when a creator races or execution is interrupted, then only that safe draft is removed.
reset_releases
GH_RACE=1 expect_failure_after_create reserve apk-repo-v0003 "$work_dir/migration.json"
grep -Fq 'gh release delete apk-repo-v0003' "$work_dir/commands.log"

# Given a successful create whose list endpoint is briefly stale, when reservation rescans, then it waits for the owned draft.
reset_releases
GH_DELAYED_VISIBILITY=1 reserve apk-repo-v0003 "$work_dir/migration.json" > "$work_dir/delayed-reservation.json"
jq -e '.status == "reserved" and .release.tag == "apk-repo-v0003"' "$work_dir/delayed-reservation.json" >/dev/null

# Given another invocation wins identical draft creation, when this invocation loses, then it never owns or deletes the winner.
reset_releases
GH_CREATE_LOSER=1 expect_failure_after_create reserve apk-repo-v0003 "$work_dir/migration.json"
grep -Fq 'gh release delete apk-repo-v0003' "$work_dir/commands.log" && exit 1
jq -e '.[] | select(.tag_name == "apk-repo-v0003" and .draft == true)' "$work_dir/releases.json" >/dev/null

# Given lightweight or annotated live tags, when they resolve to the expected commit, then reservation accepts both forms.
reset_releases
GH_TAG_TYPE=commit reserve apk-repo-v0003 "$work_dir/migration.json" >/dev/null
grep -Fq 'gh api repos/tektum/verity-images/git/ref/tags/apk-repo-v0003' "$work_dir/commands.log"
reset_releases
GH_TAG_TYPE=tag reserve apk-repo-v0003 "$work_dir/migration.json" >/dev/null
grep -Fq 'gh api repos/tektum/verity-images/git/tags/' "$work_dir/commands.log"

# Given a moved or missing live tag, when reservation checks ownership, then it fails before protected work.
reset_releases
GH_TAG_SHA=1111111111111111111111111111111111111111 expect_failure_after_create reserve apk-repo-v0003 "$work_dir/migration.json"
reset_releases
GH_TAG_MISSING=1 expect_failure_after_create reserve apk-repo-v0003 "$work_dir/migration.json"
jq -e '.[] | select(.tag_name == "apk-repo-v0003")' "$work_dir/releases.json" >/dev/null && exit 1
reset_releases
if GH_INTERRUPT=1 reserve apk-repo-v0003 "$work_dir/migration.json" >/dev/null 2>&1; then
  status=0
else
  status=$?
fi
[[ $status -eq 130 ]]
grep -Fq 'gh release delete apk-repo-v0003' "$work_dir/commands.log"

# Given a reserved draft, when publication is requested, then the incomplete marker prevents publication.
reset_releases
reserve apk-repo-v0003 "$work_dir/migration.json" > /dev/null
expect_failure run_script publish tektum/verity-images apk-repo-v0003

# Given a complete draft with its fixed asset, when the live tag moved immediately before publication, then publication fails closed.
reset_releases
reserve apk-repo-v0003 "$work_dir/migration.json" > "$work_dir/reservation.json"
run_script complete tektum/verity-images apk-repo-v0003 "$source_sha" "$work_dir/reservation.json" \
  "$work_dir/legacy/repository.tar.zst" >/dev/null
set_release_state apk-repo-v0003 "$work_dir/legacy/repository.tar.zst" true
GH_TAG_SHA=1111111111111111111111111111111111111111 expect_failure run_script publish tektum/verity-images apk-repo-v0003

grep -Fq 'gh api --paginate --slurp repos/tektum/verity-images/releases?per_page=100' "$work_dir/commands.log"
