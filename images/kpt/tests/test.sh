#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
volume="verity-kpt-$$"
work=$(mktemp -d)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  docker volume rm "$volume" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

recipe_value() {
  awk -v key="$1" '$1 == key { gsub(/"/, "", $2); print $2; exit }' "$here/../melange.yaml"
}
expected_version=$(recipe_value version:)
expected_commit=$(recipe_value source-commit:)
[ -n "$expected_version" ] && [ -n "$expected_commit" ] || fail 'could not read the recipe'

test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/kpt"]' ||
  fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 || fail 'unexpected OCI user'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

# Every run is offline on a read-only root filesystem; packages live on a
# volume that the image's /work initializes for the nonroot user.
docker volume create "$volume" >/dev/null
run() {
  docker run --rm --network none --read-only --cap-drop=ALL --security-opt no-new-privileges \
    --tmpfs /tmp --tmpfs /home/nonroot:uid=65532,gid=65532 -v "$volume:/work" "$@"
}
kpt() {
  run "$image" "$@"
}
shell() {
  run --entrypoint /bin/sh "$image" -euc "$1"
}

kpt version >"$work/version" 2>&1 || fail "kpt version failed: $(cat "$work/version")"
grep -Fx "Version: $expected_version" "$work/version" >/dev/null || fail "unexpected version: $(cat "$work/version")"
grep -F "Git commit: $expected_commit" "$work/version" >/dev/null ||
  fail "unexpected commit: $(cat "$work/version")"

status=0
kpt definitely-invalid >"$work/invalid" 2>&1 || status=$?
test "$status" -ne 0 || fail 'an unknown subcommand succeeded'

# An upstream package in a local git repository, tagged nginx/v1.
kpt pkg init /work/upstream/nginx --description 'Verity smoke package' >"$work/init" 2>&1 ||
  fail "pkg init failed: $(cat "$work/init")"
shell '
  mkdir /work/consumer
  cd /work/upstream
  cat >nginx/deploy.yaml <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
spec:
  replicas: 1
EOF
  git init -q -b main
  git add -A
  git -c user.email=smoke@verity.invalid -c user.name=smoke commit -qm v1
  git tag nginx/v1
' || fail 'could not create the upstream repository'

# pkg get clones it through git and records the upstream lock.
kpt pkg get /work/upstream.git/nginx@nginx/v1 /work/consumer/nginx >"$work/get" 2>&1 ||
  fail "pkg get failed: $(cat "$work/get")"
v1=$(run --entrypoint /usr/bin/git "$image" -C /work/upstream rev-parse nginx/v1)
shell 'cat /work/consumer/nginx/Kptfile' >"$work/Kptfile"
grep -F 'updateStrategy: resource-merge' "$work/Kptfile" >/dev/null || fail 'Kptfile has no update strategy'
grep -F "commit: $v1" "$work/Kptfile" >/dev/null || fail "Kptfile does not lock $v1: $(cat "$work/Kptfile")"
kpt pkg tree /work/consumer/nginx >"$work/tree" 2>&1 || fail "pkg tree failed: $(cat "$work/tree")"
grep -F '[deploy.yaml]  Deployment nginx' "$work/tree" >/dev/null || fail "unexpected tree: $(cat "$work/tree")"

# A local edit and an upstream change (nginx/v2) merge on pkg update.
shell '
  cd /work/upstream
  sed -i "s/replicas: 1/replicas: 3/" nginx/deploy.yaml
  git -c user.email=smoke@verity.invalid -c user.name=smoke commit -qam v2
  git tag nginx/v2
  sed -i "s/^  name: nginx\$/  name: nginx\n  labels:\n    team: smoke/" /work/consumer/nginx/deploy.yaml
  grep -F "team: smoke" /work/consumer/nginx/deploy.yaml >/dev/null
' || fail 'could not create the upstream and local changes'
run -w /work/consumer "$image" pkg update nginx@nginx/v2 >"$work/update" 2>&1 ||
  fail "pkg update failed: $(cat "$work/update")"
grep -F 'Updated 1 package(s).' "$work/update" >/dev/null || fail "unexpected update output: $(cat "$work/update")"
v2=$(run --entrypoint /usr/bin/git "$image" -C /work/upstream rev-parse nginx/v2)
shell 'cat /work/consumer/nginx/deploy.yaml' >"$work/deploy.yaml"
grep -F 'replicas: 3' "$work/deploy.yaml" >/dev/null || fail "upstream change was not merged: $(cat "$work/deploy.yaml")"
grep -F 'team: smoke' "$work/deploy.yaml" >/dev/null || fail "local change was lost: $(cat "$work/deploy.yaml")"
shell 'cat /work/consumer/nginx/Kptfile' >"$work/Kptfile"
grep -F "commit: $v2" "$work/Kptfile" >/dev/null || fail "Kptfile does not lock $v2: $(cat "$work/Kptfile")"

printf 'SMOKE PASS image=%s version=%s\n' "$image" "$expected_version"
