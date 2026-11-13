#!/bin/sh
set -eu

# Every container in this test runs with --network none: the smoke test has no
# GitGuardian API key and must never reach the GitGuardian API (or the GitHub
# release check). It asserts the offline behavior instead.

image=${1:?usage: test.sh IMAGE}
config="$(dirname "$0")/../apko.yaml"
version=$(sed -n 's/^    - ggshield=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
id=$$
hmsl="verity-ggshield-hmsl-$id"
work=$(mktemp -d)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  docker rm -f "$hmsl" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

[ -n "$version" ] || fail 'could not read the pinned ggshield version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/ggshield"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

docker run --rm --network none "$image" --version >"$work/version" 2>&1 ||
  fail 'version failed'
grep -Fx "ggshield, version $version" "$work/version" >/dev/null ||
  fail "version does not report ggshield $version: $(cat "$work/version")"

rc=0
docker run --rm --network none "$image" --definitely-invalid >"$work/invalid" 2>&1 || rc=$?
test "$rc" -eq 2 || fail "invalid flag exit code $rc, want 2"
grep -F "No such option '--definitely-invalid'" "$work/invalid" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/invalid")"

# The git integration needs git in the image.
docker run --rm --network none --entrypoint /usr/bin/git "$image" --version >"$work/git" 2>&1 ||
  fail "git is missing: $(cat "$work/git")"

mkdir -p "$work/scan"
# Example key from the AWS documentation, not a real credential.
printf 'aws_access_key_id = "AKIAIOSFODNN7EXAMPLE"\n' >"$work/scan/leak.txt"
chmod 755 "$work/scan"
chmod 644 "$work/scan/leak.txt"

# Without a key, a scan refuses up front, before any network access.
rc=0
docker run --rm --network none --read-only --cap-drop=ALL \
  --tmpfs /home/nonroot:rw,uid=65532,gid=65532 -v "$work/scan:/scan:ro" "$image" \
  secret scan path /scan/leak.txt >"$work/nokey" 2>&1 || rc=$?
test "$rc" -eq 3 || fail "keyless scan exit code $rc, want 3: $(cat "$work/nokey")"
grep -F 'A GitGuardian API key is needed to use ggshield.' "$work/nokey" >/dev/null ||
  fail "keyless scan diagnostic is missing: $(cat "$work/nokey")"

# With a placeholder key and an unreachable instance, the scan fails closed
# (it never reports a clean result it could not verify).
rc=0
timeout 120 docker run --rm --network none --read-only --cap-drop=ALL \
  --tmpfs /home/nonroot:rw,uid=65532,gid=65532 -v "$work/scan:/scan:ro" \
  -e GITGUARDIAN_API_KEY=verity-placeholder-not-a-key \
  -e GITGUARDIAN_INSTANCE=http://127.0.0.1:9 "$image" \
  --no-check-for-updates secret scan path /scan/leak.txt >"$work/offline" 2>&1 || rc=$?
test "$rc" -eq 4 || fail "unreachable-instance scan exit code $rc, want 4: $(cat "$work/offline")"
grep -F 'Failed to connect to GitGuardian server.' "$work/offline" >/dev/null ||
  fail "unreachable-instance diagnostic is missing: $(cat "$work/offline")"
grep -F "host='127.0.0.1', port=9" "$work/offline" >/dev/null ||
  fail "scan did not use the configured instance: $(cat "$work/offline")"
if grep -F 'No secrets have been found' "$work/offline" >/dev/null; then
  fail 'scan reported a clean result without reaching the API'
fi

# HasMySecretLeaked fingerprinting runs fully offline: it derives scrypt
# hashes locally and writes the payload and mapping files.
secret=verity-smoke-secret-$id
want=$(python3 - "$secret" <<'PY'
import hashlib
import sys

pepper = hashlib.sha256(b"GitGuardian").digest()
print(hashlib.scrypt(sys.argv[1].encode(), salt=pepper, n=2048, r=8, p=1, dklen=32).hex())
PY
)
docker create -i --name "$hmsl" --network none "$image" \
  hmsl fingerprint -n cleartext - >/dev/null
printf '%s\n' "$secret" | docker start -ai "$hmsl" >"$work/hmsl.log" 2>&1 ||
  fail "hmsl fingerprint failed: $(cat "$work/hmsl.log")"
grep -F 'Prepared 1 secrets.' "$work/hmsl.log" >/dev/null ||
  fail "hmsl fingerprint summary is missing: $(cat "$work/hmsl.log")"
docker cp "$hmsl:/work/mapping.txt" "$work/mapping.txt"
docker cp "$hmsl:/work/payload.txt" "$work/payload.txt"
grep -Fx "$want:$secret" "$work/mapping.txt" >/dev/null ||
  fail "hmsl mapping does not match the independent scrypt hash: $(cat "$work/mapping.txt")"
prefix=$(printf '%s' "$want" | cut -c1-5)
grep -Fx "$prefix" "$work/payload.txt" >/dev/null ||
  fail "hmsl payload is not the 5-character hash prefix: $(cat "$work/payload.txt")"
if grep -F "$secret" "$work/payload.txt" >/dev/null; then
  fail 'hmsl payload contains the cleartext secret'
fi

printf 'SMOKE PASS image=%s\n' "$image"
