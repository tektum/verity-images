#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

# The repository is bind-mounted with the host owner, so git needs
# safe.directory to accept it under the image user.
ct() {
  repo=$1
  shift
  docker run --rm --network none \
    -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0='*' \
    -v "$repo:/workspace" "$image" "$@"
}

user=$(docker image inspect -f '{{.Config.User}}' "$image")
test "$user" = 65532 || fail "image user is $user, want 65532"
entrypoint=$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")
test "$entrypoint" = '["/usr/bin/ct"]' || fail "unexpected entrypoint: $entrypoint"
workdir=$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")
test "$workdir" = /workspace || fail "unexpected working directory: $workdir"

version=$(ct "$work" version)
printf '%s\n' "$version" | grep -Eq '^Version:[[:space:]]+v3\.15\.[0-9]+$' \
  || fail "unexpected version output: $version"
printf '%s\n' "$version" | grep -Eq '^Git commit:[[:space:]]+[0-9a-f]{40}$' \
  || fail "missing git commit stamp: $version"
printf '%s\n' "$version" | grep -Eq '^Date:[[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2}T' \
  || fail "missing build date stamp: $version"

for tool in helm git yamllint yamale kubectl; do
  docker run --rm --network none --entrypoint bash "$image" -c "command -v $tool" >/dev/null \
    || fail "$tool is missing from PATH"
done

if ct "$work" --no-such-flag >/dev/null 2>&1; then
  fail 'unknown flag was accepted'
fi

make_repo() {
  dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email test@example.invalid
  git -C "$dir" config user.name test
}

commit_repo() {
  git -C "$1" add -A
  git -C "$1" commit -q -m fixture
  chmod -R a+rwX "$1"
}

write_chart() {
  dir=$1
  mkdir -p "$dir/templates"
  cat >"$dir/values.yaml" <<'EOF'
replicaCount: 1
EOF
  cat >"$dir/templates/configmap.yaml" <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .Release.Name }}-demo
data:
  replicas: {{ .Values.replicaCount | quote }}
EOF
}

# --debug echoes each external command, proving yamale and yamllint ran with
# the bundled /etc/ct defaults. No remote exists, so version checks are off.
lint_args='lint --debug --chart-dirs charts --all --validate-maintainers=false --check-version-increment=false --target-branch main'

good=$work/good
make_repo "$good"
write_chart "$good/charts/demo"
cat >"$good/charts/demo/Chart.yaml" <<'EOF'
apiVersion: v2
name: demo
description: Smoke test chart
type: application
version: 0.1.0
appVersion: "1.0.0"
EOF
commit_repo "$good"

# shellcheck disable=SC2086
output=$(ct "$good" $lint_args 2>&1) || fail "valid chart was rejected: $output"
assert_line() {
  printf '%s\n' "$1" | grep -Fxq -- "$2" || fail "missing line '$2' in: $1"
}
# ct decorates some lines with emoji; the repository keeps sources ASCII-only,
# so those lines are matched by their ASCII prefix or suffix.
assert_prefix() {
  printf '%s\n' "$1" | awk -v p="$2" 'index($0, p) == 1 { found = 1 } END { exit !found }' ||
    fail "missing line starting '$2' in: $1"
}
assert_suffix() {
  printf '%s\n' "$1" | awk -v s="$2" '
    length($0) > length(s) && substr($0, length($0) - length(s) + 1) == s { found = 1 }
    END { exit !found }' || fail "missing line ending '$2' in: $1"
}
assert_line "$output" '>>> yamale --schema /etc/ct/chart_schema.yaml charts/demo/Chart.yaml'
assert_line "$output" 'Validating charts/demo/Chart.yaml...'
assert_prefix "$output" 'Validation success! '
assert_line "$output" '>>> yamllint --config-file /etc/ct/lintconf.yaml charts/demo/Chart.yaml'
assert_line "$output" '>>> yamllint --config-file /etc/ct/lintconf.yaml charts/demo/values.yaml'
assert_line "$output" '==> Linting charts/demo'
assert_line "$output" '1 chart(s) linted, 0 chart(s) failed'
assert_line "$output" 'All charts linted successfully'

bad=$work/bad
make_repo "$bad"
# Schema violation helm itself ignores: chart_schema.yaml declares engine as
# str(), and Helm chart metadata has no such field.
write_chart "$bad/charts/badschema"
cat >"$bad/charts/badschema/Chart.yaml" <<'EOF'
apiVersion: v2
name: badschema
description: Wrong engine type
version: 0.1.0
engine: 42
EOF
# yamllint violation: lintconf.yaml enables trailing-spaces.
write_chart "$bad/charts/trailing"
printf 'apiVersion: v2\nname: trailing\ndescription: Trailing spaces   \nversion: 0.1.0\n' \
  >"$bad/charts/trailing/Chart.yaml"
commit_repo "$bad"

set +e
# shellcheck disable=SC2086
output=$(ct "$bad" $lint_args 2>&1)
status=$?
set -e
test "$status" -ne 0 || fail "broken charts were accepted: $output"
assert_line "$output" '	engine: '"'"'42'"'"' is not a str.'
assert_line "$output" 'Validation failed!'
assert_line "$output" '  3:29      error    trailing spaces  (trailing-spaces)'
assert_suffix "$output" ' badschema => (version: "0.1.0", path: "charts/badschema") > failed waiting for process: exit status 1'
assert_suffix "$output" ' trailing => (version: "0.1.0", path: "charts/trailing") > failed waiting for process: exit status 1'
assert_line "$output" 'Error: failed linting charts: failed processing charts'

printf 'SMOKE PASS image=%s\n' "$image"
