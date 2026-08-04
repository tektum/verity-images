#!/bin/bash
set -euo pipefail
shopt -s inherit_errexit

usage='usage: assemble-apk-repository.sh INPUT METADATA OUTPUT ARCHIVE KEY FINGERPRINT'
[[ $# -eq 6 ]] || { printf '%s\n' "$usage" >&2; exit 2; }
input=$1
metadata=$2
output=$3
archive=$4
key=$5
fingerprint=$6
root=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
source_date_epoch=${SOURCE_DATE_EPOCH:-0}
[[ "$source_date_epoch" =~ ^[0-9]+$ ]]
[[ -d "$input" && -f "$metadata" && -f "$key" ]]
[[ ! -e "$output" && ! -e "$archive" ]]

work_dir=$(mktemp -d "$(dirname "$output")/.assemble-apk.XXXXXX")
repository=$work_dir/apk
archive_stage=$work_dir/verity-apk-repository.tar.zst
published_output=0
published_archive=0
child=
cleanup() {
  status=$?
  trap - EXIT
  if [[ -n "$child" ]]; then
    kill "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
  fi
  if [[ $status -ne 0 ]]; then
    [[ $published_archive -eq 0 ]] || rm -f "$archive"
    [[ $published_output -eq 0 ]] || rm -rf "$output"
  fi
  rm -rf "$work_dir"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

python3 "$root/scripts/compose_apk_inputs.py" verify "$input" "$metadata"
metadata_sha256=$(sha256sum "$metadata" | cut -d' ' -f1)
mkdir -p "$repository"
mapfile -t package_paths < <(jq -er '.packages | sort_by(.path)[] | .path' "$metadata")
mapfile -t bundle_paths < <(jq -er '[.packages[].origin | select(.type == "attested-build") | .bundlePath] | unique[]' "$metadata")
for member in "${package_paths[@]}" "${bundle_paths[@]}"; do
  mkdir -p "$repository/$(dirname "$member")"
  cp "$input/$member" "$repository/$member"
done
cp "$metadata" "$repository/manifest.json"

export SOURCE_DATE_EPOCH=$source_date_epoch
for architecture in aarch64 x86_64; do
  mapfile -t packages < <(jq -er --arg architecture "$architecture" '.packages | map(select(.architecture == $architecture)) | sort_by(.path)[] | .path' "$metadata")
  ((${#packages[@]}))
  command=(melange index --arch "$architecture" --signing-key "$key" --output "$repository/$architecture/APKINDEX.tar.gz")
  for package in "${packages[@]}"; do
    command+=("$repository/$package")
  done
  timeout "${MELANGE_TIMEOUT_SECONDS:-300}" "${command[@]}" &
  child=$!
  wait "$child"
  child=
done

keys=$work_dir/keys
mkdir "$keys"
public_key=$keys/$(basename "$key").pub
openssl pkey -in "$key" -pubout > "$public_key"
actual_fingerprint=$(openssl pkey -pubin -in "$public_key" -pubout -outform DER | sha256sum | cut -d' ' -f1)
[[ "$actual_fingerprint" == "$fingerprint" ]]
[[ "$(jq -er '.fingerprint' "$metadata")" == "$fingerprint" ]]
[[ "$(sha256sum "$metadata" | cut -d' ' -f1)" == "$metadata_sha256" ]]
python3 "$root/scripts/compose_apk_inputs.py" verify "$input" "$metadata"
for member in "${package_paths[@]}" "${bundle_paths[@]}"; do
  cmp "$input/$member" "$repository/$member"
done
manifest_digest=$(sha256sum "$repository/manifest.json" | cut -d' ' -f1)
python3 "$root/scripts/apk_repository_policy.py" "$repository" "$keys" "$manifest_digest"

tar --zstd --sort=name --mtime="@$source_date_epoch" --owner=0 --group=0 --numeric-owner \
  --mode='u+rwX,go+rX,go-w' -C "$work_dir" -cf "$archive_stage" apk
published_output=1
mv "$repository" "$output"
published_archive=1
mv "$archive_stage" "$archive"
