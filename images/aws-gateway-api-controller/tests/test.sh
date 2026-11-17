#!/bin/sh
# Smoke test for the AWS Gateway API Controller image. Every container runs
# with --network none and AWS_EC2_METADATA_DISABLED=true, so no case can reach
# AWS APIs, EC2 instance metadata, or a Kubernetes API server.
set -eu

image=${1:?usage: test.sh IMAGE}
name="verity-agwc-smoke-$$"
# Startup failures without AWS or a cluster must be fast, never a retry loop.
max_seconds=20

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  docker rm -f "$name" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

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
  '["/usr/bin/aws-gateway-api-controller"]' ] || fail 'unexpected entrypoint'
[ "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ] ||
  fail 'unexpected default command'

# Help lists the flags the Helm chart and probes rely on.
run "$image" --help
[ "$status" -eq 0 ] || fail "--help exited $status"
for flag in -leader-elect -metrics-bind-address -health-probe-bind-address -kubeconfig; do
  case $output in
    *"  $flag"*) ;;
    *) fail "--help does not list $flag" ;;
  esac
done

# The Helm chart sets command: /manager with args only; keep that path usable.
run --entrypoint /manager "$image" --help
[ "$status" -eq 0 ] || fail "/manager --help exited $status"
case $output in
  *-leader-elect*) ;;
  *) fail '/manager --help does not list -leader-elect' ;;
esac

# Flag parsing rejects unknown flags and malformed values.
expect_failure 'unknown flag' 2 'flag provided but not defined: -no-such-flag' \
  "$image" --no-such-flag
expect_failure 'malformed boolean' 2 'invalid boolean value "maybe" for -leader-elect' \
  "$image" --leader-elect=maybe

# Without CLUSTER_VPC_ID the controller needs EC2 metadata; with metadata
# access disabled it must fail at once before any AWS call.
expect_failure 'missing VPC' 1 'vpcId is not specified' "$image"
case $output in
  *'access disabled to EC2 IMDS'*) ;;
  *) printf '%s\n' "$output" >&2; fail 'VPC lookup did not stop before contacting EC2 IMDS' ;;
esac

aws_env='-e CLUSTER_VPC_ID=vpc-0123456789abcdef0 -e REGION=us-west-2 -e AWS_ACCOUNT_ID=123456789012 -e CLUSTER_NAME=smoke'

# Configuration validation rejects invalid tuning values.
# shellcheck disable=SC2086
expect_failure 'short resync interval' 1 \
  'RECONCILE_DEFAULT_RESYNC_SECONDS must be 0 (disabled) or at least 60 seconds, got 5' \
  $aws_env -e RECONCILE_DEFAULT_RESYNC_SECONDS=5 "$image"
# shellcheck disable=SC2086
expect_failure 'malformed route concurrency' 1 \
  'invalid value for ROUTE_MAX_CONCURRENT_RECONCILES' \
  $aws_env -e ROUTE_MAX_CONCURRENT_RECONCILES=many "$image"

# With full AWS configuration from the environment, startup reaches the
# Kubernetes client and fails on the missing configuration, both in-cluster
# and from a kubeconfig path.
# shellcheck disable=SC2086
expect_failure 'no in-cluster configuration' 1 \
  'unable to load in-cluster configuration' $aws_env "$image"
case $output in
  *'"msg":"init config","VpcId":"vpc-0123456789abcdef0","Region":"us-west-2","AccountId":"123456789012"'*) ;;
  *) printf '%s\n' "$output" >&2; fail 'init config did not log the environment configuration' ;;
esac
case $output in
  *'"ClusterName":"smoke"'*) ;;
  *) printf '%s\n' "$output" >&2; fail 'init config did not log the cluster name' ;;
esac
# shellcheck disable=SC2086
expect_failure 'missing kubeconfig' 1 'stat /nonexistent/kubeconfig: no such file or directory' \
  $aws_env "$image" --kubeconfig=/nonexistent/kubeconfig

# Webhook mode is selected from the environment before the Kubernetes client.
# shellcheck disable=SC2086
expect_failure 'webhook enabled' 1 'unable to load in-cluster configuration' \
  $aws_env -e WEBHOOK_ENABLED=true "$image"
case $output in
  *'Webhook is enabled'*) ;;
  *) printf '%s\n' "$output" >&2; fail 'WEBHOOK_ENABLED=true did not enable the webhook' ;;
esac

# AWS TLS uses the CA bundle shipped by ca-certificates-bundle.
[ "$(docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" |
  grep -c '^SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt$')" -eq 1 ] ||
  fail 'SSL_CERT_FILE is not set to the CA bundle'

printf 'SMOKE PASS image=%s\n' "$image"
