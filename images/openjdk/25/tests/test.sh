#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE [FLAVOR]}
flavor=${2:-plain}
metadata=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)/metadata.yaml
supported_version=$(awk -F '[][]' '/^versions:/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' "$metadata")
expected_runtime_prefix=${supported_version}.
case "$flavor" in
  plain|jre) ;;
  *) exit 2 ;;
esac

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 ]
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = /app ]
env=$(docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$image")
for value in \
  'JAVA_HOME=/usr/lib/jvm/java-25-openjdk' \
  'PATH=/usr/lib/jvm/java-25-openjdk/bin:/usr/bin:/bin' \
  'LANG=en_US.UTF-8' \
  'LC_ALL=en_US.UTF-8' \
  'TZ=UTC'; do
  printf '%s\n' "$env" | grep -Fx "$value" >/dev/null
done

properties=$(docker run --rm --network none "$image" java -XshowSettings:properties -version 2>&1)
property() {
  printf '%s\n' "$properties" | awk -F ' = ' -v key="$1" '
    { name = $1; sub(/^[[:space:]]*/, "", name); if (name == key) print $2 }
  '
}
runtime=$(property java.runtime.version)
case "$runtime" in
  "${expected_runtime_prefix}"*-wolfi-r[0-9]*) ;;
  *) exit 1 ;;
esac
[ "$(property java.specification.version)" = "$supported_version" ]
[ "$(property file.encoding)" = UTF-8 ]
[ "$(property user.language)" = en ]
[ "$(property user.country)" = US ]
docker run --rm --network none "$image" keytool -list -cacerts -storepass changeit >/dev/null
docker run --rm --network none "$image" fc-list 2>/dev/null | grep -q .

if [ "$flavor" = jre ]; then
  if docker run --rm --network none "$image" javac -version >/dev/null 2>&1; then
    exit 1
  fi
  exit
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
chmod 777 "$work"
cat > "$work/Hello.java" <<'EOF'
class Hello {
  public static void main(String[] args) {
    System.out.println("Hello World");
    System.out.println(java.time.ZoneId.systemDefault());
  }
}
EOF
docker run --rm --network none -v "$work:/app" -w /app "$image" javac Hello.java
[ "$(docker run --rm --network none -v "$work:/app:ro" -w /app "$image" java Hello)" = 'Hello World
UTC' ]
