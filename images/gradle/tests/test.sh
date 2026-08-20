#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
: "${IMAGE_VERSION:?IMAGE_VERSION is required}"
fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = /home/gradle ] || fail 'unexpected OCI working directory'
version=$(docker run --rm --network none "$image" --version) || fail 'gradle --version failed'
printf '%s\n' "$version" | grep -q "^Gradle ${IMAGE_VERSION}$" || fail 'unexpected Gradle version'
docker run --rm --network none --entrypoint /bin/sh "$image" -c \
  'test -r /usr/share/licenses/gradle/LICENSE' || fail 'Gradle license is missing'

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
mkdir -p "$work/src/main/java"
cat >"$work/settings.gradle" <<'EOF'
rootProject.name = 'verity-smoke'
EOF
cat >"$work/build.gradle" <<'EOF'
plugins { id 'application' }
application { mainClass = 'Smoke' }
layout.buildDirectory = file('/tmp/gradle-build')
EOF
cat >"$work/src/main/java/Smoke.java" <<'EOF'
class Smoke {
  public static void main(String[] args) {
    System.out.println("gradle-smoke");
  }
}
EOF
chmod -R a+rwX "$work"

output=$(docker run --rm --network none -e GRADLE_USER_HOME=/tmp/gradle-home \
  -v "$work:/src:ro" --entrypoint /bin/sh "$image" -eu -c \
  'cp -R /src /tmp/project; cd /tmp/project; exec gradle --offline --no-daemon --console=plain run') \
  || fail 'offline Java build failed'
printf '%s\n' "$output" | grep -q '^gradle-smoke$' || fail 'compiled Java program did not run'

printf '%s\n' "plugins { id 'java'" >"$work/build.gradle"
if output=$(docker run --rm --network none -e GRADLE_USER_HOME=/tmp/gradle-home \
  -v "$work:/src:ro" --entrypoint /bin/sh "$image" -eu -c \
  'cp -R /src /tmp/project; cd /tmp/project; exec gradle --offline --no-daemon --console=plain help' 2>&1); then
  printf '%s\n' "$output"
  fail 'malformed build.gradle unexpectedly succeeded'
fi
printf '%s\n' "$output" | grep -q 'build.gradle' || fail 'failure did not identify build.gradle'

printf "SMOKE PASS version=${IMAGE_VERSION} image=%s\n" "$image"
