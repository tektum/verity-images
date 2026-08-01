#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
recipe="$root/packages/openssl-fips-provider/melange.yaml"
config="$root/packages/openssl-fips-provider/openssl-fips.cnf.in"
activate="$root/packages/openssl-fips-provider/openssl-fips-activate"
helper="$root/scripts/test_fips.sh"

grep -q 'version: "3.1.2"' "$recipe"
grep -q 'source-commit: 17a2c5111864d8e016c5f2d29c40a3746b559e9d' "$recipe"
grep -q 'certificate: "4985"' "$recipe"
grep -q 'expected-sha256: a0ce69b8b97ea6a35b96875235aa453b966ba3cba8af2de23657d8b6767d6539' "$recipe"
grep -q 'target-architecture:' "$recipe"
grep -q '  - x86_64' "$recipe"
grep -q '  - aarch64' "$recipe"
grep -q '      - busybox' "$recipe"
grep -q 'openssl-fips-activate' "$recipe"
grep -q 'openssl-fips.cnf.in' "$recipe"
if grep -q 'fipsmodule.cnf' "$recipe"; then
  exit 1
fi
if grep -q 'uses: patch' "$recipe"; then
  exit 1
fi

grep -q '^config_diagnostics = 1$' "$config"
grep -q '^activate = 1$' "$config"
grep -q '^default_properties = fips=yes$' "$config"
grep -q '^\.include @FIPSMODULE@$' "$config"
grep -q 'OPENSSL_FIPS_RUNTIME_DIR' "$activate"
grep -q 'mktemp -d' "$activate"
grep -q 'fipsinstall' "$activate"
grep -q -- '-verify' "$activate"
grep -q 'exec "$@"' "$activate"
grep -q 'packages/openssl-fips-provider' "$root/.github/actions/publish-image/action.yaml"

for version in 1.25 1.26; do
  diff -u \
    "$root/images/go/$version/apko.yaml" \
    <(grep -v 'GOFIPS140:' "$root/images/go/$version/fips.apko.yaml")
  grep -q 'GOFIPS140: v1.0.0' "$root/images/go/$version/fips.apko.yaml"
done
[ "$(cat "$root/images/caddy/fips.env")" = 'GOFIPS140=v1.0.0' ]
[ "$(find "$root/images/caddy" -maxdepth 1 -name 'melange.yaml' | wc -l)" -eq 1 ]

fake=$(mktemp -d)
trap 'rm -rf "$fake"' EXIT
export DOCKER_LOG="$fake/docker.log"
cat >"$fake/docker" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$DOCKER_LOG"
case "$*" in
  create*)
    printf '%s\n' test-container
    ;;
  cp*)
    destination=${3:?}
    printf 'module' >"$destination"
    ;;
  *'/usr/bin/printf'*)
    printf 'a b|c'
    ;;
  *'list -providers -verbose'*)
    printf '  fips\n    version: 3.1.2\n    status: active\n'
    ;;
  *'dgst -md5'*)
    exit 1
    ;;
  *'fips.so:ro'*)
    exit 1
    ;;
  *'image inspect'*plain*|*'image inspect'*fips*)
    printf '%s\n' '65532|["/usr/bin/app"]|["serve"]|/data|{"80/tcp":{}}|{"/data":{}}'
    ;;
esac
EOF
chmod +x "$fake/docker"

PATH="$fake:$PATH" "$helper" provider example:fips
grep -q -- '--read-only' "$DOCKER_LOG"
grep -q -- '--tmpfs /run/openssl-fips' "$DOCKER_LOG"
grep -q 'OPENSSL_FIPS_RUNTIME_DIR=/run/openssl-fips' "$DOCKER_LOG"
grep -q -- '--entrypoint /usr/bin/openssl-fips-activate' "$DOCKER_LOG"
grep -q 'list -providers -verbose' "$DOCKER_LOG"
grep -q 'dgst -sha256' "$DOCKER_LOG"
grep -q 'dgst -md5' "$DOCKER_LOG"
grep -q 'fips.so:ro' "$DOCKER_LOG"
[ "$(grep -c -- '--entrypoint /usr/bin/openssl-fips-activate' "$DOCKER_LOG")" -ge 4 ]
PATH="$fake:$PATH" "$helper" compatibility example:plain example:fips
