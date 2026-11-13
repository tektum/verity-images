#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^    - upx=\([0-9][0-9.]*\)-r[0-9]*$/\1/p' \
  "$(dirname "$0")/../apko.yaml")
[ -n "$expected_version" ] || { printf '%s\n' 'upx package pin not found' >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

run() {
  timeout 120 docker run --rm --network none -v "$work:/work" "$@"
}

user=$(docker image inspect -f '{{.Config.User}}' "$image")
[ "$user" = 65532 ] || fail "image user is $user, want 65532"
entrypoint=$(docker image inspect -f '{{json .Config.Entrypoint}} {{json .Config.Cmd}}' "$image")
[ "$entrypoint" = '["/usr/bin/upx"] null' ] || fail "unexpected entrypoint: $entrypoint"
workdir=$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")
[ "$workdir" = /work ] || fail "unexpected working directory: $workdir"

chmod 0777 "$work"
version=$(run "$image" --version 2>&1 | sed -n 1p)
[ "$version" = "upx $expected_version" ] || fail "unexpected version '$version', want upx $expected_version"

# Use the image's own upx binary as the input executable.
created=$(docker create "$image")
docker cp "$created:/usr/bin/upx" "$work/original" >/dev/null || { docker rm "$created" >/dev/null; fail 'cannot copy /usr/bin/upx'; }
docker rm "$created" >/dev/null
chmod 0755 "$work/original"
original_size=$(wc -c <"$work/original")

run "$image" -q --best -o /work/packed /work/original >"$work/pack.txt" 2>&1 ||
  { cat "$work/pack.txt" >&2; fail 'upx failed to pack an ELF executable'; }
packed_size=$(wc -c <"$work/packed")
[ "$packed_size" -lt "$original_size" ] ||
  fail "packed size $packed_size is not smaller than original size $original_size"

run "$image" -t /work/packed >"$work/test.txt" 2>&1 ||
  { cat "$work/test.txt" >&2; fail 'upx -t rejected the packed file'; }
grep -F 'testing /work/packed [OK]' "$work/test.txt" >/dev/null ||
  { cat "$work/test.txt" >&2; fail 'upx -t did not report OK'; }

run "$image" -l /work/packed >"$work/list.txt" 2>&1 ||
  { cat "$work/list.txt" >&2; fail 'upx -l failed on the packed file'; }
grep -E "^ +$original_size +-> +$packed_size +[0-9.]+% +linux/" "$work/list.txt" >/dev/null ||
  { cat "$work/list.txt" >&2; fail 'upx -l does not list the packed sizes'; }

# The packed executable must still run and self-decompress.
packed_version=$(run --entrypoint /work/packed "$image" --version 2>&1 | sed -n 1p)
[ "$packed_version" = "upx $expected_version" ] || fail "packed executable printed '$packed_version'"

run "$image" -q -d -o /work/unpacked /work/packed >"$work/unpack.txt" 2>&1 ||
  { cat "$work/unpack.txt" >&2; fail 'upx failed to unpack'; }
cmp -s "$work/original" "$work/unpacked" || fail 'unpacked executable differs from the original'

# Negative cases: a non-executable input, a file that is not packed, an unknown option.
awk 'BEGIN { for (i = 0; i < 4096; i++) print "not an executable", i }' >"$work/plain.txt"
chmod 0644 "$work/plain.txt"
if run "$image" -o /work/plain.packed /work/plain.txt >"$work/neg1.txt" 2>&1; then
  fail 'upx packed a text file'
fi
grep -F 'UnknownExecutableFormatException' "$work/neg1.txt" >/dev/null ||
  { cat "$work/neg1.txt" >&2; fail 'text file rejection does not name the reason'; }
if run "$image" -d -o /work/original.unpacked /work/original >"$work/neg2.txt" 2>&1; then
  fail 'upx unpacked a file that was not packed'
fi
grep -F 'NotPackedException' "$work/neg2.txt" >/dev/null ||
  { cat "$work/neg2.txt" >&2; fail 'unpacked input rejection does not say not packed'; }
if run "$image" --no-such-option /work/original >"$work/neg3.txt" 2>&1; then
  fail 'unknown option was accepted'
fi
grep -F 'no-such-option' "$work/neg3.txt" >/dev/null ||
  { cat "$work/neg3.txt" >&2; fail 'unknown option error does not name the option'; }

printf '%s\n' "upx $expected_version smoke test passed"
