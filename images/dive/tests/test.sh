#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

dive() {
  docker run --rm --network none -v "$work:/work:ro" "$image" "$@"
}

user=$(docker image inspect -f '{{.Config.User}}' "$image")
test "$user" = 65532 || fail "image user is $user, want 65532"
entrypoint=$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")
test "$entrypoint" = '["/usr/bin/dive"]' || fail "unexpected entrypoint: $entrypoint"

version=$(dive --version)
printf '%s\n' "$version" | grep -Eq '^dive 0\.13\.[0-9]+$' \
  || fail "unexpected version output: $version"

if dive --no-such-flag >/dev/null 2>&1; then
  fail 'unknown flag was accepted'
fi

# Hand-built docker-archive: two layers write different 64 KiB contents to one
# path, so the second layer wastes the first.
mkdir -p "$work/one" "$work/two" "$work/archive/l1" "$work/archive/l2"
head -c 65536 /dev/zero >"$work/one/payload"
head -c 65536 /dev/zero | tr '\000' x >"$work/two/payload"
tar -C "$work/one" --owner=0 --group=0 -cf "$work/archive/l1/layer.tar" payload
tar -C "$work/two" --owner=0 --group=0 -cf "$work/archive/l2/layer.tar" payload
diff1=$(sha256sum "$work/archive/l1/layer.tar" | cut -d' ' -f1)
diff2=$(sha256sum "$work/archive/l2/layer.tar" | cut -d' ' -f1)
printf '%s' '{"architecture":"amd64","os":"linux","config":{},' \
  '"rootfs":{"type":"layers","diff_ids":["sha256:'"$diff1"'","sha256:'"$diff2"'"]},' \
  '"history":[{"created_by":"write payload"},{"created_by":"overwrite payload"}]}' \
  >"$work/archive/config.json"
printf '%s' '[{"Config":"config.json","RepoTags":["verity/dive-fixture:latest"],' \
  '"Layers":["l1/layer.tar","l2/layer.tar"]}]' >"$work/archive/manifest.json"
tar -C "$work/archive" -cf "$work/fixture.tar" manifest.json config.json l1 l2
chmod -R a+rX "$work"

output=$(dive --ci --source docker-archive /work/fixture.tar \
  --lowestEfficiency=0 --highestWastedBytes=disabled --highestUserWastedPercent=disabled 2>&1) \
  || fail "relaxed CI rules failed: $output"
printf '%s\n' "$output" | grep -q 'Result:PASS' || fail "missing PASS result: $output"
printf '%s\n' "$output" | grep -q 'wastedBytes: 131072 bytes' \
  || fail "unexpected wasted bytes: $output"
printf '%s\n' "$output" | grep -Eq '^ *2 +131 kB +/payload$' \
  || fail "overwritten /payload not reported: $output"

set +e
output=$(dive --ci --source docker-archive /work/fixture.tar \
  --lowestEfficiency=0 --highestWastedBytes=1KB --highestUserWastedPercent=disabled 2>&1)
status=$?
set -e
test "$status" -ne 0 || fail "wasted-bytes rule did not fail: $output"
printf '%s\n' "$output" | grep -q 'highestWastedBytes: too many bytes wasted (wasted-bytes=131072 > threshold=1000)' \
  || fail "missing highestWastedBytes failure: $output"
printf '%s\n' "$output" | grep -q 'Result:FAIL' || fail "missing FAIL result: $output"

if dive --ci --source docker-archive /work/missing.tar >/dev/null 2>&1; then
  fail 'missing archive was accepted'
fi

printf 'SMOKE PASS image=%s\n' "$image"
