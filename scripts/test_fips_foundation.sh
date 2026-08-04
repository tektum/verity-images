#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
helper="$root/scripts/test_fips.sh"

for version in $(find "$root/images/go" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -V); do
  config="$root/images/go/$version/fips.apko.yaml"
  [ -f "$config" ] || continue
  grep -Fxq '    - https://tektum.github.io/verity-images/apk' "$config"
  grep -Fxq '    - packages/keys/verity-apk-2026.rsa.pub' "$config"
  grep -Fxq '    - openssl-fips-provider=3.1.2-r3' "$config"
  grep -Fxq '  command: /usr/bin/go-fips-entrypoint' "$root/images/go/$version/fips-wrapper.apko.yaml"
  grep -Fxq 'exec openssl-fips-activate /usr/bin/go "$@"' "$root/images/go/$version/fips-entrypoint"
  grep -Fxq '  GOFIPS140: v1.0.0' "$config"
  grep -Fxq '  OPENSSL_FIPS_RUNTIME_DIR: /run/openssl-fips' "$config"
  jq -e '
    [.contents.packages[] | select(
      .name == "openssl-fips-provider" and
      .version == "3.1.2-r3" and
      (.url | startswith("https://tektum.github.io/verity-images/apk/"))
    )] | length == 2
  ' "$root/images/go/$version/fips.apko.lock.json" >/dev/null
done
for version in 3.3 4.0; do
  recipe="$root/images/ruby/$version/fips.melange.yaml"
  grep -Fxq '  dependencies:' "$recipe"
  grep -Fxq '    runtime:' "$recipe"
  grep -Fxq '      - busybox' "$recipe"
  grep -Fxq '      - openssl-fips-provider' "$recipe"
  grep -Fxq "      - ruby-$version" "$recipe"
done
httpd="$root/images/httpd"
grep -Fxq 'flavors: [plain, fips]' "$httpd/metadata.yaml"
grep -Fxq '    - https://tektum.github.io/verity-images/apk' "$httpd/fips.apko.yaml"
grep -Fxq '    - packages/keys/verity-apk-2026.rsa.pub' "$httpd/fips.apko.yaml"
grep -Fxq '    - openssl-fips-provider=3.1.2-r3' "$httpd/fips.apko.yaml"
grep -Fxq '  command: /usr/bin/openssl-fips-activate' "$httpd/fips.apko.yaml"
grep -Fxq 'cmd: /usr/local/bin/httpd-foreground' "$httpd/fips.apko.yaml"
grep -Fxq 'stop-signal: SIGWINCH' "$httpd/fips.apko.yaml"
grep -Fxq '  OPENSSL_FIPS_RUNTIME_DIR: /run/openssl-fips' "$httpd/fips.apko.yaml"
grep -Fxq '    permissions: 0o1777' "$httpd/fips.apko.yaml"
grep -Fq "docker logs \"\$container\" >&2 || true" "$httpd/tests/test.sh"
grep -Fq "docker logs \"\$tls_container\" >&2 || true" "$httpd/tests/test.sh"
[ "$(grep -Fc 'curl --fail --silent --connect-timeout 1 --max-time 5' "$httpd/tests/test.sh")" = 3 ]
jq -e '
  [.contents.packages[] | select(
    .name == "openssl-fips-provider" and
    .version == "3.1.2-r3" and
    (.url | startswith("https://tektum.github.io/verity-images/apk/")))
  ] | length == 2
' "$httpd/fips.apko.lock.json" >/dev/null
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
  *'fips.so:ro'*|*'--user 65532'*'mode=0500'*)
    exit 1
    ;;
  *'example:fips version'*)
    printf 'go version go1.26.5 linux/amd64\n'
    ;;
  *'example:fips env GOFIPS140'*)
    printf 'v1.0.0\n'
    ;;
  *'list -providers -verbose'*)
    printf '  fips\n    version: 3.1.2\n    status: active\n'
    ;;
  *'dgst -md5'*)
    exit 1
    ;;
  *'image inspect'*plain*|*'image inspect'*fips*)
    printf '%s\n' '65532|["serve"]|/data|{"80/tcp":{}}|{"/data":{}}'
    ;;
  *'example:fips')
    printf 'Go is a tool\n' >&2
    exit 2
    ;;
esac
EOF
chmod +x "$fake/docker"

PATH="$fake:$PATH" "$helper" provider example:fips
grep -q -- '--read-only' "$DOCKER_LOG"
grep -q -- '--tmpfs /run/openssl-fips' "$DOCKER_LOG"
grep -q 'OPENSSL_FIPS_RUNTIME_DIR=/run/openssl-fips' "$DOCKER_LOG"
grep -q -- '--entrypoint /usr/bin/openssl-fips-activate' "$DOCKER_LOG"
grep -q 'example:fips version' "$DOCKER_LOG"
grep -q 'example:fips env GOFIPS140' "$DOCKER_LOG"
grep -q -- '--entrypoint /usr/bin/go example:fips version' "$DOCKER_LOG"
grep -q 'list -providers -verbose' "$DOCKER_LOG"
grep -q 'dgst -sha256' "$DOCKER_LOG"
grep -q 'dgst -md5' "$DOCKER_LOG"
grep -q 'fips.so:ro' "$DOCKER_LOG"
grep -q -- '--user 65532.*mode=0500' "$DOCKER_LOG"
[ "$(grep -c -- '--entrypoint /usr/bin/openssl-fips-activate' "$DOCKER_LOG")" -ge 2 ]
PATH="$fake:$PATH" "$helper" compatibility example:plain example:fips
