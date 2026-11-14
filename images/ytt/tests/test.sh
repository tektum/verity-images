#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
config="$here/../apko.yaml"
version=$(sed -n 's/^    - ytt=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
work=$(mktemp -d)
# Host-visible tmpfs so rendered files can be read back after the container exits.
out=$(mktemp -d -p /dev/shm ytt-out.XXXXXX)
binary_container=

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [ -n "$binary_container" ]; then
    docker rm -f "$binary_container" >/dev/null 2>&1 || true
  fi
  rm -rf "$work" "$out"
}
trap cleanup EXIT INT TERM

[ -n "$version" ] || fail 'could not read the pinned ytt version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/ytt"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ||
  fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

# Every behavior check runs offline on a read-only root with no capabilities.
run() {
  docker run --rm --network none --read-only --cap-drop=ALL \
    -v "$work/config:/work:ro" -v "$work/values:/values:ro" "$image" "$@"
}

mkdir -p "$work/config/k8s" "$work/values" "$work/broken"

# Schema with defaults, a Starlark module, a template with a loop and a
# function, a second template in a subdirectory, and an overlay.
cat >"$work/config/schema.yaml" <<'EOF'
#@data/values-schema
---
app:
  name: ""
  replicas: 1
  env: dev
  ports:
  - 0
EOF
cat >"$work/config/lib.star" <<'EOF'
def labels(name, env):
  return {"app.kubernetes.io/name": name, "env": env}
end
EOF
cat >"$work/config/deployment.yaml" <<'EOF'
#@ load("@ytt:data", "data")
#@ load("lib.star", "labels")
#@ def port_name(p):
#@   return "p" + str(p)
#@ end
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: #@ data.values.app.name
  labels: #@ labels(data.values.app.name, data.values.app.env)
spec:
  replicas: #@ data.values.app.replicas
  template:
    spec:
      containers:
      - name: #@ data.values.app.name
        ports:
        #@ for p in data.values.app.ports:
        - name: #@ port_name(p)
          containerPort: #@ p
        #@ end
EOF
cat >"$work/config/k8s/service.yaml" <<'EOF'
#@ load("@ytt:data", "data")
---
apiVersion: v1
kind: Service
metadata:
  name: #@ data.values.app.name
spec:
  ports: #@ [{"port": p, "targetPort": p} for p in data.values.app.ports]
EOF
cat >"$work/config/overlay.yaml" <<'EOF'
#@ load("@ytt:overlay", "overlay")
#@overlay/match by=overlay.subset({"kind": "Deployment"})
---
metadata:
  #@overlay/match missing_ok=True
  annotations:
    managed-by: ytt
spec:
  template:
    spec:
      #@overlay/match missing_ok=True
      securityContext:
        runAsNonRoot: true
EOF
cat >"$work/values/values.yaml" <<'EOF'
app:
  name: web
  ports: [8080, 9090]
EOF
cat >"$work/values/mismatch.yaml" <<'EOF'
app:
  replicas: three
EOF
printf '#@ x =\n---\na: 1\n' >"$work/broken/broken.yaml"
find "$work/config" "$work/values" "$work/broken" -type d -exec chmod 755 {} +
find "$work/config" "$work/values" "$work/broken" -type f -exec chmod 644 {} +

# `ytt version` must report the pinned release. Wolfi 0.55.4-r3 stamps the
# version into the pre-rename module path (github.com/vmware-tanzu/carvel-ytt),
# so the binary reports `develop`; accept that only when the embedded build
# information proves both the pinned module version and that stale ldflag.
run version >"$work/version" 2>&1 || fail "version failed: $(cat "$work/version")"
binary_container=$(docker create "$image")
docker cp "$binary_container:/usr/bin/ytt" "$work/ytt" >/dev/null ||
  fail 'could not copy /usr/bin/ytt out of the image'
grep -aqF "$(printf 'mod\tcarvel.dev/ytt\tv%s\t' "$version")" "$work/ytt" ||
  fail "binary build info does not embed carvel.dev/ytt v$version"
reported=$(sed -n 's/^ytt version \(.*\)$/\1/p' "$work/version")
case "$reported" in
  "$version" | "v$version") ;;
  develop)
    grep -aqF "github.com/vmware-tanzu/carvel-ytt/pkg/version.Version=v$version" "$work/ytt" ||
      fail "version reports develop without the known stale v$version ldflag: $(cat "$work/version")"
    ;;
  *) fail "version does not report $version: $(cat "$work/version")" ;;
esac

rc=0
run --definitely-invalid >"$work/invalid" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'unknown flag unexpectedly succeeded'
grep -F 'unknown flag: --definitely-invalid' "$work/invalid" >/dev/null ||
  fail "unknown flag diagnostic is missing: $(cat "$work/invalid")"

run -f . --data-values-file /values/values.yaml \
  --data-value app.env=prod --data-value-yaml app.replicas=3 \
  >"$work/render.yaml" 2>"$work/render.err" ||
  fail "render failed: $(cat "$work/render.err")"
cat >"$work/expected-deployment.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  labels:
    app.kubernetes.io/name: web
    env: prod
  annotations:
    managed-by: ytt
spec:
  replicas: 3
  template:
    spec:
      containers:
      - name: web
        ports:
        - name: p8080
          containerPort: 8080
        - name: p9090
          containerPort: 9090
      securityContext:
        runAsNonRoot: true
EOF
cat >"$work/expected-service.yaml" <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  ports:
  - port: 8080
    targetPort: 8080
  - port: 9090
    targetPort: 9090
EOF
{
  cat "$work/expected-deployment.yaml"
  echo ---
  cat "$work/expected-service.yaml"
} >"$work/expected.yaml"
cmp -s "$work/expected.yaml" "$work/render.yaml" ||
  fail "unexpected render: $(diff -u "$work/expected.yaml" "$work/render.yaml" || true)"

