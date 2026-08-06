#!/bin/bash
set -euo pipefail
shopt -s inherit_errexit

root=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
work_dir=$(mktemp -d)
created=0
reservation_body=
repository=
release_tag=

error() {
  printf '::error title=APK release identity::%s\n' "$1" >&2
  return 1
}

gh_call() {
  timeout "${GH_TIMEOUT_SECONDS:-30}" gh "$@"
}

resolve_live_tag() {
  local ref type sha tag
  ref=$(gh_call api "repos/${repository}/git/ref/tags/${release_tag}") || error "Live tag $release_tag is missing."
  type=$(jq -er '.object.type' <<<"$ref")
  sha=$(jq -er '.object.sha | select(test("^[0-9a-f]{40}$"))' <<<"$ref")
  if [[ "$type" == tag ]]; then
    tag=$(gh_call api "repos/${repository}/git/tags/${sha}") || error "Annotated tag $release_tag cannot be resolved."
    jq -e --arg sha "$sha" '.sha == $sha and .object.type == "commit" and (.object.sha | test("^[0-9a-f]{40}$"))' \
      <<<"$tag" >/dev/null || error "Annotated tag $release_tag does not resolve to a commit."
    jq -er '.object.sha' <<<"$tag"
  else
    [[ "$type" == commit ]] || error "Tag $release_tag does not resolve to a commit."
    printf '%s\n' "$sha"
  fi
}

verify_live_tag() {
  local expected=$1 actual
  actual=$(resolve_live_tag)
  [[ "$actual" == "$expected" ]] || error "Tag $release_tag moved from expected commit $expected."
}

verify_tag_absent() {
  local refs
  refs=$(gh_call api "repos/${repository}/git/matching-refs/tags/${release_tag}") || error "Tag $release_tag could not be checked."
  jq -e 'type == "array" and length == 0' <<<"$refs" >/dev/null || error "Tag $release_tag already exists."
}

ensure_live_tag() {
  local expected=$1
  gh_call api --method POST "repos/${repository}/git/refs" \
    -f "ref=refs/tags/${release_tag}" -f "sha=${expected}" >/dev/null 2>&1 || true
  verify_live_tag "$expected"
}

release_pages() {
  gh_call api --paginate --slurp "repos/${repository}/releases?per_page=100"
}

flat_releases() {
  jq -ce '[.[] | if type == "array" then .[] else . end]'
}

