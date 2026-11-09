#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
# Repository Jenkins LTS image used as the controller fixture. Its version must equal images/jenkins.
jenkins_index='ghcr.io/tektum/jenkins@sha256:03958d7424364f78636f1c0a463073d182d9c586968ddb7a4c57a5a19f682524'
label=verity.test=jenkins-inbound-agent-$$
controller="verity-jenkins-inbound-controller-$$"
env_agent="verity-jenkins-inbound-env-$$"
args_agent="verity-jenkins-inbound-args-$$"
network="verity-jenkins-inbound-net-$$"
tmp=$(mktemp -d)

cleanup() {
  docker rm -fv "$env_agent" "$args_agent" "$controller" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  # The plugin files belong to the Jenkins container user, which may not be the runner user.
  if [ -d "$tmp/plugins" ]; then
    docker run --rm --user 0 --label "$label" --entrypoint sh -v "$tmp/plugins:/plugins" "$image" \
      -c 'rm -rf /plugins/* /plugins/.[!.]*' >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp" || true
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf '%s\n' "$1" >&2
  for name in "$controller" "$env_agent" "$args_agent"; do
    docker logs "$name" 2>&1 | tail -n 30 >&2 || true
  done
  exit 1
}

recipe="$here/../melange.yaml"
remoting=$(sed -n 's/^  upstream-version: \([^ ]*\).*$/\1/p' "$recipe")
[ -n "$remoting" ] || fail 'remoting version is missing from the recipe'
agent_tag=$(sed -n 's/^  docker-agent-tag: \([^ ]*\).*$/\1/p' "$recipe")
case "$agent_tag" in
  "$remoting"-[0-9]*) ;;
  *) fail "launcher release $agent_tag does not package remoting $remoting" ;;
esac
jenkins_version=$(sed -n 's/^  version: "\([^"]*\)".*$/\1/p' "$here/../../jenkins/melange.yaml")
[ -n "$jenkins_version" ] || fail 'Jenkins package version is missing'

# OCI configuration.
[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 1000 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = /home/jenkins ] || fail 'unexpected OCI working directory'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/usr/local/bin/jenkins-agent"]' ] ||
  fail 'unexpected OCI entrypoint'
volumes=$(docker image inspect -f '{{json .Config.Volumes}}' "$image")
printf '%s' "$volumes" | grep -Fq '"/home/jenkins/.jenkins":' || fail '.jenkins volume is missing'
printf '%s' "$volumes" | grep -Fq '"/home/jenkins/agent":' || fail 'agent work directory volume is missing'

# The bundled remoting is the version the Jenkins LTS controller embeds, and the launcher is the upstream script.
[ "$(docker run --rm --network none "$image" -version)" = "$remoting" ] || fail 'agent.jar does not report the recipe remoting version'
[ "$(docker run --rm --network none --entrypoint java "$image" -jar /usr/share/jenkins/slave.jar -version)" = "$remoting" ] ||
  fail 'slave.jar does not report the recipe remoting version'
docker run --rm --network none --entrypoint java "$image" -version 2>&1 | grep -q '"21\.' || fail 'unexpected Java version'
docker run --rm --network none --entrypoint git "$image" --version | grep -q '^git version' || fail 'git is unavailable'
docker run --rm --network none --entrypoint git "$image" lfs version | grep -q '^git-lfs/' || fail 'git-lfs is unavailable'
docker run --rm --network none --entrypoint ssh "$image" -V 2>&1 | grep -q '^OpenSSH' || fail 'ssh is unavailable'
docker run --rm --network none --entrypoint sh "$image" -c 'test -L /usr/local/bin/jenkins-slave && test -d /home/jenkins/agent && test -w /home/jenkins/agent' ||
  fail 'launcher alias or agent work directory is missing'

