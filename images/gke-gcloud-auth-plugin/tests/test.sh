#!/bin/sh
set -eu

# Exercises the client-go exec credential protocol fully offline. Every plugin
# run uses --network none, so no token can come from Google: success paths use
# the CLOUDSDK_AUTH_ACCESS_TOKEN override and the plugin's on-disk token cache,
# and failure paths must exit 1 with a diagnostic and no stdout. The image
# ships no gcloud, so the default provider must fail cleanly when nothing else
# supplies a token.

image=${1:?usage: test.sh IMAGE}
recipe="$(dirname "$0")/../melange.yaml"
expected_version=$(sed -n 's/^  version: "\([0-9][0-9.]*\)".*$/\1/p' "$recipe")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -n "$expected_version" ] || fail 'package version not found in melange.yaml'
command -v jq >/dev/null || fail 'jq is required'

inspect() {
  docker image inspect --format "$1" "$image"
}

[ "$(inspect '{{.Config.User}}')" = 65532 ] || fail "unexpected OCI user: $(inspect '{{.Config.User}}')"
[ "$(inspect '{{json .Config.Entrypoint}}')" = '["/usr/bin/gke-gcloud-auth-plugin"]' ] ||
  fail "unexpected entrypoint: $(inspect '{{json .Config.Entrypoint}}')"
[ "$(inspect '{{.Config.WorkingDir}}')" = /work ] || fail "unexpected working directory: $(inspect '{{.Config.WorkingDir}}')"

# exec_info API: KUBERNETES_EXEC_INFO as client-go sets it for this apiVersion.
exec_info='{"kind":"ExecCredential","apiVersion":"client.authentication.k8s.io/v1beta1","spec":{"interactive":false}}'

# run NAME [docker args...] -- [plugin args...]: stdout to NAME.out, stderr to
# NAME.err, exit status to NAME.rc. Always offline and as the image user.
run() {
  name=$1
  shift
  set +e
  docker run --rm --network none "$@" >"$work/$name.out" 2>"$work/$name.err"
  printf '%s' "$?" >"$work/$name.rc"
  set -e
}

rc() { cat "$work/$1.rc"; }

# check_credential NAME TOKEN EXPIRY: stdout is exactly one v1beta1
# ExecCredential carrying TOKEN; EXPIRY is the timestamp or "none".
check_credential() {
  [ "$(rc "$1")" = 0 ] || fail "$1: exit $(rc "$1"): $(cat "$work/$1.err")"
  jq -e --arg token "$2" --arg expiry "$3" '
    .kind == "ExecCredential"
    and .apiVersion == "client.authentication.k8s.io/v1beta1"
    and .status.token == $token
    and (.status | has("clientCertificateData") | not)
    and (if $expiry == "none" then (.status | has("expirationTimestamp") | not)
         else .status.expirationTimestamp == $expiry end)
  ' "$work/$1.out" >/dev/null || fail "$1: unexpected ExecCredential: $(cat "$work/$1.out")"
}

# check_failure NAME PATTERN: exit 1, empty stdout, PATTERN on stderr.
check_failure() {
  [ "$(rc "$1")" = 1 ] || fail "$1: expected exit 1, got $(rc "$1"): $(cat "$work/$1.err")"
  [ ! -s "$work/$1.out" ] || fail "$1: failure wrote to stdout: $(cat "$work/$1.out")"
  grep -Eq "$2" "$work/$1.err" || fail "$1: stderr lacks /$2/: $(cat "$work/$1.err")"
}

run version "$image" --version
[ "$(rc version)" = 0 ] || fail "--version exited $(rc version)"
grep -Fq "v$expected_version" "$work/version.out" || fail "--version: $(cat "$work/version.out")"

# The image must not carry gcloud or a shell: the default provider has nothing
# to execute.
run no-gcloud --entrypoint /bin/sh "$image" -c true
[ "$(rc no-gcloud)" != 0 ] || fail 'image unexpectedly contains /bin/sh'

# 1. Access token override, with and without exec info. The plugin ignores
#    KUBERNETES_EXEC_INFO; it must not change or break the output.
run env-token -e CLOUDSDK_AUTH_ACCESS_TOKEN=offline-env-token "$image"
check_credential env-token offline-env-token none
run env-token-info -e CLOUDSDK_AUTH_ACCESS_TOKEN=offline-env-token \
  -e KUBERNETES_EXEC_INFO="$exec_info" "$image"
