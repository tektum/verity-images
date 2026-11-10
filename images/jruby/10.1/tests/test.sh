#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
label="verity-test=jruby-$$"
stream=10.1
ruby_compat=4.0
java_major=21

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

run() {
  docker run --rm --label "$label" --network none "$@"
}

[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/jruby"]' ] || fail 'wrong entrypoint'
[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 ] || fail 'wrong user'
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = /app ] || fail 'wrong work directory'
docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$image" |
  grep -qx "JAVA_HOME=/usr/lib/jvm/java-$java_major-openjdk" || fail 'wrong JAVA_HOME'
docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$image" |
  grep -qx 'JRUBY_OPTS=--nocache' || fail 'wrong JRUBY_OPTS'

version=$(run "$image" -v 2>&1)
case "$version" in
  *Warning*) fail "jruby -v printed a warning: $version" ;;
esac
printf '%s\n' "$version"
case "$version" in
  "jruby $stream."*"(${ruby_compat}."*") "*) ;;
  *) fail "unexpected jruby -v: $version" ;;
esac

# The bundled JRE is the one JRuby runs on, and Ruby code can call into it.
out=$(run "$image" -e 'require "java"; puts java.lang.System.getProperty("java.specification.version"); puts 1 + 1')
[ "$out" = "$java_major
2" ] || fail "java integration output: got '$out'"
[ "$(run --entrypoint "/usr/lib/jvm/java-$java_major-openjdk/bin/java" "$image" -version 2>&1 | head -1 | cut -d'"' -f2 | cut -d. -f1)" = "$java_major" ] ||
  fail 'bundled JRE is not Java '"$java_major"

# Default gems and rubygems tooling work (-S resolves through the jruby launcher).
gems=$(run "$image" -S gem list 2>&1)
for gem in bundler json rake; do
  printf '%s\n' "$gems" | grep -q "^$gem " || fail "default gem missing from gem list: $gem"
done
run "$image" -rjson -ropenssl -e 'puts JSON.generate({"ok" => OpenSSL::Digest::SHA256.hexdigest("x").size})' |
  grep -qx '{"ok":64}' || fail 'json/openssl stdlib failed'
[ "$(run "$image" -S rake --version 2>&1 | cut -d' ' -f1-2)" = 'rake, version' ] || fail 'rake is not runnable'

# Non-root can write the work directory.
run --tmpfs /app:uid=65532,gid=65532 "$image" -e 'File.write("/app/x", "ok"); puts File.read("/app/x")' |
  grep -qx ok || fail 'work directory is not writable by the runtime user'

# Negative: a syntax error and an uncaught exception must exit non-zero with a diagnostic.
status=0
err=$(run "$image" -e 'def broken(' 2>&1) || status=$?
[ "$status" -ne 0 ] || fail 'jruby accepted a syntax error'
printf '%s\n' "$err" | grep -qi 'syntax' || fail "no syntax diagnostic: $err"
status=0
run "$image" -e 'raise "boom"' >/dev/null 2>&1 || status=$?
[ "$status" -ne 0 ] || fail 'uncaught exception exited zero'
