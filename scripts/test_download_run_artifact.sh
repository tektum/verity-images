#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/payload" "$work/output"
printf 'current\n' > "$work/payload/result.json"
printf 'stale\n' > "$work/output/stale.json"
python3 - "$work/artifact.zip" "$work/payload/result.json" <<'PY'
import sys
from pathlib import Path
from zipfile import ZipFile

with ZipFile(sys.argv[1], "w") as archive:
    archive.write(Path(sys.argv[2]), "result.json")
PY

cat > "$work/bin/gh" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$GH_LOG"
case "$*" in
  *'/actions/runs/42/artifacts?per_page=100'*)
    cat <<'JSON'
[{"artifacts":[{"id":11,"name":"scan-example","expired":false,"created_at":"2026-09-20T01:00:00Z"},{"id":22,"name":"scan-example","expired":false,"created_at":"2026-09-20T02:00:00Z"},{"id":33,"name":"other","expired":false,"created_at":"2026-09-20T03:00:00Z"}]}]
JSON
    ;;
  *'/actions/artifacts/22/zip'*) cat "$ARTIFACT_ZIP" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$work/bin/gh"
export ARTIFACT_ZIP="$work/artifact.zip"
export GH_LOG="$work/gh.log"
PATH="$work/bin:$PATH" python3 "$root/scripts/download_run_artifact.py" \
  owner/repo 42 scan-example "$work/output"
[[ $(cat "$work/output/result.json") == current ]]
[[ ! -e "$work/output/stale.json" ]]
grep -Fq 'actions/artifacts/22/zip' "$GH_LOG"
PATH="$work/bin:$PATH" python3 "$root/scripts/download_run_artifact.py" \
  owner/repo 42 scan-example "$work/fresh-parent/output"
[[ $(cat "$work/fresh-parent/output/result.json") == current ]]
if grep -Fq 'actions/artifacts/11/zip' "$GH_LOG"; then
  printf 'older duplicate artifact was downloaded\n' >&2
  exit 1
fi
if PATH="$work/bin:$PATH" python3 "$root/scripts/download_run_artifact.py" \
  owner/repo 42 missing "$work/missing" 2>/dev/null; then
  printf 'missing artifact was accepted\n' >&2
  exit 1
fi
printf 'passed scripts/test_download_run_artifact.sh\n'
