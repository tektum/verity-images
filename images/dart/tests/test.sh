#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
label="verity-test=dart-$$"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT INT TERM

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/dart"]' ] || fail 'wrong entrypoint'
[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 ] || fail 'wrong user'
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = /app ] || fail 'wrong work directory'

version=$(docker run --rm --label "$label" --network none "$image" --version)
printf '%s\n' "$version"
case "$version" in
  'Dart SDK version: 3.13.'*) ;;
  *) fail "unexpected dart version: $version" ;;
esac

cat > "$fixture/main.dart" <<'DART'
import 'dart:io';

void main(List<String> args) {
  final sum = List<int>.generate(10, (i) => i + 1).fold<int>(0, (a, b) => a + b);
  stdout.writeln('verity dart ${args.join(",")} $sum');
}
DART
cat > "$fixture/broken.dart" <<'DART'
void main() {
  int x = 'not an int';
  print(x
}
DART
chmod 755 "$fixture"
chmod 644 "$fixture/main.dart" "$fixture/broken.dart"

# dart create scaffolds a console app (no network: skip pub get) as the non-root user.
created=$(docker run --rm --label "$label" --network none --tmpfs /app:exec,uid=65532,gid=65532 \
  --entrypoint /bin/sh "$image" -c 'dart create --no-pub -t console hello >/dev/null && ls hello/bin hello/pubspec.yaml')
printf '%s\n' "$created" | grep -qx 'hello.dart' || fail "dart create did not scaffold bin/hello.dart: $created"

# JIT run.
out=$(docker run --rm --label "$label" --network none -v "$fixture:/fixture:ro" \
  "$image" run /fixture/main.dart a b)
[ "$out" = 'verity dart a,b 55' ] || fail "dart run output: got '$out'"

# AOT compile to a native executable and run it.
out=$(docker run --rm --label "$label" --network none --tmpfs /app:exec,uid=65532,gid=65532 \
  -v "$fixture:/fixture:ro" --entrypoint /bin/sh "$image" \
  -c 'dart compile exe /fixture/main.dart -o /app/main >/dev/null && /app/main native')
[ "$out" = 'verity dart native 55' ] || fail "compiled executable output: got '$out'"

# Negative: a program with errors must fail to run and to analyze, with a readable diagnostic.
status=0
err=$(docker run --rm --label "$label" --network none -v "$fixture:/fixture:ro" \
  "$image" run /fixture/broken.dart 2>&1) || status=$?
[ "$status" -ne 0 ] || fail 'dart run accepted a broken program'
printf '%s\n' "$err" | grep -q 'broken.dart' || fail "no diagnostic naming broken.dart: $err"

status=0
err=$(docker run --rm --label "$label" --network none -v "$fixture:/fixture:ro" \
  "$image" analyze /fixture/broken.dart 2>&1) || status=$?
[ "$status" -ne 0 ] || fail 'dart analyze accepted a broken program'
printf '%s\n' "$err" | grep -qi 'error' || fail "analyze printed no error: $err"
