#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
python3 "$root/scripts/test_apk_repository.py"

recipe="$root/packages/openssl-fips-provider/melange.yaml"
grep -qx '  version: "3.1.2"' "$recipe"
grep -qx '  epoch: 3' "$recipe"
grep -qx '  source-commit: 17a2c5111864d8e016c5f2d29c40a3746b559e9d' "$recipe"
grep -qx '      expected-sha256: a0ce69b8b97ea6a35b96875235aa453b966ba3cba8af2de23657d8b6767d6539' "$recipe"
grep -qx '  certificate: "4985"' "$recipe"
if grep -R --include='*.yaml' --include='*.cnf*' -q 'fipsmodule.cnf' "$root/packages/openssl-fips-provider"; then
  exit 1
fi
grep -Fq "sha256sum \"\${{targets.destdir}}/usr/lib/ossl-modules/fips.so\"" "$recipe"
