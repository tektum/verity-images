#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
config="$(dirname "$0")/../apko.yaml"
version=$(sed -n 's/^    - sbt=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
work=$(mktemp -d)

trap 'rm -rf "$work"' EXIT INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -n "$version" ] || fail 'could not read the pinned sbt version'
case $version in
  2.0.*) ;;
  *) fail "pinned sbt $version is outside the published 2.0 stream" ;;
esac

inspect() {
  docker image inspect --format "$1" "$image"
}

[ "$(inspect '{{.Config.User}}')" = 65532 ] || fail 'unexpected OCI user'
[ "$(inspect '{{.Config.WorkingDir}}')" = /work ] || fail 'unexpected OCI working directory'
[ "$(inspect '{{json .Config.Entrypoint}}')" = '["/usr/bin/sbt"]' ] || fail 'unexpected OCI entrypoint'
inspect '{{range .Config.Env}}{{println .}}{{end}}' >"$work/env"
grep -Fx 'HOME=/home/build' "$work/env" >/dev/null || fail 'HOME is not /home/build'
grep -Fx 'JAVA_HOME=/usr/lib/jvm/default-jvm' "$work/env" >/dev/null || fail 'JAVA_HOME is not the bundled JDK'

# The runner script reports its own version without starting a JVM.
script_version=$(docker run --rm --network none "$image" --script-version) ||
  fail 'sbt --script-version failed'
[ "$script_version" = "$version" ] || fail "--script-version reported '$script_version', expected $version"

# --version probes the JDK before printing the runner version.
docker run --rm --network none "$image" -v --version >"$work/version" 2>&1 ||
  fail "sbt --version failed: $(cat "$work/version")"
grep -Fx "sbt runner version: $version" "$work/version" >/dev/null ||
  fail "sbt --version does not report $version: $(cat "$work/version")"
grep -F "java_version = '17'" "$work/version" >/dev/null ||
  fail "runner did not detect the bundled JDK 17: $(cat "$work/version")"

docker run --rm --network none --entrypoint /usr/lib/jvm/default-jvm/bin/java "$image" -version >"$work/java" 2>&1 ||
  fail 'bundled java is not runnable'
grep -E '^openjdk version "17\.' "$work/java" >/dev/null || fail "bundled JDK is not 17: $(cat "$work/java")"
docker run --rm --network none --entrypoint /usr/lib/jvm/default-jvm/bin/javac "$image" -version >"$work/javac" 2>&1 ||
  fail 'bundled javac is not runnable'
grep -E '^javac 17\.' "$work/javac" >/dev/null || fail "bundled javac is not 17: $(cat "$work/javac")"

# The native client for this architecture is bundled and executes.
docker run --rm --network none --entrypoint /bin/sh "$image" -c \
  'sbtn=/usr/share/java/sbt/bin/sbtn-$(uname -m)-pc-linux; test -x "$sbtn" && cd /tmp && "$sbtn" --help' \
  >"$work/sbtn" 2>&1 || true
grep -F 'entering thin client' "$work/sbtn" >/dev/null || fail "bundled sbtn did not start: $(cat "$work/sbtn")"

# HOME and the sbt, Ivy, and Coursier caches belong to the runtime user.
docker run --rm --network none --entrypoint /bin/sh "$image" -c '
  for dir in /work /home/build /home/build/.sbt /home/build/.ivy2 /home/build/.cache/coursier /home/build/.cache/sbt; do
    [ "$(stat -c %u:%g "$dir")" = 65532:65532 ] || { echo "$dir is not owned by 65532"; exit 1; }
    : >"$dir/.write-probe" || { echo "$dir is not writable"; exit 1; }
  done' >"$work/owner" 2>&1 || fail "cache directories are not writable: $(cat "$work/owner")"

# A real project build. sbt-launch.jar only bootstraps sbt; sbt itself, the
# Scala compiler, and zinc come from Maven Central at first use, so without a
# network the launcher must start on the bundled JDK, write its boot and
# Coursier caches as 65532, and fail only on artifact resolution.
mkdir -p "$work/project/project" "$work/project/src/main/scala"
printf 'sbt.version=%s\n' "$version" >"$work/project/project/build.properties"
printf 'scalaVersion := "3.3.6"\n' >"$work/project/build.sbt"
printf '@main def hello(): Unit = println("sbt smoke")\n' >"$work/project/src/main/scala/Hello.scala"
chmod -R a+rwX "$work/project"

rc=0
docker run --rm --network none -v "$work/project:/work" --entrypoint /bin/sh "$image" -c '
  sbt -batch compile
  rc=$?
  echo "probe: rc=$rc"
  for path in /home/build/.sbt/boot/sbt.boot.lock /home/build/.cache/coursier/v1/https; do
    [ -e "$path" ] && echo "probe: wrote $path"
  done
  ls -d /home/build/.sbt/1.0/java9-rt-ext-*/rt.jar 2>/dev/null | sed "s/^/probe: wrote /"
  exit "$rc"' >"$work/build" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'offline build unexpectedly resolved sbt without a network'
grep -F 'entering thin client' "$work/build" >/dev/null || fail 'sbt 2 project did not use the native client'
grep -F "getting org.scala-sbt sbt $version" "$work/build" >/dev/null ||
  fail "launcher did not try to boot sbt $version: $(cat "$work/build")"
grep -F 'UnknownHostException' "$work/build" >/dev/null ||
  fail "offline build did not fail on resolution: $(cat "$work/build")"
if grep -iE 'permission denied|AccessDeniedException|read-only file system' "$work/build" >/dev/null; then
  fail "offline build hit a filesystem permission error: $(cat "$work/build")"
fi
for path in /home/build/.sbt/boot/sbt.boot.lock /home/build/.cache/coursier/v1/https; do
  grep -Fx "probe: wrote $path" "$work/build" >/dev/null || fail "launcher did not write $path"
done
grep -E '^probe: wrote /home/build/\.sbt/1\.0/java9-rt-ext-.*/rt\.jar$' "$work/build" >/dev/null ||
  fail 'runner did not export the JDK runtime into HOME'

# Negative cases: a malformed option and a directory without a build.
rc=0
docker run --rm --network none "$image" -mem >"$work/invalid" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'sbt -mem without a value unexpectedly succeeded'
grep -F -- '-mem requires <integer> argument' "$work/invalid" >/dev/null ||
  fail "invalid option diagnostic is missing: $(cat "$work/invalid")"

rc=0
docker run --rm --network none "$image" -batch compile >"$work/empty" 2>&1 </dev/null || rc=$?
[ "$rc" -ne 0 ] || fail 'build in an empty working directory unexpectedly succeeded'
grep -F "Neither build.sbt nor a 'project' directory in the current directory: /work" "$work/empty" >/dev/null ||
  fail "empty directory diagnostic is missing: $(cat "$work/empty")"

printf 'SMOKE PASS image=%s sbt=%s\n' "$image" "$version"
