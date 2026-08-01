#!/bin/bash
set -euo pipefail

input=${1:?usage: assemble-apk-repository.sh INPUT OUTPUT KEY FINGERPRINT}
output=${2:?usage: assemble-apk-repository.sh INPUT OUTPUT KEY FINGERPRINT}
key=${3:?usage: assemble-apk-repository.sh INPUT OUTPUT KEY FINGERPRINT}
fingerprint=${4:?usage: assemble-apk-repository.sh INPUT OUTPUT KEY FINGERPRINT}

rm -rf "$output"
mkdir -p "$output"
for arch in x86_64 aarch64; do
  mkdir -p "$output/$arch"
  mapfile -t packages < <(find "$input/$arch" -maxdepth 1 -type f -name '*.apk' -print | sort)
  ((${#packages[@]}))
  cp "${packages[@]}" "$output/$arch/"
  melange index --arch "$arch" --signing-key "$key" --output "$output/$arch/APKINDEX.tar.gz" "$output/$arch"/*.apk
done
python3 - "$output" "$fingerprint" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
packages = []
for archive in sorted(root.glob('*/*.apk')):
    packages.append({'architecture': archive.parent.name, 'path': archive.relative_to(root).as_posix(), 'sha256': hashlib.sha256(archive.read_bytes()).hexdigest()})
(root / 'manifest.json').write_text(json.dumps({'architectures': ['x86_64', 'aarch64'], 'fingerprint': sys.argv[2], 'packages': packages}, sort_keys=True), encoding='utf-8')
PY
