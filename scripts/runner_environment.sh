#!/bin/bash
# Builds the predicate of the signed runner-environment attestation.
#
# collect: run first in the publish job. Fails unless the runner is an EC2
# instance that refuses IMDSv1, that RunsOn registered with GitHub as this job's
# runner, and that started at most MAX_INSTANCE_AGE_SECONDS before the job. A
# RunsOn instance serves one job and is then terminated, so an older instance
# would mean it ran something else first.
# materials: run after the candidate build. Adds the digests of the resolved
# build inputs present in the job.
set -euo pipefail

usage='usage: runner_environment.sh collect PREDICATE | materials PREDICATE BUILD_DIRECTORY'
mode=${1:?$usage}
predicate=${2:?$usage}
imds=${IMDS_ENDPOINT:-http://169.254.169.254}
max_age=${MAX_INSTANCE_AGE_SECONDS:-900}

fail() {
  printf 'runner environment: %s\n' "$1" >&2
  exit 1
}

collect() {
  local status token identity lifecycle instance pending age attempt
  # Retry transport failures (HTTP 000) so a boot-time blip does not block a publication;
  # anything but a 401 once IMDS answers still fails.
  for attempt in 1 2 3; do
    status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${imds}/latest/meta-data/instance-id") || true
    [[ "$status" != 000 ]] && break
    ((attempt == 3)) || sleep "${IMDS_RETRY_DELAY:-2}"
  done
  [[ "$status" != 000 ]] || fail 'IMDS is unreachable'
  [[ "$status" == 401 ]] || fail "IMDSv1 is not refused (HTTP ${status})"
  token=$(curl -fsS --max-time 5 -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 300' \
    "${imds}/latest/api/token") || fail 'IMDSv2 is unreachable'
  identity=$(curl -fsS --max-time 5 -H "X-aws-ec2-metadata-token: ${token}" \
    "${imds}/latest/dynamic/instance-identity/document") || fail 'IMDSv2 identity document is unreachable'
  lifecycle=$(curl -fsS --max-time 5 -H "X-aws-ec2-metadata-token: ${token}" \
    "${imds}/latest/meta-data/instance-life-cycle") || fail 'IMDSv2 instance life cycle is unreachable'
  [[ "$lifecycle" == on-demand ]] || fail "instance life cycle is ${lifecycle}, not on-demand"
  instance=$(jq -er .instanceId <<<"$identity")
  [[ "${RUNS_ON_INSTANCE_ID:-}" == "$instance" ]] ||
    fail "RunsOn instance ${RUNS_ON_INSTANCE_ID:-unset} is not ${instance}"
  [[ -n "${RUNNER_NAME:-}" && "$RUNNER_NAME" == "${RUNS_ON_RUNNER_NAME:-}" &&
    "$RUNNER_NAME" == *"--${instance}--"* ]] ||
    fail "runner ${RUNNER_NAME:-unset} is not registered for ${instance}"
  pending=$(jq -er .pendingTime <<<"$identity")
  age=$(($(date -u +%s) - $(date -u -d "$pending" +%s)))
  ((age >= 0 && age <= max_age)) || fail "instance started ${age}s before this job; limit ${max_age}s"
  jq -n --argjson identity "$identity" --arg lifecycle "$lifecycle" --argjson age "$age" \
    --argjson maxAge "$max_age" --arg collectedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{
      builder: {id: env.BUILDER_ID, runnerName: env.RUNNER_NAME, runnerEnvironment: env.RUNNER_ENVIRONMENT},
      job: {repository: env.GITHUB_REPOSITORY, sha: env.GITHUB_SHA, runId: env.GITHUB_RUN_ID,
        runAttempt: env.GITHUB_RUN_ATTEMPT, job: env.GITHUB_JOB, jobIndex: env.JOB_INDEX},
      instance: {id: $identity.instanceId, amiId: $identity.imageId, type: $identity.instanceType,
        lifecycle: $lifecycle, architecture: $identity.architecture, region: $identity.region,
        availabilityZone: $identity.availabilityZone, pendingTime: $identity.pendingTime},
      runsOn: {version: env.RUNS_ON_VERSION, stack: env.RUNS_ON_STACK_NAME,
        scheduledAt: env.RUNS_ON_INSTANCE_LAUNCHED_AT, pool: (env.RUNS_ON_POOL_NAME // null)},
      checks: {imdsV1Refused: true, runnerBoundToInstance: true, instanceAgeSeconds: $age,
        maxInstanceAgeSeconds: $maxAge},
      collectedAt: $collectedAt,
      resolvedDependencies: []
    }' >"$predicate"
}

materials() {
  local build=${1:?$usage} evidence path files=() entries upstream='[]'
  evidence=$(<"${build}/evidence-path")
  shopt -s nullglob globstar
  # Tool archives are hashed after install_image_tools.sh checked them against the pins.
  for path in "$evidence" /tmp/{grype,syft,copa,trivy}.tar.gz /tmp/apko_*_linux_*.tar.gz \
    /tmp/melange_*_linux_*.tar.gz native-arm64/**/*.apk; do
    [[ -f "$path" ]] && files+=("$path")
  done
  entries=$(sha256sum "${files[@]}" | jq -R -s -c '[split("\n")[] | select(length > 0) |
    capture("^(?<sha>[0-9a-f]{64})  (?<path>.+)$") |
    {name: (.path | sub("^/tmp/"; "")), digest: {sha256: .sha}}]')
  if [[ "$evidence" == */source-resolved.json ]]; then
    upstream=$(jq -c '[{name: .image, uri: ("oci://" + (.image | sub(":[^:/]*$"; ""))),
      digest: {sha256: (.resolvedDigest | ltrimstr("sha256:"))}}]' "$evidence")
  fi
  jq --argjson entries "$entries" --argjson upstream "$upstream" \
    '.resolvedDependencies = $upstream + $entries' "$predicate" >"${predicate}.tmp"
  mv "${predicate}.tmp" "$predicate"
}

case "$mode" in
  collect) collect ;;
  materials) materials "${3:-}" ;;
  *) fail "$usage" ;;
esac
