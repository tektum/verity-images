#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
argo_cli_version=$(sed -n 's/^[[:space:]]*argo-cli-version: \(v[^ ]*\).*$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$argo_cli_version" ] || { printf 'argo CLI version not found\n' >&2; exit 1; }
tmp=$(mktemp -d)
chmod 755 "$tmp"

cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

run() {
  docker run --rm --cpus=4 --network none --user 65532:65532 \
    -v "$tmp:/work:ro" "$@"
}

[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ] \
  || fail 'image user is not 65532'
[ "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = / ] \
  || fail 'unexpected working directory'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/argo-events"]' ] \
  || fail 'unexpected image entrypoint'

help_output=$(run "$image" --help 2>&1) || fail 'argo-events --help failed'
for command in controller eventsource-service sensor-service webhook-service lint; do
  printf '%s\n' "$help_output" | grep -E "^  $command " >/dev/null \
    || fail "argo-events help does not list $command"
done

cat >"$tmp/eventsource.yaml" <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: EventSource
metadata:
  name: webhook
spec:
  webhook:
    example:
      port: "12000"
      endpoint: /example
      method: POST
EOF

cat >"$tmp/sensor.yaml" <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Sensor
metadata:
  name: webhook
spec:
  dependencies:
    - name: payload
      eventSourceName: webhook
      eventName: example
  triggers:
    - template:
        name: submit-workflow
        argoWorkflow:
          operation: submit
          source:
            resource:
              apiVersion: argoproj.io/v1alpha1
              kind: Workflow
              metadata:
                generateName: webhook-
              spec:
                entrypoint: main
                templates:
                  - name: main
                    container:
                      image: example.invalid/hello
EOF

cat >"$tmp/invalid-eventsource.yaml" <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: EventSource
metadata:
  name: broken
spec:
  webhook:
    example:
      endpoint: /example
      method: POST
EOF

output=$(run "$image" lint /work/eventsource.yaml /work/sensor.yaml 2>&1) || {
  printf '%s\n' "$output" >&2
  fail 'lint rejected valid EventSource and Sensor resources'
}
printf '%s\n' "$output" | grep -F '/work/eventsource.yaml: EventSource is valid' >/dev/null \
  || fail 'lint did not report the EventSource as valid'
printf '%s\n' "$output" | grep -F '/work/sensor.yaml: Sensor is valid' >/dev/null \
  || fail 'lint did not report the Sensor as valid'

if output=$(run "$image" lint /work/invalid-eventsource.yaml 2>&1); then
  fail 'lint accepted an EventSource without a webhook port'
fi
printf '%s\n' "$output" | grep -F 'EventSource validation failed' >/dev/null \
  || fail 'lint did not report the invalid EventSource'

if output=$(run "$image" not-a-command 2>&1); then
  fail 'unknown command unexpectedly succeeded'
fi
printf '%s\n' "$output" | grep -F 'unknown command "not-a-command" for "argo-events"' >/dev/null \
  || fail 'unknown command did not report the expected error'

cat >"$tmp/controller-config.yaml" <<'EOF'
eventBus:
  nats:
    versions:
      - version: 0.22.1
        natsStreamingImage: nats-streaming:0.22.1
        metricsExporterImage: natsio/prometheus-nats-exporter:0.8.0
  jetstream:
    versions:
      - version: 2.10.10
        natsImage: nats:2.10.10
        metricsExporterImage: natsio/prometheus-nats-exporter:0.14.0
        configReloaderImage: natsio/nats-server-config-reloader:0.14.0
        startCommand: /nats-server
EOF
chmod 644 "$tmp"/*

# The controller loads and validates its mounted configuration, then must exit
# without a kubeconfig or in-cluster service account instead of serving. The
# missing-credentials exit itself is silent upstream (controller-runtime
# GetConfigOrDie), so assert it passed every earlier fatal check.
status=0
output=$(timeout 120 docker run --rm --cpus=4 --network none \
  -e ARGO_EVENTS_IMAGE=example.invalid/argo-events:test \
  -v "$tmp/controller-config.yaml:/etc/argo-events/controller-config.yaml:ro" \
  "$image" controller 2>&1) || status=$?
[ "$status" = 1 ] \
  || { printf '%s\n' "$output" >&2; fail "controller without Kubernetes credentials exited $status, expected 1"; }
printf '%s\n' "$output" | grep -F 'searching for config in paths' >/dev/null \
  || { printf '%s\n' "$output" >&2; fail 'controller did not read /etc/argo-events'; }
if printf '%s\n' "$output" | grep -F '"level":"fatal"' >/dev/null; then
  printf '%s\n' "$output" >&2
  fail 'controller rejected the mounted configuration or environment'
fi

if output=$(run "$image" sensor-service 2>&1); then
  fail 'sensor service started without Kubernetes credentials'
fi
printf '%s\n' "$output" | grep -F 'failed to get kubeconfig' >/dev/null \
  || { printf '%s\n' "$output" >&2; fail 'sensor service did not report missing Kubernetes credentials'; }

# The ArgoWorkflow trigger shells out to the bundled argo CLI after writing
# the workflow to the temporary directory.
argo_version=$(run --entrypoint argo "$image" version 2>&1) \
  || fail 'bundled argo CLI failed to run'
printf '%s\n' "$argo_version" | grep -F "argo: $argo_cli_version+" >/dev/null \
  || fail 'bundled argo CLI has the wrong version'

cat >"$tmp/workflow.yaml" <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: hello-
spec:
  entrypoint: main
  templates:
    - name: main
      container:
        image: example.invalid/hello
EOF
cat >"$tmp/invalid-workflow.yaml" <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: hello-
spec:
  entrypoint: missing
  templates:
    - name: main
      container:
        image: example.invalid/hello
EOF
chmod 644 "$tmp"/*

output=$(run --entrypoint argo "$image" lint --offline /work/workflow.yaml 2>&1) || {
  printf '%s\n' "$output" >&2
  fail 'argo CLI rejected a valid workflow'
}
if output=$(run --entrypoint argo "$image" lint --offline /work/invalid-workflow.yaml 2>&1); then
  fail 'argo CLI accepted a workflow with a missing entrypoint'
fi
printf '%s\n' "$output" | grep -F 'missing' >/dev/null \
  || { printf '%s\n' "$output" >&2; fail 'argo CLI did not report the missing entrypoint'; }

container=$(docker create --network none "$image")
tmp_mode=$(docker export "$container" | tar -tvf - | awk '$NF == "tmp/" { print $1 }')
docker rm "$container" >/dev/null
[ "$tmp_mode" = drwxrwxrwt ] || fail "unexpected /tmp mode: $tmp_mode"

printf 'SMOKE PASS image=%s version=%s\n' "$image" "$expected_version"
