#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*- helm-4=\([0-9][0-9.]*\)-r[0-9][0-9]*$/\1/p' \
  "$(dirname "$0")/../apko.yaml")
[ -n "$expected_version" ] || { printf 'Helm package version not found\n' >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/chart/templates" "$work/malformed"
cat >"$work/chart/Chart.yaml" <<'EOF'
apiVersion: v2
name: verity-smoke
version: 0.1.0
EOF
cat >"$work/chart/templates/configmap.yaml" <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .Release.Name }}
EOF
printf ': malformed\n' >"$work/malformed/Chart.yaml"
chmod -R a+rX "$work"

version=$(docker run --rm "$image" version --short)
case "$version" in
  "v${expected_version}"+*) ;;
  *)
    printf 'unexpected Helm version: %s\n' "$version" >&2
    exit 1
    ;;
esac

manifest=$(docker run --rm -v "$work:/work:ro" "$image" template verity /work/chart)
printf '%s\n' "$manifest" | grep -q 'kind: ConfigMap' || {
  printf 'rendered chart is missing ConfigMap\n' >&2
  exit 1
}

if docker run --rm -v "$work:/work:ro" "$image" template verity /work/missing >/dev/null 2>&1; then
  printf 'missing chart unexpectedly succeeded\n' >&2
  exit 1
fi

if docker run --rm -v "$work:/work:ro" "$image" template verity /work/malformed >/dev/null 2>&1; then
  printf 'malformed chart unexpectedly succeeded\n' >&2
  exit 1
fi

printf 'SMOKE PASS version=%s\n' "$version"
