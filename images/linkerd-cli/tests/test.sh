#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
recipe="$(dirname "$0")/../melange.yaml"
version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' "$recipe")
[ -n "$version" ] || { printf 'package version not found\n' >&2; exit 1; }
release="edge-${version}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

# Offline only: no network and no cluster. Cluster-facing checks are not exercised.
run() {
  docker run --rm --network none --read-only --cpus 2 --memory 512m --pids-limit 256 "$@"
}

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = /home/nonroot ] \
  || fail 'unexpected working directory'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/linkerd"]' ] \
  || fail 'unexpected entrypoint'
case $(docker image inspect -f '{{json .Config.Cmd}}' "$image") in null|'[]') ;; *) fail 'unexpected image command' ;; esac

run "$image" version --client --short >"$work/version" 2>&1 || fail "version failed: $(cat "$work/version")"
[ "$(cat "$work/version")" = "$release" ] || fail "unexpected version output: $(cat "$work/version")"

# Without a cluster, install refuses to render unless --ignore-cluster is given.
if run "$image" install --crds >"$work/crds-cluster" 2>&1; then
  fail 'install --crds without a cluster unexpectedly succeeded'
fi
grep -F 'You can use the --ignore-cluster flag' "$work/crds-cluster" >/dev/null \
  || fail "install --crds cluster diagnostic missing: $(cat "$work/crds-cluster")"

run "$image" install --crds --ignore-cluster >"$work/crds.yaml" 2>"$work/crds.err" \
  || fail "install --crds --ignore-cluster failed: $(cat "$work/crds.err")"
grep -Fx 'kind: CustomResourceDefinition' "$work/crds.yaml" >/dev/null || fail 'CRD manifest has no CRDs'
if grep -E '^kind: ' "$work/crds.yaml" | grep -Fxv 'kind: CustomResourceDefinition' >/dev/null; then
  fail 'CRD manifest contains non-CRD kinds'
fi
for crd in servers.policy.linkerd.io httproutes.policy.linkerd.io authorizationpolicies.policy.linkerd.io \
  serviceprofiles.linkerd.io externalworkloads.workload.linkerd.io; do
  grep -Fx "  name: ${crd}" "$work/crds.yaml" >/dev/null || fail "CRD manifest is missing ${crd}"
done

run "$image" install --ignore-cluster >"$work/cp.yaml" 2>"$work/cp.err" \
  || fail "install --ignore-cluster failed: $(cat "$work/cp.err")"
for kind in Namespace Deployment Service MutatingWebhookConfiguration ValidatingWebhookConfiguration Secret; do
  grep -Fx "kind: ${kind}" "$work/cp.yaml" >/dev/null || fail "control plane manifest is missing kind ${kind}"
done
if grep -Fx 'kind: CustomResourceDefinition' "$work/cp.yaml" >/dev/null; then
  fail 'control plane manifest unexpectedly contains CRDs'
fi
for deploy in linkerd-destination linkerd-identity linkerd-proxy-injector; do
  grep -Fx "  name: ${deploy}" "$work/cp.yaml" >/dev/null || fail "control plane manifest is missing ${deploy}"
done
grep -Fx "        image: cr.l5d.io/linkerd/controller:${release}" "$work/cp.yaml" >/dev/null \
  || fail 'control plane does not pin the controller image to the release'
grep -E "image: cr\.l5d\.io/linkerd/proxy:${release}$" "$work/cp.yaml" >/dev/null \
  || fail 'control plane does not pin the proxy image to the release'
if grep -E 'image: ' "$work/cp.yaml" | grep -Fv ":${release}" >/dev/null; then
  fail "control plane references an image outside the release: $(grep -E 'image: ' "$work/cp.yaml" | grep -Fv ":${release}")"
fi
grep -F 'BEGIN CERTIFICATE' "$work/cp.yaml" >/dev/null || fail 'control plane is missing a generated trust anchor'

# Negative: preflight checks fail closed without a reachable API server.
if run -e KUBECONFIG=/nonexistent "$image" check --pre >"$work/pre-empty" 2>&1; then
  fail 'check --pre without a kubeconfig unexpectedly succeeded'
fi
grep -F 'invalid configuration: no configuration has been provided' "$work/pre-empty" >/dev/null \
  || fail "check --pre empty kubeconfig diagnostic missing: $(cat "$work/pre-empty")"

cat >"$work/kubeconfig" <<'EOF'
apiVersion: v1
kind: Config
clusters:
  - name: unreachable
    cluster:
      server: https://127.0.0.1:1
contexts:
  - name: unreachable
    context:
      cluster: unreachable
      user: placeholder
current-context: unreachable
users:
  - name: placeholder
    user:
      token: placeholder
EOF
chmod 0644 "$work/kubeconfig"
if run -v "$work/kubeconfig:/tmp/kubeconfig:ro" "$image" --kubeconfig /tmp/kubeconfig check --pre \
  >"$work/pre" 2>&1; then
  fail 'check --pre against an unreachable API server unexpectedly succeeded'
fi
# linkerd check marks results with U+221A (pass) and U+00D7 (fail); keep the source ASCII.
check_ok=$(printf '\342\210\232')
check_fail=$(printf '\303\227')
grep -F "${check_ok} can initialize the client" "$work/pre" >/dev/null \
  || fail "check --pre did not load the kubeconfig: $(cat "$work/pre")"
grep -F "${check_fail} can query the Kubernetes API" "$work/pre" >/dev/null \
  || fail "check --pre connectivity failure missing: $(cat "$work/pre")"
grep -F 'dial tcp 127.0.0.1:1: connect: connection refused' "$work/pre" >/dev/null \
  || fail "check --pre connectivity diagnostic missing: $(cat "$work/pre")"

if run "$image" not-a-real-command >"$work/unknown" 2>&1; then
  fail 'unknown subcommand unexpectedly succeeded'
fi
grep -F 'unknown command "not-a-real-command" for "linkerd"' "$work/unknown" >/dev/null \
  || fail "unknown subcommand diagnostic missing: $(cat "$work/unknown")"

printf 'SMOKE PASS image=%s\n' "$image"
