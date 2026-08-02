#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
helper="$root/scripts/test_fips.sh"

for version in $(find "$root/images/go" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -V); do
  config="$root/images/go/$version/fips.apko.yaml"
  [ -f "$config" ] || continue
  grep -Fxq '    - https://tektum.github.io/verity-images/apk' "$config"
  grep -Fxq '    - packages/keys/verity-apk-2026.rsa.pub' "$config"
  grep -Fxq '    - openssl-fips-provider=3.1.2-r2' "$config"
  grep -Fxq '  GOFIPS140: v1.0.0' "$config"
  grep -Fxq '  OPENSSL_FIPS_RUNTIME_DIR: /run/openssl-fips' "$config"
  jq -e '
    [.contents.packages[] | select(
      .name == "openssl-fips-provider" and
      .version == "3.1.2-r2" and
      (.url | startswith("https://tektum.github.io/verity-images/apk/"))
    )] | length == 2
  ' "$root/images/go/$version/fips.apko.lock.json" >/dev/null
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
  *'mode=0500'*)
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
