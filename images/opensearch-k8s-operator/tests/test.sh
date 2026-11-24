#!/bin/sh
# Smoke test for the OpenSearch Kubernetes Operator image. Every container runs
# with --network none and without KUBERNETES_SERVICE_HOST, so no case can reach
# a Kubernetes API server or an OpenSearch cluster.
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
name="verity-opensearch-operator-smoke-$$"
# Startup failures without a cluster must be fast, never a retry loop.
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
  output=$(timeout 120 docker run --name "$name" --network none "$@" 2>&1) || status=$?
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

inspect() {
  docker image inspect --format "$1" "$image"
}

# OCI contract: upstream runs as USER 65532:65532 in WORKDIR / with
# ENTRYPOINT ["/manager"] and no CMD.
[ "$(inspect '{{.Config.User}}')" = 65532:65532 ] || fail "unexpected OCI user: $(inspect '{{.Config.User}}')"
[ "$(inspect '{{json .Config.Entrypoint}}')" = '["/manager"]' ] ||
  fail "unexpected entrypoint: $(inspect '{{json .Config.Entrypoint}}')"
[ "$(inspect '{{json .Config.Cmd}}')" = null ] || fail 'unexpected default command'
[ "$(inspect '{{.Config.WorkingDir}}')" = / ] || fail 'unexpected working directory'

nl='
'
# Help lists the flags the Helm chart and kustomize manifests pass, with the
# upstream metrics and health probe defaults. Go's flag package exits 0 on -help.
run "$image" -help
[ "$status" -eq 0 ] || fail "-help exited $status"
for flag in -health-probe-bind-address -metrics-bind-address -leader-elect \
  -kubeconfig -watch-namespace -loglevel -enable-webhooks -webhook-port \
  -max-concurrent-reconciles; do
  case $output in
    *"  $flag "* | *"  $flag$nl"*) ;;
    *) fail "-help does not list $flag" ;;
  esac
done
case $output in
  *'The address the metric endpoint binds to. (default ":8443")'*) ;;
  *) fail 'metrics address default is not :8443' ;;
esac
case $output in
  *'The address the probe endpoint binds to. (default ":8081")'*) ;;
  *) fail 'health probe address default is not :8081' ;;
esac

# Upstream has no version flag or subcommand; the flag parser rejects it like
# any unknown flag, as do malformed health, metrics, and webhook values.
expect_failure 'no version flag' 2 'flag provided but not defined: -version' \
  "$image" -version
expect_failure 'unknown flag' 2 'flag provided but not defined: -no-such-flag' \
  "$image" -no-such-flag
expect_failure 'missing probe address' 2 'flag needs an argument: -health-probe-bind-address' \
  "$image" -health-probe-bind-address
expect_failure 'missing metrics address' 2 'flag needs an argument: -metrics-bind-address' \
  "$image" -metrics-bind-address
expect_failure 'malformed webhook port' 2 'invalid value "abc" for flag -webhook-port' \
  "$image" -webhook-port=abc
expect_failure 'malformed leader election' 2 'invalid boolean value "maybe" for -leader-elect' \
  "$image" -leader-elect=maybe

# Without a cluster the manager resolves its REST config before it binds the
# metrics or health probe listeners, and must exit 1 at once: first in-cluster,
# then from the default kubeconfig location.
expect_failure 'no cluster' 1 '"msg":"unable to get kubeconfig"' \
  "$image" -metrics-bind-address=:18443 -health-probe-bind-address=:18081
case $output in
  *'unable to load in-cluster configuration, KUBERNETES_SERVICE_HOST and KUBERNETES_SERVICE_PORT must be defined'*) ;;
  *) printf '%s\n' "$output" >&2; fail 'in-cluster lookup did not fail on the missing service environment' ;;
esac
case $output in
  *'starting server'* | *'Starting metrics server'*)
    printf '%s\n' "$output" >&2
    fail 'manager bound listeners without a cluster'
    ;;
esac

# An explicit kubeconfig path that does not exist is named in the error.
expect_failure 'missing kubeconfig' 1 '"msg":"unable to get kubeconfig"' \
  "$image" -kubeconfig=/nonexistent/kubeconfig
case $output in
  *'stat /nonexistent/kubeconfig: no such file or directory'*) ;;
  *) printf '%s\n' "$output" >&2; fail 'kubeconfig failure does not name the path' ;;
esac

# client-go skips missing files named by KUBECONFIG, so startup still fails
# cleanly with no usable configuration.
expect_failure 'missing KUBECONFIG' 1 'no configuration has been provided' \
  -e KUBECONFIG=/nonexistent/env-kubeconfig "$image"

# An invalid log level is reported and startup still proceeds to the config step.
expect_failure 'invalid log level' 1 '"msg":"unable to get kubeconfig"' \
  "$image" -loglevel=bogus
case $output in
  *"Invalid log level 'bogus'. Leaving on info"*) ;;
  *) printf '%s\n' "$output" >&2; fail 'invalid log level is not reported' ;;
esac

printf 'SMOKE PASS image=%s version=v%s\n' "$image" "$expected_version"
