#!/bin/sh
set -eu

# The adapter runs with --network none and a read-only root filesystem, with
# tmpfs at /tmp and /home/scanner/.cache as the upstream Helm chart mounts them.
# Redis is not needed for metadata, probes, or request validation: the client
# connects lazily. HTTP requests come from a pinned curl container that joins
# the adapter's network namespace, so nothing leaves the host.

image=${1:?usage: test.sh IMAGE}
recipe="$(dirname "$0")/../melange.yaml"
version=$(sed -n 's/^  version: "\([0-9.]*\)".*$/\1/p' "$recipe")
commit=$(sed -n 's/^  source-commit: \([0-9a-f]\{40\}\)$/\1/p' "$recipe")
trivy_version=$(sed -n 's/^  trivy-version: "\([0-9.]*\)".*$/\1/p' "$recipe")
probe_index='docker.io/curlimages/curl:8.14.1@sha256:9a1ed35addb45476afa911696297f8e115993df459278ed036182dd2cd22b67b'
label="verity-test=harbor-scanner-trivy-$$"
adapter=verity-harbor-scanner-trivy-$$
work=$(mktemp -d)

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -f >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  if docker inspect "$adapter" >/dev/null 2>&1; then
    printf -- '--- adapter logs ---\n' >&2
    docker logs "$adapter" >&2 2>&1 || true
  fi
  exit 1
}

[ -n "$version" ] || fail 'could not read the recipe version'
[ -n "$commit" ] || fail 'could not read the recipe source commit'
[ -n "$trivy_version" ] || fail 'could not read the recipe Trivy version'

inspect() {
  docker image inspect --format "$1" "$image"
}

# Upstream image contract: user scanner (10000), entrypoint in its home, and
# TRIVY_VERSION, which the adapter reports as the scanner version.
[ "$(inspect '{{.Config.User}}')" = 10000 ] || fail "unexpected OCI user: $(inspect '{{.Config.User}}')"
[ "$(inspect '{{json .Config.Entrypoint}}')" = '["/home/scanner/bin/scanner-trivy"]' ] ||
  fail "unexpected entrypoint: $(inspect '{{json .Config.Entrypoint}}')"
inspect '{{range .Config.Env}}{{println .}}{{end}}' >"$work/env.txt"
grep -Fx "TRIVY_VERSION=$trivy_version" "$work/env.txt" >/dev/null ||
  fail "TRIVY_VERSION is not $trivy_version: $(cat "$work/env.txt")"
grep -Fx 'HOME=/home/scanner' "$work/env.txt" >/dev/null || fail 'HOME is not /home/scanner'

# The bundled Trivy CLI is on PATH and is the pinned version.
docker run --rm --label "$label" --network none --entrypoint trivy "$image" \
  version --format json >"$work/trivy-version.json" ||
  fail 'trivy version failed'
[ "$(jq -r .Version "$work/trivy-version.json")" = "$trivy_version" ] ||
  fail "bundled trivy is not $trivy_version: $(cat "$work/trivy-version.json")"

# A classic Docker image store cannot bind the index digest to a second
# platform's image, so pull the probe by its own per-platform child digest.
# The index bytes are verified against the pinned digest before a child is
# chosen, which keeps the pin authoritative.
image_arch=$(inspect '{{.Architecture}}')
probe_raw=$(docker buildx imagetools inspect --raw "$probe_index") ||
  fail 'cannot inspect probe image index'
[ "sha256:$(printf '%s' "$probe_raw" | sha256sum | cut -d' ' -f1)" = "${probe_index#*@}" ] ||
  fail 'probe image index digest mismatch'
probe_digest=$(printf '%s' "$probe_raw" |
  jq -r --arg arch "$image_arch" '
    [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
    | if length == 1 then .[0] else empty end') ||
  fail 'cannot resolve probe image digest'
case $probe_digest in
  sha256:*) ;;
  *) fail "no unique linux/$image_arch probe image in $probe_index" ;;
esac
probe=docker.io/curlimages/curl@$probe_digest
docker pull --quiet --platform "linux/$image_arch" "$probe" >/dev/null ||
  fail 'cannot pull probe image'

running() {
  [ "$(docker inspect --format '{{.State.Running}}' "$adapter" 2>/dev/null)" = true ]
}

# curl_adapter ARGS...: run curl in the adapter network namespace.
curl_adapter() {
  docker run --rm --label "$label" --network "container:$adapter" "$probe" "$@"
}

# Default listen address is :8080. SCANNER_* settings are surfaced in the
# metadata properties, so a non-default value proves the env contract.
docker run -d --name "$adapter" --label "$label" --network none --read-only \
  --tmpfs /tmp:mode=1777 \
  --tmpfs /home/scanner/.cache:uid=10000,gid=10000,mode=0755 \
  -e SCANNER_LOG_LEVEL=info \
  -e SCANNER_TRIVY_SEVERITY=HIGH,CRITICAL \
  -e SCANNER_TRIVY_SKIP_UPDATE=true \
  -e SCANNER_TRIVY_IGNORE_UNFIXED=true \
  "$image" >/dev/null ||
  fail 'cannot start the adapter'

