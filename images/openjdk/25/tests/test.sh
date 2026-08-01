#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE [FLAVOR]}
flavor=${2:-plain}
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
for value in \
  'java.specification.version = 25' \
  'file.encoding = UTF-8' \
  'user.language = en' \
  'user.country = US' \
  'user.timezone = UTC'; do
  printf '%s\n' "$properties" | grep -Fqx "    $value" >/dev/null
done
docker run --rm --network none "$image" keytool -list -cacerts -storepass changeit >/dev/null
docker run --rm --network none "$image" fc-list | grep -q .

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
  }
}
EOF
docker run --rm --network none -v "$work:/app" -w /app "$image" javac Hello.java
[ "$(docker run --rm --network none -v "$work:/app" -w /app "$image" java Hello)" = 'Hello World' ]