# Launcher behavior: a single non-option argument runs an alternate command, options start the agent.
docker run --rm --network none "$image" id | grep -q '^uid=1000(jenkins) gid=1000(jenkins)' || fail 'unexpected runtime user'
docker run --rm --network none "$image" -help 2>&1 | grep -q -- '-webSocket' || fail 'agent usage output is missing'
out=$(docker run --rm --network none "$image" -url http://127.0.0.1:1 2>&1 || true)
printf '%s' "$out" | grep -q 'Secret is required for inbound agents' || fail 'missing secret was not rejected'
out=$(docker run --rm --network none -e JENKINS_URL=http://127.0.0.1:1 -e JENKINS_SECRET=0 -e JENKINS_AGENT_NAME=unreachable \
  "$image" -noReconnect 2>&1 || true)
printf '%s' "$out" | grep -q 'Failed to connect to http://127.0.0.1:1/' || fail 'unreachable controller failure was not readable'

# Connect to a real controller over WebSocket (environment variables) and TCP (command-line options).
docker network create --label "$label" "$network" >/dev/null
mkdir -p "$tmp/init.groovy.d"
cat >"$tmp/init.groovy.d/agents.groovy" <<'GROOVY'
import hudson.slaves.DumbSlave
import hudson.slaves.JNLPLauncher
import jenkins.model.Jenkins
import jenkins.slaves.JnlpAgentReceiver

def jenkins = Jenkins.get()
jenkins.setSlaveAgentPort(50000)
jenkins.setNumExecutors(0)
['verity-env', 'verity-args'].each { name ->
  if (jenkins.getNode(name) == null) {
    def agent = new DumbSlave(name, '/home/jenkins/agent', new JNLPLauncher())
    agent.setLabelString(name)
    agent.setNumExecutors(1)
    jenkins.addNode(agent)
  }
  new File(jenkins.getRootDir(), "secret-${name}").text = JnlpAgentReceiver.SLAVE_SECRET.mac(name)
}
GROOVY
chmod 755 "$tmp" "$tmp/init.groovy.d"
chmod 644 "$tmp/init.groovy.d/agents.groovy"

# Without plugins the controller publishes no instance identity, which TCP inbound agents require.
mkdir -p "$tmp/plugins"
chmod 777 "$tmp/plugins"
fetch_plugin() {
  curl -fsSL --retry 3 --retry-all-errors --connect-timeout 10 --max-time 120 -o "$tmp/plugins/$1.jpi" \
    "https://updates.jenkins.io/download/plugins/$1/$2/$1.hpi" || fail "$1 plugin download failed"
  printf '%s  %s\n' "$3" "$tmp/plugins/$1.jpi" | sha256sum -c >/dev/null 2>&1 || fail "$1 plugin checksum mismatch"
}
fetch_plugin instance-identity 203.v15e81a_1b_7a_38 df2b3205a6177248f12b294650a60405f65ba2cd503ca9599b2dcb72c1de5018
fetch_plugin bouncycastle-api 2.30.1.86.2-310.v4655f6742752 57cc5cf1585f9a8f29c5a1e3985f07dace5d5359545d788e72ecaa3636515a58

docker run --name "$controller" -d --label "$label" --network "$network" --network-alias jenkins \
  -e JAVA_OPTS=-Djenkins.install.runSetupWizard=false \
  -v "$tmp/init.groovy.d:/var/jenkins_home/init.groovy.d:ro" -v "$tmp/plugins:/var/jenkins_home/plugins" -p 127.0.0.1::8080 "$jenkins_index" >/dev/null
port=$(docker port "$controller" 8080/tcp | awk -F: 'NR == 1 { print $2 }')
[ -n "$port" ] || fail 'controller port is missing'
base="http://127.0.0.1:$port"
headers="$tmp/headers"
ready=0
for _ in $(seq 1 120); do
  status=$(curl -s --connect-timeout 1 --max-time 5 -o /dev/null -D "$headers" -w '%{http_code}' "$base/login" || true)
  if [ "$status" = 200 ]; then
    ready=1
    break
  fi
  sleep 2
done
[ "$ready" = 1 ] || fail 'Jenkins controller did not become ready'
tr -d '\r' <"$headers" | grep -qi "^X-Jenkins: ${jenkins_version}\$" ||
  fail "controller fixture is not the Jenkins ${jenkins_version} image in images/jenkins; update its digest"

docker cp "$controller:/var/jenkins_home/secret-verity-env" "$tmp/secret-env" >/dev/null || fail 'agent secret for verity-env is missing'
docker cp "$controller:/var/jenkins_home/secret-verity-args" "$tmp/secret-args" >/dev/null || fail 'agent secret for verity-args is missing'
env_secret=$(cat "$tmp/secret-env")
args_secret=$(cat "$tmp/secret-args")
[ -n "$env_secret" ] && [ -n "$args_secret" ] || fail 'agent secret is empty'

docker run --name "$env_agent" -d --label "$label" --network "$network" \
  -e JENKINS_URL=http://jenkins:8080 -e JENKINS_AGENT_NAME=verity-env -e JENKINS_SECRET="$env_secret" \
  -e JENKINS_WEB_SOCKET=true "$image" >/dev/null
docker run --name "$args_agent" -d --label "$label" --network "$network" \
  "$image" -url http://jenkins:8080 -secret "$args_secret" -name verity-args >/dev/null

wait_online() {
  for _ in $(seq 1 90); do
    if curl -fsS --connect-timeout 1 --max-time 5 "$base/computer/$1/api/json" 2>/dev/null | grep -q '"offline":false'; then
      return 0
    fi
    sleep 2
  done
  fail "agent $1 did not connect"
}
wait_online verity-env
wait_online verity-args

jar="$tmp/cookies"
crumb=$(curl -fsS --connect-timeout 1 --max-time 5 -c "$jar" "$base/crumbIssuer/api/json" |
  sed -n 's/.*"crumb":"\([^"]*\)".*/\1/p')
[ -n "$crumb" ] || fail 'CSRF crumb is missing'

# The controller reports the agent remoting version and its own embedded remoting version: all three must match.
for name in verity-env verity-args; do
  versions=$(curl -fsS --connect-timeout 1 --max-time 30 -b "$jar" -H "Jenkins-Crumb: $crumb" \
    --data-urlencode "script=println(jenkins.model.Jenkins.get().getComputer('$name').getSlaveVersion() + ' ' + hudson.remoting.Launcher.VERSION)" \
    "$base/scriptText" | tr -d '\r\n')
  [ "$versions" = "$remoting $remoting" ] ||
    fail "agent $name remoting and controller embedded remoting differ from the recipe: $versions (expected $remoting)"
done

# Run real builds on both agents.
for name in verity-env verity-args; do
  curl -fsS --connect-timeout 1 --max-time 30 -b "$jar" -H "Jenkins-Crumb: $crumb" -H 'Content-Type: application/xml' \
    --data "<project><assignedNode>$name</assignedNode><canRoam>false</canRoam><builders><hudson.tasks.Shell><command>echo agent-uid=\$(id -u); echo agent-java=\$(java -version 2>&amp;1 | head -n 1); git --version</command></hudson.tasks.Shell></builders></project>" \
    "$base/createItem?name=job-$name" >/dev/null || fail "job creation failed for $name"
  curl -fsS --connect-timeout 1 --max-time 30 -b "$jar" -H "Jenkins-Crumb: $crumb" -X POST \
    "$base/job/job-$name/build?delay=0sec" >/dev/null || fail "build trigger failed for $name"
  finished=0
  for _ in $(seq 1 60); do
    if curl -fsS --connect-timeout 1 --max-time 5 "$base/job/job-$name/1/api/json" 2>/dev/null | grep -q '"result":"SUCCESS"'; then
      finished=1
      break
    fi
    sleep 2
  done
  [ "$finished" = 1 ] || fail "build on $name did not succeed"
  console=$(curl -fsS --connect-timeout 1 --max-time 10 "$base/job/job-$name/1/consoleText")
  printf '%s' "$console" | grep -q "Building remotely on $name in workspace /home/jenkins/agent/workspace/job-$name" ||
    fail "build did not run on agent $name: $console"
  printf '%s' "$console" | grep -q '^agent-uid=1000$' || fail "build on $name ran as the wrong user"
  printf '%s' "$console" | grep -q '^agent-java=.*"21\.' || fail "build on $name did not see Java 21"
  printf '%s' "$console" | grep -q '^git version' || fail "build on $name did not see git"
done

# Both agents stop cleanly on SIGTERM.
docker stop -t 30 "$env_agent" "$args_agent" >/dev/null
for name in "$env_agent" "$args_agent"; do
  code=$(docker inspect -f '{{.State.ExitCode}}' "$name")
  case "$code" in
    0|143) ;;
    *) fail "unexpected exit code $code from $name after SIGTERM" ;;
  esac
done
printf 'SMOKE PASS remoting=%s jenkins=%s image=%s\n' "$remoting" "$jenkins_version" "$image"