# Schema defaults apply when no override is given.
run -f . --data-values-file /values/values.yaml --data-values-inspect \
  >"$work/inspect.yaml" 2>&1 || fail "data values inspect failed: $(cat "$work/inspect.yaml")"
cat >"$work/expected-inspect.yaml" <<'EOF'
app:
  name: web
  replicas: 1
  env: dev
  ports:
  - 8080
  - 9090
EOF
cmp -s "$work/expected-inspect.yaml" "$work/inspect.yaml" ||
  fail "unexpected data values: $(diff -u "$work/expected-inspect.yaml" "$work/inspect.yaml" || true)"

rc=0
run -f . --data-values-file /values/values.yaml --data-values-file /values/mismatch.yaml \
  >"$work/mismatch" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'schema type mismatch in a values file unexpectedly rendered'
for line in 'One or more data values were invalid' 'replicas: three' '= found: string' \
  '= expected: integer (by schema.yaml:'; do
  grep -F -- "$line" "$work/mismatch" >/dev/null ||
    fail "values file mismatch diagnostic lacks '$line': $(cat "$work/mismatch")"
done

rc=0
run -f . --data-values-file /values/values.yaml --data-value app.replicas=3 \
  >"$work/mismatch-flag" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'string --data-value for an integer field unexpectedly rendered'
for line in 'app.replicas=3' '= found: string' '= expected: integer (by schema.yaml:'; do
  grep -F -- "$line" "$work/mismatch-flag" >/dev/null ||
    fail "--data-value mismatch diagnostic lacks '$line': $(cat "$work/mismatch-flag")"
done

rc=0
docker run --rm --network none --read-only --cap-drop=ALL \
  -v "$work/broken:/broken:ro" "$image" -f /broken >"$work/syntax" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'template syntax error unexpectedly rendered'
grep -F 'broken.yaml:' "$work/syntax" >/dev/null ||
  fail "syntax error diagnostic does not name the file: $(cat "$work/syntax")"
grep -F 'want primary expression' "$work/syntax" >/dev/null ||
  fail "syntax error diagnostic is missing: $(cat "$work/syntax")"

# The read-only root and mounted input reject output files.
rc=0
run -f . --data-values-file /values/values.yaml --output-files /work/rendered \
  >"$work/ro-out" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'output to the read-only input mount unexpectedly succeeded'
grep -F 'read-only file system' "$work/ro-out" >/dev/null ||
  fail "read-only output diagnostic is missing: $(cat "$work/ro-out")"

# Output files land on a writable tmpfs, mirroring the template tree; schema,
# Starlark, and overlay inputs produce no output files.
printf 'creating: /out/deployment.yaml\ncreating: /out/k8s/service.yaml\n' >"$work/expected-created"
docker run --rm --network none --read-only --cap-drop=ALL \
  -v "$work/config:/work:ro" -v "$work/values:/values:ro" \
  --tmpfs /out:rw,noexec,nosuid,size=4m,uid=65532,gid=65532,mode=0755 "$image" \
  -f . --data-values-file /values/values.yaml --data-value app.env=prod \
  --data-value-yaml app.replicas=3 --output-files /out >"$work/created" 2>&1 ||
  fail "output to tmpfs failed: $(cat "$work/created")"
cmp -s "$work/expected-created" "$work/created" ||
  fail "unexpected tmpfs output files: $(cat "$work/created")"

# Same render to a host tmpfs directory. The subdirectory is pre-created so
# the runner can delete everything ytt writes during cleanup.
mkdir "$out/k8s"
chmod 777 "$out" "$out/k8s"
docker run --rm --network none --read-only --cap-drop=ALL \
  -v "$work/config:/work:ro" -v "$work/values:/values:ro" -v "$out:/out" "$image" \
  -f . --data-values-file /values/values.yaml --data-value app.env=prod \
  --data-value-yaml app.replicas=3 --output-files /out >"$work/created" 2>&1 ||
  fail "output to directory failed: $(cat "$work/created")"
cmp -s "$work/expected-created" "$work/created" ||
  fail "unexpected output files: $(cat "$work/created")"
files=$(cd "$out" && find . -type f | LC_ALL=C sort | tr '\n' ' ')
test "$files" = './deployment.yaml ./k8s/service.yaml ' ||
  fail "unexpected output tree: $files"
for file in deployment.yaml k8s/service.yaml; do
  test "$(stat -c '%u:%g' "$out/$file")" = 65532:65532 ||
    fail "$file was not written by the image user: $(stat -c '%u:%g' "$out/$file")"
done

# ytt may write owner-only files, so read them back as the image user.
readback() {
  docker run --rm --network none --read-only --cap-drop=ALL \
    -v "$out:/out:ro" "$image" "$@"
}
readback -f /out --files-inspect >"$work/inspected" 2>&1 ||
  fail "files inspect failed: $(cat "$work/inspected")"
test "$(cat "$work/inspected")" = "$(printf -- '- deployment.yaml\n- k8s/service.yaml')" ||
  fail "unexpected inspected files: $(cat "$work/inspected")"
for file in deployment k8s/service; do
  name=$(basename "$file")
  readback -f "/out/$file.yaml" >"$work/readback-$name.yaml" 2>&1 ||
    fail "reading $file.yaml failed: $(cat "$work/readback-$name.yaml")"
  cmp -s "$work/expected-$name.yaml" "$work/readback-$name.yaml" ||
    fail "unexpected $file.yaml: $(diff -u "$work/expected-$name.yaml" "$work/readback-$name.yaml" || true)"
done

printf 'SMOKE PASS image=%s\n' "$image"
