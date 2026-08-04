#!/bin/bash
set -euo pipefail

repository=${1:?usage: verify_apk_repository.sh REPOSITORY KEY}
key=${2:?usage: verify_apk_repository.sh REPOSITORY KEY}
resolved_key=$(realpath "$key")
key_name=$(basename "$resolved_key")
package_paths=$(
  python3 - "$repository/manifest.json" <<'PY'
import json
import pathlib
import sys

manifest = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
packages = manifest.get("packages") if isinstance(manifest, dict) else None
if not isinstance(packages, list):
    raise SystemExit("invalid manifest packages")
for package in packages:
    path = package.get("path") if isinstance(package, dict) else None
    candidate = pathlib.PurePosixPath(path) if isinstance(path, str) else None
    if candidate is None or candidate.is_absolute() or ".." in candidate.parts or str(candidate) in {"", "."}:
        raise SystemExit("unsafe manifest path")
    print(f"/repository/{candidate}")
PY
)
[[ -n "$package_paths" ]]
mapfile -t packages <<<"$package_paths"
((${#packages[@]}))

docker run --rm \
  -v "$(realpath "$repository"):/repository:ro" \
  -v "$(dirname "$resolved_key"):/keys:ro" \
  cgr.dev/chainguard/wolfi-base@sha256:003627df3c1e1bba0c4116afcddb314aca9594ee2328c7e876a8081a6c988b2e \
  sh -ec '
    keys=$(mktemp -d)
    cp "/keys/$1" "$keys/$1"
    shift
    apk --keys-dir "$keys" verify \
      /repository/x86_64/APKINDEX.tar.gz \
      /repository/aarch64/APKINDEX.tar.gz \
      "$@"
  ' sh "$key_name" "${packages[@]}"
