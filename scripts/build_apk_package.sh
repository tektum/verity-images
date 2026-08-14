#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
rm -rf artifact

if [[ $# -ne 2 || -z "$1" || -z "$2" ]]; then
  printf 'usage: build_apk_package.sh PACKAGE ARCHITECTURE\n' >&2
  exit 2
fi
package=$1
architecture=$2

if [[ ! "$package" =~ ^[a-z0-9][a-z0-9+._-]*$ || ! -f "packages/$package/melange.yaml" ]]; then
  printf 'unknown package: %s\n' "$package" >&2
  exit 2
fi
recipe=packages/$package/melange.yaml
runtime_gate=
case "$package" in
  openssl-fips-provider)
    runtime_gate=scripts/test_fips_runtime.sh
    ;;
esac

case "$architecture" in
  x86_64) expected_machine=x86_64 ;;
  aarch64) expected_machine=aarch64 ;;
  *)
    printf 'unsupported architecture: %s\n' "$architecture" >&2
    exit 2
    ;;
esac

if [[ "$(uname -m)" != "$expected_machine" ]]; then
  printf 'runner architecture %s does not match requested %s\n' "$(uname -m)" "$expected_machine" >&2
  exit 2
fi

work_dir=$(mktemp -d)
stage_dir=
cleanup() {
  rm -rf "$work_dir" "$stage_dir"
  [[ -z "$stage_dir" ]] || rm -rf artifact
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

if ! source_state=$(git status --porcelain --untracked-files=all); then
  printf 'cannot inspect source worktree\n' >&2
  exit 2
fi
if [[ -n "$source_state" ]]; then
  printf 'source worktree must be clean\n' >&2
  exit 2
fi
if ! source_sha=$(git rev-parse --verify HEAD); then
  printf 'cannot resolve source commit\n' >&2
  exit 2
fi
recipe_sha256=$(sha256sum "$recipe" | cut -d' ' -f1)

melange build "$recipe" --arch "$architecture" --runner docker \
  --out-dir "$work_dir/out" --cache-dir "$work_dir/cache"
if ! current_source_sha=$(git rev-parse --verify HEAD) || \
  ! source_state=$(git status --porcelain --untracked-files=all); then
  printf 'cannot recheck source worktree\n' >&2
  exit 2
fi
if [[ "$current_source_sha" != "$source_sha" || -n "$source_state" || \
  "$(sha256sum "$recipe" | cut -d' ' -f1)" != "$recipe_sha256" ]]; then
  printf 'source changed during build\n' >&2
  exit 2
fi

find "$work_dir/out" -type f -name '*.apk' -print0 | sort -z > "$work_dir/candidates"
mapfile -d '' candidates < "$work_dir/candidates"
primary=()
primary_version=
for candidate in "${candidates[@]}"; do
  pkginfo=$(tar -xzOf "$candidate" .PKGINFO)
  candidate_name_count=$(awk -F ' = ' '$1 == "pkgname" {count++} END {print count + 0}' <<<"$pkginfo")
  candidate_version_count=$(awk -F ' = ' '$1 == "pkgver" {count++} END {print count + 0}' <<<"$pkginfo")
  candidate_architecture_count=$(awk -F ' = ' '$1 == "arch" {count++} END {print count + 0}' <<<"$pkginfo")
  if [[ "$candidate_name_count" -ne 1 || "$candidate_version_count" -ne 1 || \
    "$candidate_architecture_count" -ne 1 ]]; then
    printf 'invalid APK identity metadata: %s\n' "$candidate" >&2
    exit 2
  fi
  candidate_name=$(awk -F ' = ' '$1 == "pkgname" {print $2}' <<<"$pkginfo")
  candidate_version=$(awk -F ' = ' '$1 == "pkgver" {print $2}' <<<"$pkginfo")
  candidate_architecture=$(awk -F ' = ' '$1 == "arch" {print $2}' <<<"$pkginfo")
  if [[ ! "$candidate_version" =~ ^[A-Za-z0-9][A-Za-z0-9._+~:-]*$ ]]; then
    printf 'invalid APK version: %s\n' "$candidate_version" >&2
    exit 2
  fi
  if [[ "$candidate_name" == "$package" ]]; then
    primary+=("$candidate")
    primary_version=$candidate_version
    [[ "$candidate_architecture" == "$architecture" ]]
  fi
done
if [[ "${#primary[@]}" -ne 1 ]]; then
  printf 'expected exactly one primary APK for %s, found %s\n' "$package" "${#primary[@]}" >&2
  exit 2
fi

apk_name=$package-$primary_version.apk
unsigned_apk_sha256=$(sha256sum "${primary[0]}" | cut -d' ' -f1)
mkdir "$work_dir/repository"
melange keygen "$work_dir/test.rsa"
cp "${primary[0]}" "$work_dir/repository/$apk_name"
melange sign --signing-key "$work_dir/test.rsa" "$work_dir/repository/$apk_name"
PYTHONPATH=scripts python3 - "$work_dir/repository/$apk_name" "$architecture" "$package" "$primary_version" <<'PY'
import sys
from pathlib import Path

import apk_repository_policy

info = apk_repository_policy.checked_package(Path(sys.argv[1]), sys.argv[2])
if (info.name, info.version) != (sys.argv[3], sys.argv[4]):
    raise SystemExit("signed APK identity mismatch")
PY
melange index --arch "$architecture" --signing-key "$work_dir/test.rsa" \
  --output "$work_dir/repository/APKINDEX.tar.gz" \
  "$work_dir/repository/$apk_name"
if [[ -n "$runtime_gate" ]]; then
  "$runtime_gate" "$work_dir/repository" "$work_dir/test.rsa.pub" "$architecture"
fi

if ! current_source_sha=$(git rev-parse --verify HEAD) || \
  ! source_state=$(git status --porcelain --untracked-files=all); then
  printf 'cannot recheck source worktree\n' >&2
  exit 2
fi
if [[ "$current_source_sha" != "$source_sha" || -n "$source_state" || \
  "$(sha256sum "$recipe" | cut -d' ' -f1)" != "$recipe_sha256" ]]; then
  printf 'source changed during runtime validation\n' >&2
  exit 2
fi
stage_dir=$(mktemp -d "$root/.artifact.XXXXXX")
cp "${primary[0]}" "$stage_dir/$apk_name"
(
  cd "$stage_dir"
  sha256sum "$apk_name" > SHA256SUMS
)
jq -S -n \
  --arg architecture "$architecture" \
  --arg name "$package" \
  --arg version "$primary_version" \
  --arg recipe_path "$recipe" \
  --arg recipe_sha256 "$recipe_sha256" \
  --arg source_sha "$source_sha" \
  --arg unsigned_apk_sha256 "$unsigned_apk_sha256" \
  '{architecture:$architecture,identity:{name:$name,version:$version},recipe:{path:$recipe_path,sha256:$recipe_sha256},sourceSha:$source_sha,unsignedApkSha256:$unsigned_apk_sha256}' \
  > "$stage_dir/metadata.json"
mv "$stage_dir" artifact
stage_dir=
