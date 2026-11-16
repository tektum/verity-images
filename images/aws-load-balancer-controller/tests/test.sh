#!/bin/sh
# Smoke test for the AWS Load Balancer Controller image. Every container runs
# with --network none and AWS_EC2_METADATA_DISABLED=true, so no case can reach
# AWS APIs, EC2 instance metadata, or a Kubernetes API server.
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
name="verity-albc-smoke-$$"
# Startup failures without a cluster or AWS must be fast, never a retry loop.
max_seconds=20

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  docker rm -f "$name" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

expected_version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' "$here/../melange.yaml")
[ -n "$expected_version" ] || fail 'could not read the recipe version'

# run ARGS...: run the image offline; sets $output, $status, and $elapsed.
run() {
  cleanup
  started=$(date +%s)
  status=0
  output=$(timeout 120 docker run --name "$name" --network none \
    -e AWS_EC2_METADATA_DISABLED=true "$@" 2>&1) || status=$?
  elapsed=$(($(date +%s) - started))
  cleanup
}

# expect_failure DESCRIPTION CODE TEXT ARGS...: the run exits with CODE within
# $max_seconds and its output contains TEXT.
expect_failure() {
  description=$1 code=$2 text=$3
  shift 3
  run "$@"
  if [ "$status" -ne "$code" ]; then
    printf '%s\n' "$output" >&2
    fail "$description: exit status $status, expected $code"
  fi
  if [ "$elapsed" -gt "$max_seconds" ]; then
    printf '%s\n' "$output" >&2
    fail "$description: took ${elapsed}s, expected at most ${max_seconds}s"
  fi
  case $output in
    *"$text"*) ;;
    *)
      printf '%s\n' "$output" >&2
      fail "$description: missing '$text'"
      ;;
  esac
}

# OCI contract: upstream runs as nonroot UID 65532 with an entrypoint, no CMD.
[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ] ||
  fail 'unexpected OCI user'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/aws-load-balancer-controller"]' ] || fail 'unexpected entrypoint'
[ "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ] ||
  fail 'unexpected default command'

# Help lists the flags the Helm chart and an offline deployment rely on.
run "$image" --help
[ "$status" -eq 0 ] || fail "--help exited $status"
for flag in --cluster-name --aws-region --aws-vpc-id --kubeconfig --ingress-class \
  --webhook-cert-dir --metrics-bind-addr --health-probe-bind-addr --feature-gates; do
  case $output in
    *"$flag "*) ;;
    *) fail "--help does not list $flag" ;;
  esac
done

# The upstream /controller path stays usable for manifests that set command.
run --entrypoint /controller "$image" --help
[ "$status" -eq 0 ] || fail "/controller --help exited $status"
case $output in
  *--cluster-name*) ;;
  *) fail '/controller --help does not list --cluster-name' ;;
esac

# Flag parsing rejects unknown flags and malformed values.
expect_failure 'unknown flag' 2 'unknown flag: --no-such-flag' \
  "$image" --no-such-flag
expect_failure 'malformed boolean' 2 'invalid argument "maybe" for "--enable-shield"' \
  "$image" --cluster-name=smoke --enable-shield=maybe

# There is no version flag: the controller logs its version stamps first, then
# validates configuration. Without a cluster name it stops before any client.
expect_failure 'missing cluster name' 1 'kubernetes cluster name must be specified' \
  "$image"
case $output in
  *'"msg":"version","GitVersion":"v'"$expected_version"'","GitCommit":"'*) ;;
  *) printf '%s\n' "$output" >&2; fail "version log does not report v$expected_version" ;;
esac
commit=$(printf '%s\n' "$output" | sed -n 's/.*"GitCommit":"\([0-9a-f]*\)".*/\1/p')
[ "${#commit}" -eq 40 ] || fail "GitCommit is not a full commit hash: '$commit'"
case $output in
  *'"BuildDate":"20'*) ;;
  *) fail 'version log has no BuildDate' ;;
esac

expect_failure 'invalid target type' 1 'invalid value bogus for default target type' \
  "$image" --cluster-name=smoke --default-target-type=bogus

# Without --aws-region the controller needs EC2 metadata; with metadata access
# disabled it must fail at once with its documented hint.
expect_failure 'missing region' 1 'specify --aws-region instead if EC2Metadata is unavailable' \
  "$image" --cluster-name=smoke
case $output in
  *'access disabled to EC2 IMDS'*) ;;
  *) printf '%s\n' "$output" >&2; fail 'region lookup did not stop before contacting EC2 IMDS' ;;
esac

# With region and VPC given, AWS setup needs no network. Startup then fails on
# the missing Kubernetes configuration, in-cluster and from a kubeconfig path.
aws_args='--cluster-name=smoke --aws-region=us-west-2 --aws-vpc-id=vpc-0123456789abcdef0'
# shellcheck disable=SC2086
expect_failure 'no in-cluster configuration' 1 'unable to load in-cluster configuration' \
  "$image" $aws_args
case $output in
  *'unable to build REST config'*) ;;
  *) printf '%s\n' "$output" >&2; fail 'in-cluster failure is not the REST config step' ;;
esac
# shellcheck disable=SC2086
expect_failure 'missing kubeconfig' 1 'unable to build REST config' \
  "$image" $aws_args --kubeconfig=/nonexistent/kubeconfig
case $output in
  *'/nonexistent/kubeconfig'*) ;;
  *) printf '%s\n' "$output" >&2; fail 'kubeconfig failure does not name the path' ;;
esac

printf 'SMOKE PASS image=%s version=v%s\n' "$image" "$expected_version"
