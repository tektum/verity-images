#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
recipe="$here/../melange.yaml"
version=$(sed -n 's/^  version: "\([0-9.]*\)".*/\1/p' "$recipe")
commit=$(sed -n 's/^  source-commit: \([0-9a-f]*\)$/\1/p' "$recipe")
work=$(mktemp -d)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

[ -n "$version" ] || fail 'could not read the recipe version'
[ -n "$commit" ] || fail 'could not read the recipe source commit'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/skaffold"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ||
  fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

# Offline on a read-only root with no capabilities; skaffold keeps its state
# under a tmpfs home and the project is mounted read-only.
run() {
  docker run --rm --network none --read-only --cap-drop=ALL \
    --tmpfs /home/nonroot:uid=65532,gid=65532,mode=0755 --tmpfs /tmp:mode=1777 \
    -e SKAFFOLD_UPDATE_CHECK=false -e SKAFFOLD_COLLECT_METRICS=false \
    -v "$work/project:/work:ro" "$image" "$@"
}

mkdir -p "$work/project/k8s"
chmod 755 "$work/project" "$work/project/k8s"

run version >"$work/version" 2>&1 || fail "version failed: $(cat "$work/version")"
grep -Fx "v$version" "$work/version" >/dev/null ||
  fail "version does not report v$version: $(cat "$work/version")"

rc=0
run --definitely-invalid >"$work/invalid" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid flag unexpectedly succeeded'
grep -F 'unknown flag: --definitely-invalid' "$work/invalid" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/invalid")"

run schema list >"$work/schemas" 2>&1 || fail "schema list failed: $(cat "$work/schemas")"
grep -Fx 'skaffold/v4beta14' "$work/schemas" >/dev/null ||
  fail "schema list lacks the current schema: $(cat "$work/schemas")"

rc=0
run render >"$work/noconfig" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'render without a skaffold.yaml unexpectedly succeeded'
grep -F 'skaffold.yaml' "$work/noconfig" >/dev/null ||
  fail "missing config diagnostic is missing: $(cat "$work/noconfig")"

cat >"$work/project/k8s/deployment.yaml" <<'EOF'
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
          image: example.com/web
EOF
cat >"$work/project/k8s/service.yaml" <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  selector:
    app: web
  ports:
    - port: 80
EOF
# The prod profile adds the Service and patches the replica count.
cat >"$work/project/skaffold.yaml" <<'EOF'
apiVersion: skaffold/v4beta14
kind: Config
metadata:
  name: shop
build:
  artifacts:
    - image: example.com/web
manifests:
  rawYaml:
    - k8s/deployment.yaml
profiles:
  - name: prod
    patches:
      - op: add
        path: /manifests/rawYaml/-
        value: k8s/service.yaml
EOF
cat >"$work/project/Dockerfile" <<'EOF'
FROM scratch
COPY k8s /k8s
EOF
chmod 644 "$work/project/k8s"/* "$work/project/skaffold.yaml" "$work/project/Dockerfile"

# diagnose reports the build commit, as upstream does, and walks the artifact's
# Docker build context without a Docker daemon.
run diagnose >"$work/diagnose" 2>&1 || fail "diagnose failed: $(cat "$work/diagnose")"
grep -Fx "Skaffold version: $commit" "$work/diagnose" >/dev/null ||
  fail "diagnose does not report the build commit: $(cat "$work/diagnose")"
grep -F 'Number of artifacts: 1' "$work/diagnose" >/dev/null ||
  fail "diagnose does not count the artifact: $(cat "$work/diagnose")"

run inspect profiles list --format json >"$work/profiles" 2>&1 ||
  fail "inspect profiles failed: $(cat "$work/profiles")"
jq -e '.profiles == [{"name":"prod","path":"/work/skaffold.yaml","module":"shop"}]' "$work/profiles" >/dev/null ||
  fail "unexpected profiles: $(cat "$work/profiles")"

# render resolves the artifact to the tag passed with --images.
run render --offline=true --digest-source=none --images example.com/web=example.com/web:1.2.3 \
  >"$work/render" 2>"$work/render.err" || fail "render failed: $(cat "$work/render.err")"
grep -F 'image: example.com/web:1.2.3' "$work/render" >/dev/null ||
  fail "render did not apply the image tag: $(cat "$work/render")"
grep -F 'kind: Deployment' "$work/render" >/dev/null || fail "render lacks the Deployment: $(cat "$work/render")"
if grep -F 'kind: Service' "$work/render" >/dev/null; then
  fail 'the default render includes the prod-only Service'
fi

run render --offline=true --digest-source=none -p prod --images example.com/web=example.com/web:1.2.3 \
  >"$work/render-prod" 2>"$work/render-prod.err" || fail "prod render failed: $(cat "$work/render-prod.err")"
grep -F 'kind: Service' "$work/render-prod" >/dev/null ||
  fail "prod render lacks the Service: $(cat "$work/render-prod")"

rc=0
run render --offline=true --digest-source=none -p missing >"$work/badprofile" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'render with an unknown profile unexpectedly succeeded'
grep -F 'profile selection' "$work/badprofile" >/dev/null ||
  fail "unknown profile diagnostic is missing: $(cat "$work/badprofile")"

# fix upgrades an old schema to the current one on stdout.
cat >"$work/project/old.yaml" <<'EOF'
apiVersion: skaffold/v2beta29
kind: Config
build:
  artifacts:
    - image: example.com/web
deploy:
  kubectl:
    manifests:
      - k8s/deployment.yaml
EOF
cat >"$work/project/bad.yaml" <<'EOF'
apiVersion: skaffold/v0nonexistent
kind: Config
EOF
chmod 644 "$work/project/old.yaml" "$work/project/bad.yaml"
run fix -f old.yaml >"$work/fixed" 2>"$work/fixed.err" || fail "fix failed: $(cat "$work/fixed.err")"
grep -Fx 'apiVersion: skaffold/v4beta14' "$work/fixed" >/dev/null ||
  fail "fix did not upgrade the schema: $(cat "$work/fixed")"
grep -F 'rawYaml:' "$work/fixed" >/dev/null || fail "fix did not migrate the manifests: $(cat "$work/fixed")"

rc=0
run diagnose -f bad.yaml >"$work/badversion" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'an unknown apiVersion unexpectedly parsed'
grep -F 'skaffold/v0nonexistent' "$work/badversion" >/dev/null ||
  fail "unknown apiVersion diagnostic is missing: $(cat "$work/badversion")"

printf 'SMOKE PASS image=%s\n' "$image"
