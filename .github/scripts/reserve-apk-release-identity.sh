#!/bin/bash
set -euo pipefail

[[ $# -eq 5 ]]

repository=$1
release_tag=$2
source_sha=$3
x86_64_package=$4
aarch64_package=$5
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM

[[ "$release_tag" =~ ^apk-repo-v[0-9]{4}$ ]]
[[ "$source_sha" =~ ^[0-9a-f]{40}$ ]]

package_identity() {
  local architecture=$1 package=$2 metadata recipe name version epoch
  metadata=$(tar -xOf "$package" .PKGINFO)
  recipe=$(tar -xOf "$package" .melange.yaml)
  name=$(awk -F ' = ' '$1 == "pkgname" { print $2; exit }' <<<"$metadata")
  version=$(awk -F ' = ' '$1 == "pkgver" { print $2; exit }' <<<"$metadata")
  epoch=$(awk '/^  epoch: / { print $2; exit }' <<<"$recipe")
  [[ "$name" =~ ^[a-z0-9][a-z0-9+._-]*$ ]]
  [[ "$version" =~ ^[0-9][A-Za-z0-9+._-]*$ ]]
  [[ "$epoch" =~ ^[0-9]+$ ]]
  jq -cn --arg architecture "$architecture" --arg name "$name" --arg version "$version" --argjson epoch "$epoch" \
    '{architecture:$architecture,name:$name,version:$version,epoch:$epoch}'
}

identities() {
  package_identity x86_64 "$1"
  package_identity aarch64 "$2"
}

identity=$(identities "$x86_64_package" "$aarch64_package" | jq -sc '{schemaVersion:1,packages:sort_by(.architecture)}')
releases=$(gh api --paginate --slurp "repos/${repository}/releases?per_page=100")

while IFS= read -r release; do
  tag=$(jq -er '.tag_name' <<<"$release")
  [[ "$tag" =~ ^apk-repo-v[0-9]{4}$ ]] || continue
  if [[ "$tag" == "$release_tag" ]]; then
    printf '::error title=Duplicate release::Release %s already exists.\n' "$release_tag" >&2
    exit 1
  fi
  body=$(jq -er '.body // ""' <<<"$release")
  body=${body//$'\r'/}
  marker_count=$(grep -c '^<!-- apk-release-identity: .* -->$' <<<"$body" || true)
  if [[ "$marker_count" == 1 ]]; then
    historical=$(sed -n 's/^<!-- apk-release-identity: \(.*\) -->$/\1/p' <<<"$body")
    if ! historical=$(jq -ce '
      if .schemaVersion == 1 and
        (.packages | type == "array" and length == 2) and
        ([.packages[].architecture] | sort) == ["aarch64", "x86_64"]
        and all(.packages[];
          type == "object" and
          (.name | type == "string" and length > 0) and
          (.version | type == "string" and length > 0) and
          (.epoch | type == "number" and . >= 0 and floor == .)
        )
      then {schemaVersion:1,packages:(.packages | sort_by(.architecture) | map({architecture,name,version,epoch}))}
      else error("invalid identity reservation") end
    ' <<<"$historical" 2>/dev/null); then
      printf '::error title=Malformed identity reservation::Release %s has an invalid identity reservation.\n' "$tag" >&2
      exit 1
    fi
  elif [[ "$marker_count" == 0 ]]; then
    release_dir="$work_dir/$tag"
    mkdir -p "$release_dir"
    if ! jq -e '.assets | type == "array" and any(.[]; .name == "verity-apk-repository.tar.zst")' <<<"$release" >/dev/null; then
      printf '::error title=Missing identity reservation::Release %s has no reservation or repository archive.\n' "$tag" >&2
      exit 1
    fi
    gh release download "$tag" --repo "$repository" --pattern verity-apk-repository.tar.zst --dir "$release_dir" >/dev/null
    tar --zstd -xf "$release_dir/verity-apk-repository.tar.zst" -C "$release_dir"
    shopt -s nullglob
    x86_64_packages=("$release_dir"/apk/x86_64/*.apk)
    aarch64_packages=("$release_dir"/apk/aarch64/*.apk)
    [[ ${#x86_64_packages[@]} -eq 1 ]]
    [[ ${#aarch64_packages[@]} -eq 1 ]]
    historical=$(identities "${x86_64_packages[0]}" "${aarch64_packages[0]}" | jq -sc '{schemaVersion:1,packages:sort_by(.architecture)}')
  else
    printf '::error title=Malformed identity reservation::Release %s has multiple identity reservations.\n' "$tag" >&2
    exit 1
  fi
  if [[ "$historical" == "$identity" ]]; then
    printf '::error title=Package identity reuse::Release %s already reserves this identity. Delete an abandoned draft only after review.\n' "$tag" >&2
    exit 1
  fi
done < <(jq -c '[.[] | if type == "array" then .[] else . end | select(.tag_name | test("^apk-repo-v[0-9]{4}$"))][]' <<<"$releases")

if git ls-remote --exit-code --tags origin "refs/tags/${release_tag}" >/dev/null 2>&1; then
  printf '::error title=Duplicate tag::Tag %s already exists.\n' "$release_tag" >&2
  exit 1
fi

notes=$(jq -nr --arg release_tag "$release_tag" --argjson identity "$identity" '
  "APK repository identity reservation: \($release_tag)\n\n" +
  "<!-- apk-release-identity: \($identity | tojson) -->"
')
gh release create "$release_tag" --repo "$repository" --draft --target "$source_sha" --title "$release_tag" --notes "$notes" >/dev/null
printf '%s\n' "$identity"
