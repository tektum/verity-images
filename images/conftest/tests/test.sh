#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

conftest() {
  docker run --rm --network none -v "$work:/project:ro" "$image" "$@"
}

user=$(docker image inspect -f '{{.Config.User}}' "$image")
test "$user" = 65532 || fail "image user is $user, want 65532"
entrypoint=$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")
test "$entrypoint" = '["/usr/bin/conftest"]' || fail "unexpected entrypoint: $entrypoint"
workdir=$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")
test "$workdir" = /project || fail "unexpected working directory: $workdir"

version=$(conftest --version)
printf '%s\n' "$version" | grep -Eq '^Conftest: 0\.71\.[0-9]+$' \
  || fail "unexpected version output: $version"

if conftest --no-such-flag >/dev/null 2>&1; then
  fail 'unknown flag was accepted'
fi

mkdir "$work/policy"
cat >"$work/policy/deployment.rego" <<'EOF'
package main

import rego.v1

deny contains msg if {
  input.kind == "Deployment"
  not input.spec.template.spec.securityContext.runAsNonRoot
  msg := "Containers must not run as root"
}
EOF
cat >"$work/good.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: good
spec:
  template:
    spec:
      securityContext:
        runAsNonRoot: true
EOF
cat >"$work/bad.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: bad
spec:
  template:
    spec:
      containers:
        - name: app
          image: example
EOF
chmod -R a+rX "$work"

output=$(conftest test --no-color good.yaml 2>&1) || fail "compliant fixture was rejected: $output"
printf '%s\n' "$output" | grep -q '1 test, 1 passed, 0 warnings, 0 failures, 0 exceptions' \
  || fail "unexpected pass summary: $output"

set +e
output=$(conftest test --no-color bad.yaml 2>&1)
status=$?
set -e
test "$status" -eq 1 || fail "non-compliant fixture exited $status, want 1: $output"
printf '%s\n' "$output" | grep -q '^FAIL - bad.yaml - main - Containers must not run as root$' \
  || fail "missing policy failure: $output"

printf 'SMOKE PASS image=%s\n' "$image"
