#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
config="$(dirname "$0")/../apko.yaml"
version=$(sed -n 's/^    - kubebuilder=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
id=$$
volume="verity-kubebuilder-$id"
reader="verity-kubebuilder-read-$id"
work=$(mktemp -d)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  docker rm -f "$reader" >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

[ -n "$version" ] || fail 'could not read the pinned kubebuilder version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/kubebuilder"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

docker run --rm --network none "$image" version >"$work/version" 2>&1 ||
  fail 'version failed'
grep -E "^KubeBuilder: +v$version\$" "$work/version" >/dev/null ||
  fail "version does not report kubebuilder $version: $(cat "$work/version")"

rc=0
# The root command prints help for unknown flags; subcommands reject them.
docker run --rm --network none "$image" init --definitely-invalid >"$work/invalid" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid flag unexpectedly succeeded'
grep -F 'unknown flag: --definitely-invalid' "$work/invalid" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/invalid")"

# Scaffold a project with the kustomize plugin, which needs no Go toolchain or
# network. A fresh named volume inherits /work's 65532 ownership from the image.
docker volume create "$volume" >/dev/null
docker run --rm --network none --read-only --cap-drop=ALL -v "$volume:/work" "$image" \
  init --plugins kustomize/v2 --domain example.com --project-name verity >"$work/init.log" 2>&1 ||
  fail "init failed: $(cat "$work/init.log")"

docker create --name "$reader" -v "$volume:/work" "$image" >/dev/null
mkdir -p "$work/out"
docker cp "$reader:/work/." "$work/out/"
test -s "$work/out/PROJECT" || fail 'PROJECT was not written'
grep -Fx "cliVersion: $version" "$work/out/PROJECT" >/dev/null ||
  fail "PROJECT cliVersion mismatch: $(cat "$work/out/PROJECT")"
grep -Fx 'domain: example.com' "$work/out/PROJECT" >/dev/null ||
  fail "PROJECT domain mismatch: $(cat "$work/out/PROJECT")"
grep -Fx 'projectName: verity' "$work/out/PROJECT" >/dev/null ||
  fail "PROJECT name mismatch: $(cat "$work/out/PROJECT")"
grep -Fx -- '- kustomize.common.kubebuilder.io/v2' "$work/out/PROJECT" >/dev/null ||
  fail "PROJECT layout mismatch: $(cat "$work/out/PROJECT")"
grep -Fx 'version: "3"' "$work/out/PROJECT" >/dev/null ||
  fail "PROJECT config version mismatch: $(cat "$work/out/PROJECT")"
grep -Fx 'namespace: verity-system' "$work/out/config/default/kustomization.yaml" >/dev/null ||
  fail 'default kustomization namespace missing'
grep -Fx 'namePrefix: verity-' "$work/out/config/default/kustomization.yaml" >/dev/null ||
  fail 'default kustomization namePrefix missing'
for f in config/manager/manager.yaml config/rbac/role.yaml config/rbac/service_account.yaml; do
  test -s "$work/out/$f" || fail "$f was not scaffolded"
done
grep -F 'kind: Deployment' "$work/out/config/manager/manager.yaml" >/dev/null ||
  fail 'manager manifest is not a Deployment'

# Negative: a second init in the same project is refused.
rc=0
docker run --rm --network none -v "$volume:/work" "$image" \
  init --plugins kustomize/v2 --domain example.com --project-name verity >"$work/reinit.log" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'second init unexpectedly succeeded'
grep -F 'already initialized' "$work/reinit.log" >/dev/null ||
  fail "second init diagnostic is missing: $(cat "$work/reinit.log")"

# The image ships no Go toolchain: the default go/v4 plugin must fail with a
# clear missing-go error instead of writing a half-initialized Go project.
rc=0
docker run --rm --network none --tmpfs /work:rw,uid=65532,gid=65532 "$image" \
  init --domain example.com --repo example.com/verity --skip-go-version-check >"$work/goinit.log" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'go/v4 init without Go unexpectedly succeeded'
grep -F 'exec: "go": executable file not found in' "$work/goinit.log" >/dev/null ||
  fail "go/v4 init diagnostic is missing: $(cat "$work/goinit.log")"

printf 'SMOKE PASS image=%s\n' "$image"
