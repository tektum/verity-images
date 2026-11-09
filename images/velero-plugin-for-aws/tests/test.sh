#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
work=$(mktemp -d)

trap 'rm -rf "$work"' EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

plugin=/plugins/velero-plugin-for-aws

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/cp-plugin","/plugins/velero-plugin-for-aws","/target/velero-plugin-for-aws"]' ||
  fail 'unexpected entrypoint'

uid=$(docker run --rm --network none --read-only --entrypoint /bin/id "$image" -u)
test "$uid" = 65532 || fail "container runs as uid $uid, want 65532"

expected=$(docker run --rm --network none --read-only --entrypoint /bin/sha256sum \
  "$image" "$plugin" | cut -d ' ' -f 1)
test -n "$expected" || fail 'plugin binary checksum is empty'

# Default init-container entrypoint, as `velero install --plugins` runs it.
mkdir "$work/default"
chmod 0777 "$work/default"
docker run --rm --network none --read-only -v "$work/default:/target" "$image" \
  >"$work/default.log" 2>&1 || {
  cat "$work/default.log" >&2
  fail 'default entrypoint failed to install the plugin'
}
grep -F "Copying $plugin to /target/velero-plugin-for-aws" "$work/default.log" >/dev/null ||
  fail 'default entrypoint did not report the copy'
test -f "$work/default/velero-plugin-for-aws" || fail 'plugin missing from target'
test -x "$work/default/velero-plugin-for-aws" || fail 'installed plugin is not executable'

# Generic init-container contract: cp /plugins/* /target/.
mkdir "$work/cp"
chmod 0777 "$work/cp"
docker run --rm --network none --read-only -v "$work/cp:/target" --entrypoint /bin/sh \
  "$image" -c 'cp /plugins/* /target/' || fail 'cp /plugins/* /target/ failed'
test -f "$work/cp/velero-plugin-for-aws" || fail 'cp contract did not copy the plugin'
test -x "$work/cp/velero-plugin-for-aws" || fail 'cp contract plugin is not executable'

for dir in default cp; do
  actual=$(docker run --rm --network none --read-only -v "$work/$dir:/target:ro" \
    --entrypoint /bin/sha256sum "$image" /target/velero-plugin-for-aws | cut -d ' ' -f 1)
  test "$actual" = "$expected" || fail "$dir copy differs from the shipped plugin"
done

# The copied binary is the real Velero plugin: run outside Velero, it refuses.
if docker run --rm --network none --read-only -v "$work/default:/target:ro" \
  --entrypoint /target/velero-plugin-for-aws "$image" >"$work/plugin.log" 2>&1; then
  fail 'plugin unexpectedly ran outside Velero'
fi
grep -F 'This binary is a plugin' "$work/plugin.log" >/dev/null ||
  fail 'copied binary is not a Velero plugin'

# Without a writable target the init container must fail, not succeed silently.
if docker run --rm --network none --read-only "$image" >"$work/missing.log" 2>&1; then
  fail 'missing /target unexpectedly succeeded'
fi
grep -F 'Error: failed to create destination file /target/velero-plugin-for-aws' \
  "$work/missing.log" >/dev/null || fail 'missing target diagnostic is missing'

printf 'SMOKE PASS image=%s\n' "$image"