check_credential env-token-info offline-env-token none
run env-token-badinfo -e CLOUDSDK_AUTH_ACCESS_TOKEN=offline-env-token \
  -e KUBERNETES_EXEC_INFO='{not json' "$image"
check_credential env-token-badinfo offline-env-token none
cmp -s "$work/env-token.out" "$work/env-token-info.out" ||
  fail 'KUBERNETES_EXEC_INFO changed the ExecCredential'

# 2. Token cache next to the kubeconfig, keyed by current-context and args.
mkdir -p "$work/kube"
cat >"$work/kube/config" <<'EOF'
apiVersion: v1
kind: Config
clusters:
- name: offline
  cluster:
    server: https://127.0.0.1:6443
contexts:
- name: gke_offline_us-central1_test
  context:
    cluster: offline
    user: gke
current-context: gke_offline_us-central1_test
users:
- name: gke
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      command: gke-gcloud-auth-plugin
      interactiveMode: Never
      provideClusterInfo: true
EOF
expiry=2099-01-01T00:00:00Z
write_cache() {
  printf '{"current_context":"%s","access_token":"%s","token_expiry":"%s","extra_args":"%s"}\n' \
    "$1" "$2" "$3" "$4" >"$work/kube/gke_gcloud_auth_plugin_cache"
}
chmod 0755 "$work/kube"
chmod 0644 "$work/kube/config"
mount="-v $work/kube:/kube:ro -e KUBECONFIG=/kube/config"

write_cache gke_offline_us-central1_test offline-cached-token "$expiry" ''
chmod 0644 "$work/kube/gke_gcloud_auth_plugin_cache"
# shellcheck disable=SC2086
run cached $mount -e KUBERNETES_EXEC_INFO="$exec_info" "$image"
check_credential cached offline-cached-token "$expiry"

write_cache gke_offline_us-central1_test offline-cached-token "$expiry" '--project=offline-project'
# shellcheck disable=SC2086
run cached-args $mount "$image" --project=offline-project
check_credential cached-args offline-cached-token "$expiry"

# A cache for other args, another context, or an expired token is not used;
# without gcloud the plugin then fails cleanly.
# shellcheck disable=SC2086
run cache-args-miss $mount "$image" --project=other-project
check_failure cache-args-miss 'gcloud.*executable file not found'
write_cache gke_other_context offline-cached-token "$expiry" ''
# shellcheck disable=SC2086
run cache-context-miss $mount "$image"
check_failure cache-context-miss 'gcloud.*executable file not found'
write_cache gke_offline_us-central1_test offline-cached-token 2001-01-01T00:00:00Z ''
# shellcheck disable=SC2086
run cache-expired $mount "$image"
check_failure cache-expired 'gcloud.*executable file not found'

# 3. Clean failures with no gcloud and no credentials.
run no-creds -e KUBERNETES_EXEC_INFO="$exec_info" "$image"
check_failure no-creds 'print credential failed.*gcloud.*executable file not found'
# With no credential file, ADC probes the GCE metadata server; the offline
# network must turn that into a clean failure rather than a hang.
run adc-none "$image" --use_application_default_credentials
check_failure adc-none 'print credential failed.*could not find default credentials'
run adc-missing -e GOOGLE_APPLICATION_CREDENTIALS=/work/missing.json "$image" \
  --use_application_default_credentials
check_failure adc-missing 'print credential failed.*missing\.json'
printf '{"type":"unsupported_type"}\n' >"$work/bad-adc.json"
chmod 0644 "$work/bad-adc.json"
run adc-invalid -v "$work/bad-adc.json:/creds/adc.json:ro" \
  -e GOOGLE_APPLICATION_CREDENTIALS=/creds/adc.json "$image" --use_application_default_credentials
check_failure adc-invalid 'print credential failed.*unsupported_type'
run edge-missing "$image" --use_edge_cloud
check_failure edge-missing 'project, --location and --cluster are required'
run bad-flag "$image" --no-such-flag
[ "$(rc bad-flag)" != 0 ] || fail 'unknown flag was accepted'
[ ! -s "$work/bad-flag.out" ] || fail 'unknown flag wrote to stdout'

printf 'SMOKE PASS image=%s\n' "$image"
