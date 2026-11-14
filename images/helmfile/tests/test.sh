#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
recipe="$here/../melange.yaml"
version=$(sed -n 's/^  version: "\([0-9.]*\)".*/\1/p' "$recipe")
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

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/helmfile"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ||
  fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

# Offline on a read-only root with no capabilities; Helm keeps its cache and
# configuration under a tmpfs home and the project is mounted read-only.
run() {
  docker run --rm --network none --read-only --cap-drop=ALL \
    --tmpfs /home/nonroot:uid=65532,gid=65532,mode=0755 --tmpfs /tmp:mode=1777 \
    -v "$work/project:/work:ro" "$image" "$@"
}

mkdir -p "$work/project/charts/app/templates"
chmod -R 755 "$work/project"

run version --output short >"$work/version" 2>&1 || fail "version failed: $(cat "$work/version")"
grep -Ex "v?$version" "$work/version" >/dev/null ||
  fail "version does not report $version: $(cat "$work/version")"

# helmfile drives the bundled Helm 4 client.
docker run --rm --network none --entrypoint /usr/bin/helm "$image" version --template '{{.Version}}' \
  >"$work/helm-version" 2>&1 || fail "helm version failed: $(cat "$work/helm-version")"
grep -Ex 'v4\.[0-9]+\.[0-9]+' "$work/helm-version" >/dev/null ||
  fail "unexpected bundled Helm version: $(cat "$work/helm-version")"

diff_version=$(sed -n 's/^  helm-diff-version: "\([0-9.]*\)".*/\1/p' "$recipe")
[ -n "$diff_version" ] || fail 'could not read the helm-diff version'
test "$(docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" |
  sed -n 's/^HELMFILE_UPGRADE_NOTICE_DISABLED=//p')" = true || fail 'the upgrade notice is not disabled'

# helmfile diff and apply need the bundled helm-diff plugin.
docker run --rm --network none --entrypoint /usr/bin/helm "$image" plugin list >"$work/plugins" 2>&1 ||
  fail "helm plugin list failed: $(cat "$work/plugins")"
awk -v v="$diff_version" '$1 == "diff" && $2 == v { found = 1 } END { exit !found }' "$work/plugins" ||
  fail "helm-diff $diff_version is not installed: $(cat "$work/plugins")"
run_helm() {
  docker run --rm --network none --read-only --cap-drop=ALL \
    --tmpfs /home/nonroot:uid=65532,gid=65532,mode=0755 --tmpfs /tmp:mode=1777 \
    --entrypoint /usr/bin/helm "$image" "$@"
}
run_helm diff version >"$work/diff-version" 2>&1 || fail "helm diff version failed: $(cat "$work/diff-version")"
grep -Fx "$diff_version" "$work/diff-version" >/dev/null ||
  fail "helm diff does not report $diff_version: $(cat "$work/diff-version")"

rc=0
run --definitely-invalid >"$work/invalid" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid flag unexpectedly succeeded'
grep -F 'unknown flag: --definitely-invalid' "$work/invalid" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/invalid")"

rc=0
run template >"$work/nostate" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'template without a state file unexpectedly succeeded'
grep -F 'no state file found' "$work/nostate" >/dev/null ||
  fail "missing state file diagnostic is missing: $(cat "$work/nostate")"

cat >"$work/project/charts/app/Chart.yaml" <<'EOF'
apiVersion: v2
name: app
version: 0.1.0
appVersion: "1.0.0"
EOF
cat >"$work/project/charts/app/values.yaml" <<'EOF'
replicas: 1
color: grey
EOF
cat >"$work/project/charts/app/templates/configmap.yaml" <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .Release.Name }}-settings
  namespace: {{ .Release.Namespace }}
data:
  replicas: {{ .Values.replicas | quote }}
  color: {{ required "color is required" .Values.color | quote }}
EOF
# Two releases of the local chart; the environment selects the replica count,
# and one release overrides a value with set.
cat >"$work/project/helmfile.yaml.gotmpl" <<'EOF'
environments:
  default:
    values:
      - replicas: 1
  prod:
    values:
      - replicas: 3
---
releases:
  - name: frontend
    namespace: web
    chart: ./charts/app
    labels:
      tier: frontend
    values:
      - replicas: {{ .Values.replicas }}
        color: blue
  - name: backend
    namespace: api
    chart: ./charts/app
    labels:
      tier: backend
    needs:
      - web/frontend
    set:
      - name: color
        value: green
EOF
mkdir -p "$work/project/broken"
cat >"$work/project/broken/helmfile.yaml" <<'EOF'
releases:
  - name: broken
    chart: ../charts/app
    values:
      - color: null
EOF
chmod 755 "$work/project/broken"
find "$work/project" -type f -exec chmod 644 {} +

run lint >"$work/lint" 2>&1 || fail "lint failed: $(cat "$work/lint")"
grep -F '1 chart(s) linted, 0 chart(s) failed' "$work/lint" >/dev/null ||
  fail "lint did not lint the releases: $(cat "$work/lint")"

run list --output json >"$work/list" 2>"$work/list.err" || fail "list failed: $(cat "$work/list.err")"
# helmfile adds chart, name and namespace labels to the declared ones.
jq -e 'sort_by(.name) | map({name, namespace, tier: (.labels | split(",") | map(select(startswith("tier:")))[0])})
  == [{"name":"backend","namespace":"api","tier":"tier:backend"},
      {"name":"frontend","namespace":"web","tier":"tier:frontend"}]' "$work/list" >/dev/null ||
  fail "unexpected release list: $(cat "$work/list")"

run template >"$work/default" 2>"$work/default.err" || fail "template failed: $(cat "$work/default.err")"
run -e prod template >"$work/prod" 2>"$work/prod.err" || fail "prod template failed: $(cat "$work/prod.err")"
for expect in 'name: frontend-settings' 'namespace: web' 'color: "blue"' 'replicas: "1"' \
  'name: backend-settings' 'namespace: api' 'color: "green"'; do
  grep -F "$expect" "$work/default" >/dev/null || fail "default render lacks '$expect': $(cat "$work/default")"
done
grep -F 'replicas: "3"' "$work/prod" >/dev/null || fail "prod render lacks 3 replicas: $(cat "$work/prod")"

run -l tier=backend template >"$work/selected" 2>"$work/selected.err" ||
  fail "selector template failed: $(cat "$work/selected.err")"
grep -F 'name: backend-settings' "$work/selected" >/dev/null ||
  fail "selector render lacks the backend: $(cat "$work/selected")"
if grep -F 'name: frontend-settings' "$work/selected" >/dev/null; then
  fail 'the label selector rendered an unselected release'
fi

rc=0
run -f broken/helmfile.yaml template >"$work/broken" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'a failing chart template unexpectedly rendered'
grep -F 'color is required' "$work/broken" >/dev/null ||
  fail "chart template error is missing: $(cat "$work/broken")"

printf 'SMOKE PASS image=%s\n' "$image"
