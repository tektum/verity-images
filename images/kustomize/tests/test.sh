#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
config="$here/../apko.yaml"
version=$(sed -n 's/^    - kustomize=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
work=$(mktemp -d)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

[ -n "$version" ] || fail 'could not read the pinned kustomize version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/kustomize"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ||
  fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

run() {
  docker run --rm --network none --read-only --cap-drop=ALL \
    -v "$work/config:/work:ro" "$image" "$@"
}

docker run --rm --network none "$image" version >"$work/version" 2>&1 ||
  fail 'version failed'
grep -Fx "$version" "$work/version" >/dev/null ||
  fail "version does not report $version: $(cat "$work/version")"

rc=0
docker run --rm --network none "$image" --definitely-invalid >"$work/invalid" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid flag unexpectedly succeeded'
grep -F 'unknown flag: --definitely-invalid' "$work/invalid" >/dev/null ||
  fail 'invalid flag diagnostic is missing'

# A base and an overlay: the overlay adds a name prefix and a label, retags the
# image and patches the replica count of the base Deployment.
mkdir -p "$work/config/base" "$work/config/overlay" "$work/config/empty"
cat >"$work/config/base/deployment.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 1
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
        - name: web
          image: example.com/web:1.0.0
EOF
cat >"$work/config/base/kustomization.yaml" <<'EOF'
resources:
  - deployment.yaml
EOF
cat >"$work/config/overlay/replicas.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 3
EOF
cat >"$work/config/overlay/kustomization.yaml" <<'EOF'
namePrefix: prod-
labels:
  - pairs:
      env: prod
resources:
  - ../base
patches:
  - path: replicas.yaml
images:
  - name: example.com/web
    newTag: 2.0.0
EOF
chmod -R a+rX "$work/config"

# Render on a read-only root with no capabilities and no network.
run build overlay >"$work/rendered" 2>"$work/build.err" ||
  fail "build failed: $(cat "$work/build.err")"
grep -Fx '  name: prod-web' "$work/rendered" >/dev/null || fail 'name prefix was not applied'
grep -Fx '  replicas: 3' "$work/rendered" >/dev/null || fail 'replica patch was not applied'
grep -Fx '      - image: example.com/web:2.0.0' "$work/rendered" >/dev/null ||
  fail 'image tag was not replaced'
grep -Fx '    env: prod' "$work/rendered" >/dev/null || fail 'label was not added'
grep -F 'replicas: 1' "$work/rendered" >/dev/null && fail 'base replica count leaked through'

# The base alone still renders unchanged.
run build base >"$work/base" 2>&1 || fail "base build failed: $(cat "$work/base")"
grep -Fx '  name: web' "$work/base" >/dev/null || fail 'base name changed'
grep -Fx '  replicas: 1' "$work/base" >/dev/null || fail 'base replica count changed'

# Negative: a directory without a kustomization fails with its diagnostic.
rc=0
run build empty >"$work/empty" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'build of an empty directory unexpectedly succeeded'
grep -F "unable to find one of 'kustomization.yaml'" "$work/empty" >/dev/null ||
  fail "empty build diagnostic is missing: $(cat "$work/empty")"

echo 'SMOKE PASS'