ready=
i=0
while [ "$i" -lt 60 ]; do
  running || fail 'adapter exited during startup'
  code=$(curl_adapter -sS -m 5 -o /dev/null -w '%{http_code}' \
    http://127.0.0.1:8080/probe/healthy 2>/dev/null) || code=000
  if [ "$code" = 200 ]; then
    ready=1
    break
  fi
  i=$((i + 1))
  sleep 1
done
[ -n "$ready" ] || fail "/probe/healthy never returned 200 on :8080 (last $code)"

code=$(curl_adapter -sS -m 10 -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/probe/ready) ||
  fail '/probe/ready request failed'
[ "$code" = 200 ] || fail "/probe/ready returned $code"

# Metadata: scanner identity, adapter build stamps, capabilities, and the
# SCANNER_* overrides. The handler runs the bundled trivy to read DB status.
curl_adapter -sS -m 60 -D - -o - http://127.0.0.1:8080/api/v1/metadata >"$work/metadata.http" ||
  fail '/api/v1/metadata request failed'
sed -n '1p' "$work/metadata.http" | grep -E '^HTTP/[0-9.]+ 200' >/dev/null ||
  fail "/api/v1/metadata did not return 200: $(sed -n '1p' "$work/metadata.http")"
grep -i '^content-type: application/vnd.scanner.adapter.metadata+json; version=1.0' \
  "$work/metadata.http" >/dev/null ||
  fail "unexpected metadata content type: $(grep -i '^content-type:' "$work/metadata.http")"
sed '1,/^\r\{0,1\}$/d' "$work/metadata.http" >"$work/metadata.json"

expect() {
  actual=$(jq -r "$1" "$work/metadata.json") || fail "metadata is not JSON: $(cat "$work/metadata.json")"
  [ "$actual" = "$2" ] || fail "metadata $1 is '$actual', expected '$2'"
}
expect '.scanner.name' Trivy
expect '.scanner.vendor' 'Aqua Security'
expect '.scanner.version' "$trivy_version"
expect '.properties["org.label-schema.version"]' "$version"
expect '.properties["org.label-schema.vcs-ref"]' "$commit"
expect '.properties["harbor.scanner-adapter/scanner-type"]' os-package-vulnerability
expect '.properties["env.SCANNER_TRIVY_SEVERITY"]' HIGH,CRITICAL
expect '.properties["env.SCANNER_TRIVY_SKIP_UPDATE"]' true
expect '.properties["env.SCANNER_TRIVY_IGNORE_UNFIXED"]' true
expect '[.capabilities[].type] | sort | join(",")' sbom,vulnerability
expect '.capabilities[] | select(.type == "vulnerability") | .produces_mime_types[0]' \
  'application/vnd.security.vulnerability.report; version=1.1'
expect '[.capabilities[].consumes_mime_types[]] | unique | join(",")' \
  'application/vnd.docker.distribution.manifest.v2+json,application/vnd.oci.image.manifest.v1+json'
if docker logs "$adapter" 2>&1 | grep -F 'Error while retrieving vulnerability DB version' >/dev/null; then
  fail 'metadata could not run the bundled trivy'
fi

# Negative cases: malformed JSON is a 400, a request without a registry is a
# 422, and an unknown API path is a 404. None of these reach Redis.
code=$(curl_adapter -sS -m 10 -o /dev/null -w '%{http_code}' -X POST \
  -H 'Content-Type: application/vnd.scanner.adapter.scan.request+json; version=1.1' \
  --data '{not json' http://127.0.0.1:8080/api/v1/scan) || fail 'malformed scan request failed'
[ "$code" = 400 ] || fail "malformed scan request returned $code, expected 400"

curl_adapter -sS -m 10 -o - -w '\n%{http_code}' -X POST \
  -H 'Content-Type: application/vnd.scanner.adapter.scan.request+json; version=1.1' \
  --data '{"artifact":{"repository":"library/alpine","digest":"sha256:0000000000000000000000000000000000000000000000000000000000000000"}}' \
  http://127.0.0.1:8080/api/v1/scan >"$work/scan-invalid.txt" || fail 'invalid scan request failed'
[ "$(tail -n 1 "$work/scan-invalid.txt")" = 422 ] ||
  fail "scan request without registry returned $(tail -n 1 "$work/scan-invalid.txt"), expected 422"
sed '$d' "$work/scan-invalid.txt" | jq -e '.error.message == "missing registry.url"' >/dev/null ||
  fail "unexpected validation error: $(cat "$work/scan-invalid.txt")"

code=$(curl_adapter -sS -m 10 -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/api/v1/unsupported) ||
  fail 'unknown path request failed'
[ "$code" = 404 ] || fail "unknown path returned $code, expected 404"

# SIGTERM shuts the API server down before the stop timeout. Upstream's
# ListenAndServe calls os.Exit(1) when it sees http.ErrServerClosed (the check
# is inverted), so a graceful stop exits 0 or 1 depending on which goroutine
# wins. Anything else, notably 137 from SIGKILL, is a failure.
docker stop -t 20 "$adapter" >/dev/null || fail 'cannot stop the adapter'
status=$(docker inspect --format '{{.State.ExitCode}}' "$adapter")
case "$status" in
  0) ;;
  1) docker logs "$adapter" 2>&1 | grep -F '"err":"http: Server closed"' >/dev/null ||
       fail 'adapter exited with 1 after SIGTERM without a graceful shutdown' ;;
  *) fail "adapter exited with $status after SIGTERM" ;;
esac

# A broken configuration fails fast instead of serving.
status=0
docker run --rm --label "$label" --network none \
  -e SCANNER_REDIS_URL=bogus://localhost "$image" >"$work/bad.log" 2>&1 || status=$?
[ "$status" -ne 0 ] || fail 'adapter accepted an unsupported Redis URL scheme'
grep -F 'invalid redis URL scheme: bogus' "$work/bad.log" >/dev/null ||
  fail "adapter did not report the bad Redis URL: $(cat "$work/bad.log")"

printf 'SMOKE PASS image=%s version=%s trivy=%s\n' "$image" "$version" "$trivy_version"
