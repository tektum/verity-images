#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
work=$(mktemp -d)

cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

# The conda release comes from the reviewed lock, so a lock refresh needs no
# test edit.
expected_version=$(jq -r '[.contents.packages[] | select(.name == "py3.12-conda") | .version]
  | unique | if length == 1 then .[0] | sub("-r[0-9]+$"; "") else empty end' \
  "$here/../apko.lock.json")
[ -n "$expected_version" ] || fail 'could not read the locked py3.12-conda version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/python3.12","-m","conda"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/nonroot ||
  fail 'unexpected working directory'

# conda ARGS...: run the image offline with a read-only root filesystem.
conda() {
  docker run --rm --network none --read-only --tmpfs /tmp \
    --tmpfs /home/nonroot:uid=65532,gid=65532,mode=0755 "$image" "$@"
}

version=$(conda --version) || fail 'conda --version failed'
[ "$version" = "conda $expected_version" ] ||
  fail "conda --version printed '$version', expected 'conda $expected_version'"

# Negative: unknown flags and subcommands fail.
if conda --definitely-invalid >"$work/invalid" 2>&1; then
  fail 'unknown flag unexpectedly succeeded'
fi
grep -F 'conda: error:' "$work/invalid" >/dev/null ||
  fail 'unknown flag diagnostic is missing'
if conda definitely-not-a-command >"$work/invalid-cmd" 2>&1; then
  fail 'unknown subcommand unexpectedly succeeded'
fi
grep -F "invalid choice: 'definitely-not-a-command'" "$work/invalid-cmd" >/dev/null ||
  fail 'unknown subcommand diagnostic is missing'

conda info --json >"$work/info.json" || fail 'conda info --json failed'
jq -e --arg v "$expected_version" '.conda_version == $v' "$work/info.json" >/dev/null ||
  fail 'conda info reports another version'
jq -e '.channels | length > 0 and all(test("/conda-forge/"))' "$work/info.json" >/dev/null ||
  fail "channels are not conda-forge only: $(jq -c .channels "$work/info.json")"
jq -e '[.channels[] | select(test("repo.anaconda.com|/pkgs/main"))] | length == 0' \
  "$work/info.json" >/dev/null || fail 'the Anaconda defaults channel is configured'
jq -e '.root_writable == false and (.envs_dirs | index("/home/nonroot/.conda/envs") != null)' \
  "$work/info.json" >/dev/null || fail 'environments are not created under the user home'

conda config --show channel_priority >"$work/priority" || fail 'conda config failed'
grep -Fx 'channel_priority: strict' "$work/priority" >/dev/null ||
  fail 'channel priority is not strict'

# Create, list, use and remove an environment without network access. The
# environment lives in the user's home on a tmpfs, so one container runs the
# whole sequence through the conda module.
docker run --rm --network none --read-only --tmpfs /tmp \
  --tmpfs /home/nonroot:uid=65532,gid=65532,mode=0755 \
  --entrypoint /bin/sh "$image" -euc '
    c() { /usr/bin/python3.12 -m conda "$@"; }
    c create --yes --quiet --offline --name smoke >/dev/null
    c env list --json >/tmp/envs.json
    grep -F "/home/nonroot/.conda/envs/smoke" /tmp/envs.json >/dev/null
    test -f /home/nonroot/.conda/envs/smoke/conda-meta/history
    prefix=$(c run --name smoke sh -c "printf %s \"\$CONDA_PREFIX\"")
    test "$prefix" = /home/nonroot/.conda/envs/smoke
    test "$(c list --name smoke --json | tr -d "[:space:]")" = "[]"
    c env remove --yes --quiet --name smoke >/dev/null
    test ! -e /home/nonroot/.conda/envs/smoke
  ' >"$work/env.log" 2>&1 || {
  cat "$work/env.log" >&2
  fail 'offline environment lifecycle failed'
}

# Negative: installing a package offline from an empty cache fails cleanly.
if conda create --yes --offline --name needs-network python >"$work/offline" 2>&1; then
  fail 'offline install of an uncached package succeeded'
fi
grep -E 'PackagesNotFoundError|not available from current channels' "$work/offline" >/dev/null ||
  fail "unexpected offline install diagnostic: $(tail -n 5 "$work/offline")"

echo "conda $expected_version smoke test passed"
