#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
recipe="$(dirname "$0")/../melange.yaml"
version=$(sed -n 's/^  version: "\([0-9.]*\)".*$/\1/p' "$recipe")
label="verity-test=eksctl-$$"
work=$(mktemp -d)

trap 'rm -rf "$work"' EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ -n "$version" ] || fail 'could not read the recipe version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/eksctl"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

# Every run is offline with dummy credentials and no instance metadata, so no
# command can reach AWS.
run() {
  docker run --rm --label "$label" --network none --read-only \
    --tmpfs /tmp:rw,mode=1777 \
    -e AWS_REGION=eu-west-1 -e AWS_DEFAULT_REGION=eu-west-1 \
    -e AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE \
    -e AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY \
    -e AWS_EC2_METADATA_DISABLED=true \
    -v "$work/config:/work:ro" "$image" "$@"
}

mkdir -p "$work/config"
cat >"$work/config/cluster.yaml" <<'YAML'
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: verity-smoke
  region: eu-west-1
  version: "1.33"
availabilityZones: [eu-west-1a, eu-west-1b]
managedNodeGroups:
  - name: workers
    instanceType: m6i.large
    desiredCapacity: 2
    amiFamily: AmazonLinux2023
YAML
sed 's/    desiredCapacity: 2/&\n    notAField: true/' "$work/config/cluster.yaml" \
  >"$work/config/unknown-field.yaml"
grep -v '^  region:' "$work/config/cluster.yaml" >"$work/config/no-region.yaml"
cat "$work/config/cluster.yaml" - >"$work/config/subnets-and-zones.yaml" <<'YAML'
vpc:
  subnets:
    private:
      eu-west-1a: {id: subnet-0123456789abcdef0}
YAML
chmod -R a+rX "$work/config"

# stdout only: docker prints a platform mismatch warning on stderr for emulated arm64 runs.
out=$(run version) || fail 'version failed'
test "$out" = "$version" || fail "version does not report $version: $out"
out=$(run info) || fail 'info failed'
printf '%s\n' "$out" | grep -Fx "eksctl version: $version" >/dev/null ||
  fail "info does not report $version: $out"

# The ClusterConfig JSON schema is generated offline from the compiled API types.
run utils schema >"$work/schema.json" || fail 'utils schema failed'
jq -e '
  ."$ref" == "#/definitions/ClusterConfig"
  and .definitions.ClusterConfig.properties.apiVersion.enum == ["eksctl.io/v1alpha5"]
  and .definitions.ClusterConfig.properties.kind.enum == ["ClusterConfig"]
  and (.definitions.ClusterConfig.required | index("metadata") != null)
  and (.definitions.ClusterMeta.required | sort) == ["name", "region"]
  and (.definitions.ManagedNodeGroup.properties.amiFamily.enum | index("AmazonLinux2023") != null)
  and (.definitions.ClusterConfig.properties | has("managedNodeGroups") and has("availabilityZones"))
' "$work/schema.json" >/dev/null || fail 'utils schema produced an unexpected ClusterConfig schema'

out=$(run completion bash) || fail 'completion failed'
printf '%s\n' "$out" | grep -q '__start_eksctl' || fail 'bash completion lacks the eksctl entry point'

# Negative: an unknown command is rejected.
if run definitely-not-a-command >"$work/bad.log" 2>&1; then
  fail 'unknown command was accepted'
fi
grep -q 'unknown command "definitely-not-a-command"' "$work/bad.log" ||
  fail "unexpected unknown-command error: $(cat "$work/bad.log")"

# Negative: invalid ClusterConfig files are rejected by the loader with their diagnostic.
expect_config_error() {
  file=$1 message=$2
  if run create cluster --dry-run -f "/work/$file" >"$work/$file.log" 2>&1; then
    fail "invalid config $file was accepted"
  fi
  grep -qF "$message" "$work/$file.log" ||
    fail "unexpected error for $file: $(cat "$work/$file.log")"
  if grep -q 'STS' "$work/$file.log"; then
    fail "$file was not rejected before contacting AWS: $(cat "$work/$file.log")"
  fi
}
expect_config_error unknown-field.yaml 'json: unknown field "notAField"'
expect_config_error no-region.yaml 'metadata.region must be set'
expect_config_error subnets-and-zones.yaml \
  'vpc.subnets and availabilityZones cannot be set at the same time'

# Negative: commands that need AWS fail fast with a network error. The valid
# config passes the loader and stops at the first STS call; the empty status
# code and request ID show that no endpoint answered.
expect_offline_failure() {
  log=$1
  shift
  start=$(date +%s)
  if run "$@" >"$work/$log" 2>&1; then
    fail "$* succeeded without network access"
  fi
  elapsed=$(($(date +%s) - start))
  [ "$elapsed" -lt 60 ] || fail "$* took ${elapsed}s to fail offline"
  grep -qF 'checking AWS STS access' "$work/$log" ||
    fail "$* did not stop at the STS check: $(cat "$work/$log")"
  grep -qF 'StatusCode: 0, RequestID: , request send failed' "$work/$log" ||
    fail "$* reached an endpoint: $(cat "$work/$log")"
  grep -Eq 'dial tcp: lookup sts\.eu-west-1\.amazonaws\.com.*(network is unreachable|no such host|server misbehaving)' \
    "$work/$log" || fail "$* failed for a reason other than the network: $(cat "$work/$log")"
}
expect_offline_failure dry-run.log create cluster --dry-run -f /work/cluster.yaml
expect_offline_failure get.log get clusters --region eu-west-1

printf 'SMOKE PASS\n'