safe_cleanup() {
  [[ $created -eq 1 ]] || return 0
  local releases release
  releases=$(release_pages 2>/dev/null | flat_releases 2>/dev/null) || return 0
  release=$(jq -ce --arg tag "$release_tag" --arg body "$reservation_body" '
    [.[] | select(.tag_name == $tag)] as $matches |
    if ($matches | length) == 1 and
      $matches[0].draft == true and
      ($matches[0].assets | type == "array" and length == 0) and
      (($matches[0].body // "") | gsub("\\r"; "")) == $body
    then $matches[0] else empty end
  ' <<<"$releases" 2>/dev/null) || return 0
  [[ -n "$release" ]] || return 0
  gh_call release delete "$release_tag" --repo "$repository" --yes >/dev/null 2>&1 || true
}

cleanup() {
  status=$?
  trap - EXIT
  if [[ $status -ne 0 ]]; then
    safe_cleanup
  fi
  rm -rf "$work_dir"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

sha256() {
  sha256sum "$1" | awk '{print $1}'
}

package_identity() {
  local package=$1 metadata recipe name version epoch
  metadata=$(tar -xOf "$package" .PKGINFO)
  recipe=$(tar -xOf "$package" .melange.yaml)
  name=$(awk -F ' = ' '$1 == "pkgname" { print $2; exit }' <<<"$metadata")
  version=$(awk -F ' = ' '$1 == "pkgver" { print $2; exit }' <<<"$metadata")
  epoch=$(awk '/^  epoch: / { print $2; exit }' <<<"$recipe")
  [[ "$name" =~ ^[a-z0-9][a-z0-9+._-]*$ ]]
  [[ "$version" =~ ^[0-9][A-Za-z0-9+._-]*$ ]]
  [[ "$epoch" =~ ^[0-9]+$ ]]
  jq -cn --arg name "$name" --arg version "$version" --argjson epoch "$epoch" \
    '{name:$name,version:$version,epoch:$epoch}'
}

safe_archive_members() {
  local archive=$1 output=$2 line type member
  tar --zstd --quoting-style=literal -tf "$archive" > "$output"
  [[ -s "$output" ]]
  while IFS= read -r member; do
    [[ "$member" == apk || "$member" == apk/ || "$member" == apk/* ]]
    [[ "$member" != *[[:space:]]* && "$member" != /* && "$member" != *'/../'* && "$member" != ../* && "$member" != *'/..' ]]
  done < "$output"
  [[ -z "$(sort "$output" | uniq -d)" ]]
  tar --zstd --quoting-style=literal -tvf "$archive" > "$output.details"
  [[ $(wc -l < "$output") -eq $(wc -l < "$output.details") ]]
  while IFS= read -r line; do
    type=${line:0:1}
    member=${line##* }
    [[ "$type" == - || "$type" == d ]]
    grep -Fxq "$member" "$output" || grep -Fxq "$member/" "$output"
  done < "$output.details"
}

normalize_marker() {
  jq -ceS '
    def hex($n): type == "string" and test("^[0-9a-f]{" + ($n | tostring) + "}$");
    def digest: type == "string" and test("^sha256:[0-9a-f]{64}$");
    def bare_digest: type == "string" and test("^[0-9a-f]{64}$");
    def identity:
      type == "object" and (keys | sort) == ["epoch","name","version"] and
      (.name | type == "string" and test("^[a-z0-9][a-z0-9+._-]*$")) and
      (.version | type == "string" and test("^[0-9][A-Za-z0-9+._-]*$")) and
      (.epoch | type == "number" and . >= 0 and floor == .);
    def origin:
      type == "object" and
      if .type == "legacy-snapshot" then
        (keys | sort) == ["assetId","assetSha256","manifestSha256","releaseId","releaseTag","sourcePath","targetCommit","type"] and
        (.releaseId | type == "number" and floor == . and . > 0) and
        (.releaseTag | type == "string" and test("^apk-repo-v[0-9]{4}$")) and
        (.targetCommit | hex(40)) and (.assetId | type == "number" and floor == . and . > 0) and
        (.assetSha256 | digest) and (.manifestSha256 | bare_digest) and
        (.sourcePath | type == "string" and test("^(aarch64|x86_64)/[^/]+\\.apk$"))
      elif .type == "attested-build" then
        (keys | sort) == ["buildArtifactId","buildArtifactSha256","buildRunId","buildWorkflowId","bundlePath","bundleSha256","signingRunId","signingWorkflowId","sourceCommit","type","unsignedSha256"] and
        (.sourceCommit | hex(40)) and
        ([.buildWorkflowId,.buildRunId,.buildArtifactId,.signingWorkflowId,.signingRunId] | all(type == "number" and floor == . and . > 0)) and
        (.buildArtifactSha256 | digest) and (.unsignedSha256 | bare_digest) and
        (.bundlePath | type == "string" and test("^bundles/[a-z0-9]+([._+-][a-z0-9]+)*/(aarch64|x86_64)\\.json$")) and
        (.bundleSha256 | bare_digest)
      elif .type == "build-input" then
        (keys | sort) == ["artifactId","artifactSha256","runId","sourceCommit","type","unsignedSha256","workflowRef"] and
        (.sourceCommit | hex(40)) and (.workflowRef | type == "string" and length > 0) and
        ([.runId,.artifactId] | all(type == "number" and floor == . and . > 0)) and
        (.artifactSha256 | digest) and (.unsignedSha256 | bare_digest)
      else false end;
    def package:
      type == "object" and (keys | sort) == ["architecture","epoch","name","origin","path","sha256","version"] and
      (.architecture == "aarch64" or .architecture == "x86_64") and
      ({name,version,epoch} | identity) and
      (.path | type == "string" and test("^(aarch64|x86_64)/[^/]+\\.apk$")) and
      (. as $package | $package.path | startswith($package.architecture + "/")) and (.sha256 | bare_digest) and (.origin | origin);
    def packages:
      type == "array" and length > 0 and all(.[]; package) and
      (sort_by(.name,.version,.epoch,.architecture,.path) | group_by([.name,.version,.epoch]) | all(.[]; ([.[].architecture] | sort) == ["aarch64","x86_64"])) and
      (([.[].path] | length) == ([.[].path] | unique | length));
    def base:
      type == "object" and (keys | sort) == ["archive","asset","release","stateSha256"] and
      (.stateSha256 | bare_digest) and
      (.release | type == "object" and (keys | sort) == ["id","tag","targetCommit"] and (.id | type == "number" and floor == . and . > 0) and (.tag | type == "string" and test("^apk-repo-v[0-9]{4}$")) and (.targetCommit | hex(40))) and
      (.asset | type == "object" and (keys | sort) == ["id","name","sha256"] and (.id | type == "number" and floor == . and . > 0) and .name == "verity-apk-repository.tar.zst" and (.sha256 | digest)) and
      (.archive | type == "object" and (keys | sort) == ["manifestSha256","sha256"] and (.sha256 | digest) and (.manifestSha256 | bare_digest));
    def operation:
      type == "object" and
      if .mode == "migration" then (keys == ["mode"])
      elif .mode == "replacement" then ((keys | sort) == ["identity","mode"] and (.identity | identity))
      else false end;
    if type == "object" and .schemaVersion == 2 and
      (.status == "reserved" or .status == "complete") and
      (.repository | type == "string" and test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")) and
      (.release | type == "object" and (keys | sort) == ["tag","targetCommit"] and (.tag | type == "string" and test("^apk-repo-v[0-9]{4}$")) and (.targetCommit | hex(40))) and
      (.base | base) and (.operation | operation) and (.unsignedPackages | packages) and
      if .status == "reserved" then
        (keys | sort) == ["base","operation","release","repository","schemaVersion","status","unsignedPackages"]
      else
        (keys | sort) == ["archive","base","operation","packages","release","repository","schemaVersion","status","unsignedPackages"] and
        (.packages | packages) and
        (.archive | type == "object" and (keys | sort) == ["name","sha256"] and .name == "verity-apk-repository.tar.zst" and (.sha256 | bare_digest))
      end
    then . else error("invalid schema-v2 release marker") end
  '
}

marker_from_body() {
  local kind=$1 body=$2
  sed -n "s/^<!-- apk-release-${kind}: \(.*\) -->$/\\1/p" <<<"$body"
}

base_snapshot() {
  local state=$1 state_sha=$2
  jq -ceS --arg state_sha "$state_sha" '
    . as $state |
    {
      stateSha256:$state_sha,
      release:{id:.release.id,tag:.release.tag,targetCommit:.release.targetCommit},
      asset:{id:.asset.id,name:.asset.name,sha256:.asset.sha256},
      archive:{sha256:.archive.sha256,manifestSha256:.archive.manifestSha256}
    }
  ' "$state"
}

base_packages() {
  jq -ceS '
    . as $state |
    [.packages[] |
      . + {origin:(.origin // {
        type:"legacy-snapshot",
        releaseId:$state.release.id,
        releaseTag:$state.release.tag,
        targetCommit:$state.release.targetCommit,
        assetId:$state.asset.id,
        assetSha256:$state.asset.sha256,
        manifestSha256:$state.archive.manifestSha256,
        sourcePath:.path
      })}
    ] | sort_by(.name,.version,.epoch,.architecture,.path)
  ' "$1"
}

legacy_seed() {
  jq -nce --arg tag "$1" '
    {
      "apk-repo-v0001":{releaseId:363733856,assetId:498710090,archiveSha256:"sha256:1d56b5710707b2aff9ee1e9cd0876466a6eb795fca5d0e58bb3f91c5c2922802"},
      "apk-repo-v0002":{releaseId:363781736,assetId:498881369,archiveSha256:"sha256:7d6783ffae959a9761fc61cf10b7888a14813e2e24887ff8315fa52f8a68e79a"}
    }[$tag] // error("unmarked release is not an approved legacy seed")
  '
}

verify_legacy() {
  local release=$1 tag=$2 seed asset release_dir archive manifest manifest_sha target package identity packages
  seed=$(legacy_seed "$tag") || error "Release $tag has no schema-v2 marker."
  jq -e --argjson seed "$seed" '
    .id == $seed.releaseId and .draft == false and .prerelease == false and .immutable == true and
    (.target_commitish | type == "string" and test("^[0-9a-f]{40}$")) and
    (.assets | type == "array" and length == 1) and
    .assets[0].id == $seed.assetId and .assets[0].name == "verity-apk-repository.tar.zst" and
    .assets[0].state == "uploaded" and .assets[0].digest == $seed.archiveSha256
  ' <<<"$release" >/dev/null || error "Legacy release $tag is mutable or has unexpected API metadata."
  target=$(jq -er '.target_commitish' <<<"$release")
  [[ "$(git rev-list -n1 "$tag")" == "$target" ]] || error "Legacy release $tag target does not match its immutable tag."
  release_dir="$work_dir/legacy-$tag"
  mkdir -p "$release_dir"
  asset=$(jq -er '.assets[0].id' <<<"$release")
  archive="$release_dir/$asset.tar.zst"
  gh_call api "repos/${repository}/releases/assets/${asset}" -H 'Accept: application/octet-stream' > "$archive"
  [[ "sha256:$(sha256 "$archive")" == "$(jq -r '.archiveSha256' <<<"$seed")" ]] || error "Legacy release $tag archive digest mismatch."
  safe_archive_members "$archive" "$release_dir/members" || error "Legacy release $tag archive contains unsafe members."
  [[ $(grep -cx 'apk/manifest.json' "$release_dir/members") -eq 1 ]] || error "Legacy release $tag archive has an invalid manifest path."
  tar --zstd --no-same-owner --no-same-permissions -xf "$archive" -C "$release_dir"
  manifest="$release_dir/apk/manifest.json"
  manifest_sha=$(sha256 "$manifest")
  python3 "$root/scripts/apk_repository_policy.py" "$release_dir/apk" "$root/packages/keys" "$manifest_sha"
  jq -e '
    .architectures | sort == ["aarch64","x86_64"]
  ' "$manifest" >/dev/null || error "Legacy release $tag manifest has an invalid architecture set."
  packages='[]'
  while IFS= read -r package; do
    architecture=$(jq -er '.architecture' <<<"$package")
    path=$(jq -er '.path' <<<"$package")
    digest=$(jq -er '.sha256' <<<"$package")
    [[ "$architecture" == aarch64 || "$architecture" == x86_64 ]]
    [[ "$path" == "$architecture/"*.apk ]]
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]]
    [[ "$(sha256 "$release_dir/apk/$path")" == "$digest" ]] || error "Legacy release $tag package digest mismatch."
    identity=$(package_identity "$release_dir/apk/$path")
    package=$(jq -cn --argjson identity "$identity" --arg architecture "$architecture" --arg path "$path" --arg sha256 "$digest" \
      '$identity + {architecture:$architecture,path:$path,sha256:$sha256}')
    packages=$(jq -cn --argjson packages "$packages" --argjson package "$package" '$packages + [$package]')
  done < <(jq -c '.packages[]' "$manifest")
  jq -ceS 'sort_by(.name,.version,.epoch,.architecture,.path)' <<<"$packages"
}

collision_check() {
  local candidate=$1 historical=$2 tag=$3 compare_origin=$4 identities current prior
  identities=$(jq -cn --argjson packages "$candidate" '$packages | map([.name,.version,.epoch]) | unique')
  while IFS= read -r identity; do
    current=$(jq -nceS --argjson identity "$identity" --argjson packages "$candidate" --argjson compare_origin "$compare_origin" '
      [$packages[] | select([.name,.version,.epoch] == $identity) |
        if $compare_origin then . else del(.origin) end] | sort_by(.architecture,.path)
    ')
    prior=$(jq -nceS --argjson identity "$identity" --argjson packages "$historical" --argjson compare_origin "$compare_origin" '
      [$packages[] | select([.name,.version,.epoch] == $identity) |
        if $compare_origin then . else del(.origin) end] | sort_by(.architecture,.path)
    ')
    if [[ "$prior" != '[]' && "$current" != "$prior" ]]; then
      error "Release $tag already contains this package identity with different bytes, paths, or origins."
    fi
  done < <(jq -c '.[]' <<<"$identities")
}

scan_releases() {
  local phase=$1 candidate=${2:-'[]'} expected_body=${3:-} releases max_tag expected_tag attempt target_count=0 blockers=0
  local release tag body reserved complete normalized historical
  for attempt in {1..10}; do
    releases=$(release_pages | flat_releases)
    if [[ "$phase" != post-create ]] || jq -e --arg tag "$release_tag" 'any(.[]; .tag_name == $tag)' <<<"$releases" >/dev/null; then
      break
    fi
    [[ $attempt -lt 10 ]] || error "Release $release_tag was not visible after creation."
    sleep "${GH_VISIBILITY_RETRY_SECONDS:-1}"
  done
  max_tag=$(jq -r '[.[] | .tag_name? | select(type == "string" and test("^apk-repo-v[0-9]{4}$"))] | max // "apk-repo-v0000"' <<<"$releases")
  expected_tag=$(printf 'apk-repo-v%04d' "$((10#${max_tag##*v} + 1))")
  if [[ "$phase" == reserve && "$release_tag" != "$expected_tag" ]]; then
    error "Release tag $release_tag is not strictly next; expected $expected_tag."
  fi
  while IFS= read -r release; do
    tag=$(jq -er '.tag_name' <<<"$release")
    [[ "$tag" =~ ^apk-repo-v[0-9]{4}$ ]] || continue
    body=$(jq -er '.body // ""' <<<"$release")
    body=${body//$'\r'/}
    reserved=$(marker_from_body reserved "$body")
    complete=$(marker_from_body complete "$body")
    [[ $(grep -c '^<!-- apk-release-reserved: .* -->$' <<<"$body" || true) -le 1 ]]
    [[ $(grep -c '^<!-- apk-release-complete: .* -->$' <<<"$body" || true) -le 1 ]]
    if [[ -n "$reserved" && -n "$complete" ]]; then
      error "Release $tag contains conflicting ledger markers."
    elif [[ -n "$reserved" ]]; then
      normalized=$(normalize_marker <<<"$reserved") || error "Release $tag has a malformed reserved marker."
      [[ $(jq -r '.status' <<<"$normalized") == reserved ]]
      [[ $(jq -r '.repository' <<<"$normalized") == "$repository" ]]
      [[ $(jq -r '.release.tag' <<<"$normalized") == "$tag" ]]
      [[ $(jq -r '.release.targetCommit' <<<"$normalized") == "$(jq -r '.target_commitish' <<<"$release")" ]]
      [[ $(jq -r '.draft' <<<"$release") == true ]] || error "Published release $tag contains an incomplete reserved marker."
      if [[ "$tag" == "$release_tag" && ( "$phase" == post-create || "$phase" == complete-pre ) ]]; then
        [[ "$body" == "$expected_body" ]]
        [[ $(jq -r '.assets | length' <<<"$release") -eq 0 ]]
        if [[ "$phase" == post-create ]]; then
          created=1
        fi
        target_count=$((target_count + 1))
      else
        blockers=$((blockers + 1))
      fi
    elif [[ -n "$complete" ]]; then
      normalized=$(normalize_marker <<<"$complete") || error "Release $tag has a malformed complete marker."
      [[ "$complete" == "$normalized" ]] || error "Release $tag has a noncanonical complete marker."
      [[ $(jq -r '.status' <<<"$normalized") == complete ]]
      [[ $(jq -r '.repository' <<<"$normalized") == "$repository" ]]
      [[ $(jq -r '.release.tag' <<<"$normalized") == "$tag" ]]
      [[ $(jq -r '.release.targetCommit' <<<"$normalized") == "$(jq -r '.target_commitish' <<<"$release")" ]]
      if [[ "$tag" != "$release_tag" || ( "$phase" != complete-post && "$phase" != publish ) ]]; then
        jq -e --arg digest "sha256:$(jq -r '.archive.sha256' <<<"$normalized")" '
          .draft == false and .prerelease == false and .immutable == true and
          (.published_at | type == "string" and length > 0) and
          (.assets | type == "array" and length == 1) and
          .assets[0].name == "verity-apk-repository.tar.zst" and
          .assets[0].state == "uploaded" and .assets[0].digest == $digest
        ' <<<"$release" >/dev/null || error "Complete release $tag is not an immutable published snapshot."
      fi
      historical=$(jq -c '.packages' <<<"$normalized")
      collision_check "$candidate" "$historical" "$tag" true
      if [[ "$tag" == "$release_tag" && ( "$phase" == complete-post || "$phase" == publish ) ]]; then
        [[ "$body" == "$expected_body" ]]
        target_count=$((target_count + 1))
        if [[ "$phase" == publish ]]; then
          jq -e --arg digest "sha256:$(jq -r '.archive.sha256' <<<"$normalized")" '
            .draft == true and .prerelease == false and
            (.assets | type == "array" and length == 1) and
            .assets[0].name == "verity-apk-repository.tar.zst" and
            .assets[0].state == "uploaded" and .assets[0].digest == $digest
          ' <<<"$release" >/dev/null || error "Release $tag is not ready for immutable publication."
        fi
      elif [[ "$tag" == "$release_tag" ]]; then
        error "Release $tag already exists."
      fi
    else
      historical=$(verify_legacy "$release" "$tag")
      collision_check "$candidate" "$historical" "$tag" false
      [[ "$tag" != "$release_tag" ]] || error "Release $tag already exists."
    fi
  done < <(jq -c '.[]' <<<"$releases")
  [[ $blockers -eq 0 ]] || error "A draft reservation already blocks APK publication."
  case "$phase" in
    post-create|complete-pre|complete-post|publish)
      [[ $target_count -eq 1 ]] || error "Release $release_tag changed during the ledger rescan."
      ;;
  esac
  if [[ "$phase" == post-create && "$max_tag" != "$release_tag" ]]; then
    error "A competing release was created after reservation began."
  fi
}

checked_base() {
  local state=$1 pin
  [[ -f "$state" ]]
  pin="$(dirname "$state")/repository-state.pin.json"
  [[ -f "$pin" ]]
  cmp "$state" "$pin" >/dev/null || error "Reviewed repository state and pin differ."
  git diff --quiet -- "$state" "$pin" || error "Reviewed repository state is dirty."
  git diff --cached --quiet -- "$state" "$pin" || error "Reviewed repository state is staged."
  python3 "$root/scripts/validate_repository_state.py" "$state"
}

unsigned_packages() {
  local inputs=$1 state=$2 mode package architecture path file identity digest origin entry packages='[]' base
  mode=$(jq -er '.mode' "$inputs")
  jq -e 'type == "object" and (.mode == "migration" or .mode == "replacement") and (.packages | type == "array" and length > 0)' "$inputs" >/dev/null
  while IFS= read -r package; do
    architecture=$(jq -er '.architecture' <<<"$package")
    path=$(jq -er '.path' <<<"$package")
    file=$(jq -er '.file' <<<"$package")
    [[ "$architecture" == aarch64 || "$architecture" == x86_64 ]]
    [[ "$path" == "$architecture/"*.apk ]]
    [[ -f "$file" ]]
    identity=$(package_identity "$file")
    digest=$(sha256 "$file")
    if [[ "$mode" == migration ]]; then
      base=$(base_packages "$state")
      origin=$(jq -ce --arg architecture "$architecture" --arg path "$path" --arg digest "$digest" --argjson identity "$identity" '
        [.[] | select(.architecture == $architecture and .path == $path and .sha256 == $digest and
          [.name,.version,.epoch] == [$identity.name,$identity.version,$identity.epoch])] |
        if length == 1 then .[0].origin else error("migration package does not match reviewed base") end
      ' <<<"$base") || error "Migration input $path is not an exact reviewed package."
    else
      origin=$(jq -ce '.origin' <<<"$package")
    fi
    entry=$(jq -cn --argjson identity "$identity" --arg architecture "$architecture" --arg path "$path" --arg sha256 "$digest" --argjson origin "$origin" \
      '$identity + {architecture:$architecture,path:$path,sha256:$sha256,origin:$origin}')
    packages=$(jq -cn --argjson packages "$packages" --argjson entry "$entry" '$packages + [$entry]')
  done < <(jq -c '.packages[]' "$inputs")
  jq -ceS 'sort_by(.name,.version,.epoch,.architecture,.path)' <<<"$packages"
}

reserve() {
  [[ $# -eq 5 ]]
  repository=$1 release_tag=$2 source_sha=$3
  local state=$4 inputs=$5 state_sha base operation packages reservation notes
  [[ "$release_tag" =~ ^apk-repo-v[0-9]{4}$ ]]
  [[ "$source_sha" =~ ^[0-9a-f]{40}$ ]]
  checked_base "$state"
  state_sha=$(sha256 "$state")
  base=$(base_snapshot "$state" "$state_sha")
  packages=$(unsigned_packages "$inputs" "$state")
  if [[ $(jq -r '.mode' "$inputs") == migration ]]; then
    operation='{"mode":"migration"}'
  else
    operation=$(jq -ceS '{mode:"replacement",identity:.identity}' "$inputs")
    jq -ne --argjson operation "$operation" --argjson packages "$packages" '
      all($packages[];
        [.name,.version,.epoch] == [$operation.identity.name,$operation.identity.version,$operation.identity.epoch] and
        .origin.type == "build-input" and .origin.unsignedSha256 == .sha256)
    ' </dev/null >/dev/null || error "Replacement inputs do not match the requested identity and unsigned digests."
  fi
  reservation=$(jq -cnS --arg repository "$repository" --arg tag "$release_tag" --arg target "$source_sha" \
    --argjson base "$base" --argjson operation "$operation" --argjson packages "$packages" \
    '{schemaVersion:2,status:"reserved",repository:$repository,release:{tag:$tag,targetCommit:$target},base:$base,operation:$operation,unsignedPackages:$packages}' | normalize_marker)
  scan_releases reserve "$packages"
  verify_tag_absent
  notes=$(jq -nr --arg release_tag "$release_tag" --argjson reservation "$reservation" '
    "APK repository byte reservation: \($release_tag)\n\n" +
    "<!-- apk-release-reserved: \($reservation | tojson) -->"
  ')
  reservation_body=$notes
  gh_call release create "$release_tag" --repo "$repository" --draft --target "$source_sha" --title "$release_tag" --notes "$notes" >/dev/null
  created=1
  scan_releases post-create "$packages" "$notes"
  verify_tag_absent
  created=0
  printf '%s\n' "$reservation"
}

complete() {
  [[ $# -eq 5 ]]
  repository=$1 release_tag=$2
  local source_sha=$3 reservation_file=$4 archive_file=$5 repository_dir="$work_dir/final/apk" reservation packages='[]' unsigned final path architecture digest identity origin entry complete notes member mode binding manifest_schema replacement_count=0
  reservation=$(normalize_marker < "$reservation_file")
  [[ $(jq -r '.status' <<<"$reservation") == reserved ]]
  [[ $(jq -r '.repository' <<<"$reservation") == "$repository" ]]
  [[ $(jq -r '.release.tag' <<<"$reservation") == "$release_tag" ]]
  [[ $(jq -r '.release.targetCommit' <<<"$reservation") == "$source_sha" ]]
  notes=$(jq -nr --arg release_tag "$release_tag" --argjson reservation "$reservation" '
    "APK repository byte reservation: \($release_tag)\n\n" +
    "<!-- apk-release-reserved: \($reservation | tojson) -->"
  ')
  scan_releases complete-pre "$(jq -c '.unsignedPackages' <<<"$reservation")" "$notes"
  mkdir -p "$work_dir/final"
  safe_archive_members "$archive_file" "$work_dir/final-members" || error "Final archive contains unsafe members."
  [[ $(grep -cx 'apk/manifest.json' "$work_dir/final-members") -eq 1 ]] || error "Final archive has an invalid manifest path."
  tar --zstd --no-same-owner --no-same-permissions -xf "$archive_file" -C "$work_dir/final"
  unsigned=$(jq -c '.unsignedPackages' <<<"$reservation")
  mode=$(jq -r '.operation.mode' <<<"$reservation")
  manifest_schema=$(jq -r '.schemaVersion // 1' "$repository_dir/manifest.json")
  while IFS= read -r final; do
    architecture=$(jq -er '.architecture' <<<"$final")
    path=$(jq -er '.path' <<<"$final")
    digest=$(jq -er '.sha256' <<<"$final")
    [[ -f "$repository_dir/$path" ]]
    [[ "$(sha256 "$repository_dir/$path")" == "$digest" ]]
    identity=$(package_identity "$repository_dir/$path")
    if [[ "$manifest_schema" == 2 ]]; then
      jq -e --argjson identity "$identity" '[.name,.version,.epoch] == [$identity.name,$identity.version,$identity.epoch]' \
        <<<"$final" >/dev/null || error "Final package identity does not match its manifest entry."
    fi
    if origin=$(jq -ce '.origin' <<<"$final" 2>/dev/null); then
      :
    elif [[ "$mode" == migration ]]; then
      origin=$(jq -ce --arg architecture "$architecture" --arg path "$path" --argjson identity "$identity" '
        [.[] | select(.architecture == $architecture and .path == $path and [.name,.version,.epoch] == [$identity.name,$identity.version,$identity.epoch])] |
        if length == 1 then .[0].origin else error("final migration package diverges from reservation") end
      ' <<<"$unsigned") || error "Final migration package diverges from reservation."
    else
      error "Final replacement manifest is missing package provenance."
    fi
    if [[ "$mode" == replacement ]] && jq -e --argjson identity "$identity" \
      '[.name,.version,.epoch] == [$identity.name,$identity.version,$identity.epoch]' \
      <<<"$(jq -c '.operation.identity' <<<"$reservation")" >/dev/null; then
      binding=$(jq -ce --arg architecture "$architecture" --arg path "$path" --argjson identity "$identity" '
        [.[] | select(.architecture == $architecture and .path == $path and [.name,.version,.epoch] == [$identity.name,$identity.version,$identity.epoch])] |
        if length == 1 then .[0] else error("replacement package diverges from reservation") end
      ' <<<"$unsigned") || error "Final replacement package diverges from reservation."
      jq -ne --argjson origin "$origin" --argjson binding "$binding" '
        $binding.origin.type == "build-input" and
        $binding.origin.unsignedSha256 == $binding.sha256 and
        $origin.type == "attested-build" and
        $origin.sourceCommit == $binding.origin.sourceCommit and
        $origin.buildRunId == $binding.origin.runId and
        $origin.buildArtifactId == $binding.origin.artifactId and
        $origin.buildArtifactSha256 == $binding.origin.artifactSha256 and
        $origin.unsignedSha256 == $binding.sha256
      ' >/dev/null || error "Final replacement provenance does not bind its reserved input."
      replacement_count=$((replacement_count + 1))
    fi
    entry=$(jq -cn --argjson identity "$identity" --arg architecture "$architecture" --arg path "$path" --arg sha256 "$digest" --argjson origin "$origin" \
      '$identity + {architecture:$architecture,path:$path,sha256:$sha256,origin:$origin}')
    packages=$(jq -cn --argjson packages "$packages" --argjson entry "$entry" '$packages + [$entry]')
  done < <(jq -c '.packages[]' "$repository_dir/manifest.json")
  packages=$(jq -ceS 'sort_by(.name,.version,.epoch,.architecture,.path)' <<<"$packages")
  if [[ "$mode" == migration ]]; then
    [[ "$packages" == "$(jq -ceS '.unsignedPackages' <<<"$reservation")" ]] || error "Migration changed package bytes."
  else
    [[ $replacement_count -eq $(jq -r 'length' <<<"$unsigned") ]] || error "Final manifest does not contain every reserved replacement."
  fi
  complete=$(jq -cnS --argjson reservation "$reservation" --argjson packages "$packages" --arg archive_sha "$(sha256 "$archive_file")" \
    '$reservation | .status="complete" | .packages=$packages | .archive={name:"verity-apk-repository.tar.zst",sha256:$archive_sha}' | normalize_marker)
  scan_releases complete-pre "$packages" "$notes"
  notes=$(jq -nr --arg release_tag "$release_tag" --argjson complete "$complete" '
    "APK repository complete byte ledger: \($release_tag)\n\n" +
    "SHA-256: \($complete.archive.sha256)\n\n" +
    "<!-- apk-release-complete: \($complete | tojson) -->"
  ')
  gh_call release edit "$release_tag" --repo "$repository" --notes "$notes" >/dev/null
  scan_releases complete-post "$packages" "$notes"
  printf '%s\n' "$complete"
}

publish() {
  [[ $# -eq 2 ]]
  repository=$1 release_tag=$2
  local releases body complete notes source_sha
  releases=$(release_pages | flat_releases)
  body=$(jq -er --arg tag "$release_tag" '[.[] | select(.tag_name == $tag)] | if length == 1 then .[0].body // "" else error("release lookup mismatch") end' <<<"$releases")
  body=${body//$'\r'/}
  complete=$(marker_from_body complete "$body")
  [[ -n "$complete" ]] || error "Release $release_tag has no complete marker; publication refused."
  complete=$(normalize_marker <<<"$complete")
  source_sha=$(jq -r '.release.targetCommit' <<<"$complete")
  notes=$(jq -nr --arg release_tag "$release_tag" --argjson complete "$complete" '
    "APK repository complete byte ledger: \($release_tag)\n\n" +
    "SHA-256: \($complete.archive.sha256)\n\n" +
    "<!-- apk-release-complete: \($complete | tojson) -->"
  ')
  scan_releases publish "$(jq -c '.packages' <<<"$complete")" "$notes"
  ensure_live_tag "$source_sha"
  gh_call release edit "$release_tag" --repo "$repository" --target "$source_sha" --draft=false >/dev/null
}

mode=${1:-}
shift || true
case "$mode" in
  reserve) reserve "$@" ;;
  complete) complete "$@" ;;
  publish) publish "$@" ;;
  *) error 'usage: reserve-apk-release-identity.sh {reserve|complete|publish} ...' ;;
esac
