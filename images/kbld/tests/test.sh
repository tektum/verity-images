#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
config="$here/../apko.yaml"
version=$(sed -n 's/^    - kbld=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
work=$(mktemp -d)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

[ -n "$version" ] || fail 'could not read the pinned kbld version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/kbld"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ||
  fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

docker run --rm --network none "$image" version >"$work/version" 2>&1 ||
  fail 'version failed'
grep -Fx "kbld version v$version" "$work/version" >/dev/null ||
  fail "version does not report kbld $version: $(cat "$work/version")"

rc=0
docker run --rm --network none "$image" definitely-invalid >"$work/invalid" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid command unexpectedly succeeded'
grep -F "does not accept extra arguments 'definitely-invalid'" "$work/invalid" >/dev/null ||
  fail "invalid command diagnostic is missing: $(cat "$work/invalid")"

digest_a=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
digest_b=sha256:fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210
mkdir -p "$work/in"
cat >"$work/in/app.yml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: smoke
spec:
  template:
    spec:
      containers:
      - name: pinned
        image: registry.example.invalid/pinned@$digest_a
      - name: app
        image: app
---
apiVersion: kbld.k14s.io/v1alpha1
kind: Config
overrides:
- image: app
  newImage: registry.example.invalid/team/app@$digest_b
  preresolved: true
EOF
chmod -R a+rX "$work/in"

# Digest references and preresolved overrides resolve offline; the output is
# the rewritten manifest with the kbld provenance annotation.
docker run --rm --network none --read-only --cap-drop=ALL \
  -v "$work/in:/in:ro" "$image" -f /in/app.yml >"$work/out.yml" 2>"$work/resolve.log" ||
  fail "resolve failed: $(cat "$work/resolve.log")"
grep -Fx "      - image: registry.example.invalid/team/app@$digest_b" "$work/out.yml" >/dev/null ||
  fail "override was not applied: $(cat "$work/out.yml")"
grep -Fx "      - image: registry.example.invalid/pinned@$digest_a" "$work/out.yml" >/dev/null ||
  fail "digest reference was not preserved: $(cat "$work/out.yml")"
grep -F 'kbld.k14s.io/images:' "$work/out.yml" >/dev/null ||
  fail 'kbld provenance annotation is missing'
if grep -F 'kind: Config' "$work/out.yml" >/dev/null; then
  fail 'kbld configuration leaked into the output manifest'
fi
if grep -E 'image: app$' "$work/out.yml" >/dev/null; then
  fail 'unresolved image reference left in the output'
fi
grep -F "resolve | final: app -> registry.example.invalid/team/app@$digest_b" "$work/resolve.log" >/dev/null ||
  fail "resolution log is missing the override: $(cat "$work/resolve.log")"

# A lock file records the resolution and can be fed back as configuration.
docker run --rm --network none --read-only --cap-drop=ALL \
  -v "$work/in:/in:ro" "$image" -f /in/app.yml --imgpkg-lock-output /dev/stdout \
  >"$work/lock.out" 2>/dev/null || fail 'imgpkg lock output failed'
grep -F 'kind: ImagesLock' "$work/lock.out" >/dev/null ||
  fail "imgpkg lock output is missing: $(cat "$work/lock.out")"

# Manifests on stdin work too, and tag references need registry access, so an
# offline run must fail with the resolution error rather than pass the tag through.
rc=0
printf 'kind: Pod\nspec:\n  containers:\n  - image: registry.example.invalid/app:1.0\n' |
  docker run -i --rm --network none "$image" -f - >"$work/tag.out" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'offline tag resolution unexpectedly succeeded'
grep -F "Resolving image 'registry.example.invalid/app:1.0'" "$work/tag.out" >/dev/null ||
  fail "missing tag resolution diagnostic: $(cat "$work/tag.out")"

rc=0
docker run --rm --network none "$image" -f /does/not/exist.yml >"$work/missing.out" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'missing input file unexpectedly succeeded'
grep -F '/does/not/exist.yml' "$work/missing.out" >/dev/null ||
  fail "missing input diagnostic: $(cat "$work/missing.out")"

echo 'SMOKE PASS'
