#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-jenkins-test-$$"
negative="$container-negative"
volume="$container-home"
fail() {
  printf '%s\n' "$1" >&2
  docker logs "$container" 2>&1 | tail -n 40 >&2 || true
  exit 1
}
cleanup() {
  docker rm -fv "$container" "$negative" >/dev/null 2>&1 || true
  docker volume rm "$volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

recipe_version=$(sed -n 's/^  version: "\([^"]*\)".*$/\1/p' "$(dirname "$0")/../melange.yaml")
[ -n "$recipe_version" ] || fail 'Jenkins package version is missing'

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 1000 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = /var/jenkins_home ] || fail 'unexpected OCI working directory'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/tini","--","/usr/local/bin/jenkins.sh"]' ] || fail 'unexpected OCI entrypoint'
docker image inspect -f '{{json .Config.Volumes}}' "$image" | grep -Fq '"/var/jenkins_home":' || fail 'JENKINS_HOME volume is missing'

docker run --rm --network none "$image" git --version | grep -q '^git version' || fail 'git is unavailable'
docker run --rm --network none "$image" java -version 2>&1 | grep -q '"21\.' || fail 'unexpected Java version'
docker run --rm --network none --entrypoint /usr/bin/jenkins-plugin-cli "$image" --help >/dev/null 2>&1 || fail 'jenkins-plugin-cli is unavailable'

docker run --name "$negative" -d --network none "$image" --httpPort=invalid >/dev/null
negative_code=$(timeout 120 docker wait "$negative") || fail 'invalid httpPort did not stop Jenkins'
[ "$negative_code" != 0 ] || fail 'invalid httpPort unexpectedly succeeded'
docker logs "$negative" 2>&1 | grep -q 'Failed to start a listener' || fail 'invalid httpPort failure was not readable'

headers=$(mktemp)
body=$(mktemp)
trap 'rm -f "$headers" "$body"; cleanup' EXIT INT TERM

start_jenkins() {
  docker run --name "$container" -d -e JAVA_OPTS=-Djenkins.install.runSetupWizard=false \
    -v "$volume:/var/jenkins_home" -p 127.0.0.1::8080 "$image" >/dev/null
  port=$(docker port "$container" 8080/tcp | awk -F: 'NR == 1 { print $2 }')
  [ -n "$port" ] || fail 'published port is missing'
  for _ in $(seq 1 120); do
    status=$(curl -s --connect-timeout 1 --max-time 5 -o "$body" -D "$headers" -w '%{http_code}' "http://127.0.0.1:$port/login" || true)
    [ "$status" != 200 ] || return 0
    sleep 2
  done
  fail 'Jenkins did not become ready'
}

stop_jenkins() {
  docker stop -t 60 "$container" >/dev/null
  code=$(docker inspect -f '{{.State.ExitCode}}' "$container")
  case "$code" in
    0|143) ;;
    *) fail "unexpected exit code $code after SIGTERM" ;;
  esac
  docker rm "$container" >/dev/null
}

start_jenkins
grep -qi 'Sign in to Jenkins\|j_username' "$body" || fail 'login form is missing'
tr -d '\r' <"$headers" | grep -qi "^X-Jenkins: ${recipe_version}\$" || fail 'unexpected X-Jenkins version header'
curl -fsS --connect-timeout 1 --max-time 5 "http://127.0.0.1:$port/api/json" | grep -q '"mode"' || fail 'API did not return Jenkins JSON'

jar=$(mktemp)
crumb=$(curl -fsS --connect-timeout 1 --max-time 5 -c "$jar" "http://127.0.0.1:$port/crumbIssuer/api/json" |
  sed -n 's/.*"crumb":"\([^"]*\)".*/\1/p')
[ -n "$crumb" ] || fail 'CSRF crumb is missing'
curl -fsS --connect-timeout 1 --max-time 30 -b "$jar" -H "Jenkins-Crumb: $crumb" \
  -H 'Content-Type: application/xml' --data '<project><builders/></project>' \
  "http://127.0.0.1:$port/createItem?name=verity-smoke" >/dev/null || fail 'job creation failed'
rm -f "$jar"
stop_jenkins

start_jenkins
curl -fsS --connect-timeout 1 --max-time 5 "http://127.0.0.1:$port/job/verity-smoke/api/json" | grep -q '"name":"verity-smoke"' ||
  fail 'job did not persist across container replacement'
stop_jenkins
printf 'SMOKE PASS version=%s image=%s\n' "$recipe_version" "$image"
