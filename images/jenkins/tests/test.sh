#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-jenkins-test-$$"
fail() {
  printf '%s\n' "$1" >&2
  docker logs "$container" 2>&1 | tail -n 40 >&2 || true
  exit 1
}
cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

recipe_version=$(sed -n 's/^  version: "\([^"]*\)".*$/\1/p' "$(dirname "$0")/../melange.yaml")
[ -n "$recipe_version" ] || fail 'Jenkins package version is missing'

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 1000 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = /var/jenkins_home ] || fail 'unexpected OCI working directory'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/tini","--","/usr/local/bin/jenkins.sh"]' ] || fail 'unexpected OCI entrypoint'
docker image inspect -f '{{json .Config.Volumes}}' "$image" | grep -Fq '/var/jenkins_home' || fail 'JENKINS_HOME volume is missing'

docker run --rm --network none "$image" git --version | grep -q '^git version' || fail 'git is unavailable'
docker run --rm --network none "$image" java -version 2>&1 | grep -q '"21\.' || fail 'unexpected Java version'
docker run --rm --network none --entrypoint /usr/bin/jenkins-plugin-cli "$image" --help >/dev/null 2>&1 || fail 'jenkins-plugin-cli is unavailable'

if output=$(docker run --rm --network none "$image" --httpPort=invalid 2>&1); then
  fail 'invalid httpPort unexpectedly succeeded'
fi
printf '%s\n' "$output" | grep -q 'Failed to start a listener' || fail 'invalid httpPort failure was not readable'

docker run --name "$container" -d -e JAVA_OPTS=-Djenkins.install.runSetupWizard=false \
  -p 127.0.0.1::8080 "$image" >/dev/null
port=$(docker port "$container" 8080/tcp | awk -F: 'NR == 1 { print $2 }')
[ -n "$port" ] || fail 'published port is missing'

headers=$(mktemp)
body=$(mktemp)
trap 'rm -f "$headers" "$body"; cleanup' EXIT INT TERM
ready=false
for _ in $(seq 1 120); do
  status=$(curl -s --connect-timeout 1 --max-time 5 -o "$body" -D "$headers" -w '%{http_code}' "http://127.0.0.1:$port/login" || true)
  if [ "$status" = 200 ]; then
    ready=true
    break
  fi
  sleep 2
done
[ "$ready" = true ] || fail 'Jenkins did not become ready'
grep -qi 'Sign in to Jenkins\|j_username' "$body" || fail 'login form is missing'
tr -d '\r' <"$headers" | grep -qi "^X-Jenkins: ${recipe_version}\$" || fail 'unexpected X-Jenkins version header'
curl -fsS --connect-timeout 1 --max-time 5 "http://127.0.0.1:$port/api/json" | grep -q '"mode"' || fail 'API did not return Jenkins JSON'

docker stop -t 60 "$container" >/dev/null
code=$(docker inspect -f '{{.State.ExitCode}}' "$container")
case "$code" in
  0|143) ;;
  *) fail "unexpected exit code $code after SIGTERM" ;;
esac
printf 'SMOKE PASS version=%s image=%s\n' "$recipe_version" "$image"
