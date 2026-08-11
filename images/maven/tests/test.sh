#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = /home/build ] || fail 'unexpected OCI working directory'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/mvn"]' ] || fail 'unexpected OCI entrypoint'

version=$(docker run --rm --network none "$image" --version) || fail 'mvn --version failed'
printf '%s\n' "$version" | grep -Eq '^Apache Maven 3\.9\.16 ' || fail 'unexpected Maven version'
printf '%s\n' "$version" | grep -Eq '^Java version: 21\.' || fail 'unexpected Java version'

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
cat > "$work/pom.xml" <<'EOF'
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>dev.verity</groupId>
  <artifactId>maven-smoke</artifactId>
  <version>1.0.0</version>
</project>
EOF
chmod -R a+rwX "$work"

docker run --rm --network none -v "$work:/home/build" "$image" -Duser.home=/tmp --offline --batch-mode --no-transfer-progress validate || fail 'offline Maven validation failed'
docker run --rm --network none --entrypoint /usr/lib/jvm/default-jvm/bin/javac "$image" -version || fail 'JDK compiler is unavailable'

printf '<project><broken></project>\n' > "$work/pom.xml"
if output=$(docker run --rm --network none -v "$work:/home/build" "$image" -Duser.home=/tmp --offline --batch-mode --no-transfer-progress validate 2>&1); then
  fail 'malformed pom.xml unexpectedly succeeded'
fi
printf '%s\n' "$output" | grep -F 'Non-parseable POM' >/dev/null || fail 'malformed project did not report a non-parseable POM'
printf '%s\n' "$output" | grep -F 'pom.xml' >/dev/null || fail 'malformed project failure did not identify pom.xml'

printf 'SMOKE PASS\n'
