#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE [FLAVOR]}
flavor=${2:-plain}

case "$flavor" in
  plain|jre) ;;
  *) printf 'usage: test.sh IMAGE [plain|jre]\n' >&2; exit 2 ;;
esac

envs=$(docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image")
printf '%s\n' "$envs" | grep -qx 'JAVA_HOME=/usr/lib/jvm/java-17-openjdk'
printf '%s\n' "$envs" | grep -qx 'PATH=/usr/lib/jvm/java-17-openjdk/bin:/usr/bin:/bin'
printf '%s\n' "$envs" | grep -qx 'LANG=en_US.UTF-8'
printf '%s\n' "$envs" | grep -qx 'LC_ALL=en_US.UTF-8'
printf '%s\n' "$envs" | grep -qx 'TZ=UTC'
[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ]
[ "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /app ]

properties=$(docker run --rm "$image" java -XshowSettings:properties -version 2>&1)
printf '%s\n' "$properties" | grep -Eq '^[[:space:]]*java.specification.version = 17$'
printf '%s\n' "$properties" | grep -Eq '^[[:space:]]*file.encoding = UTF-8$'
printf '%s\n' "$properties" | grep -Eq '^[[:space:]]*user.language = en$'
printf '%s\n' "$properties" | grep -Eq '^[[:space:]]*user.country = US$'
printf '%s\n' "$properties" | grep -Eq '^[[:space:]]*user.timezone = UTC$'
docker run --rm "$image" keytool -list -cacerts -storepass changeit >/dev/null
docker run --rm "$image" fc-list | grep -q .

if [ "$flavor" = jre ]; then
  if docker run --rm "$image" javac -version; then
    exit 1
  fi
  exit 0
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
docker run --network none --rm -v "$work:/work" -w /work "$image" javac Hello.java
[ "$(docker run --network none --rm -v "$work:/work:ro" -w /work "$image" java Hello)" = 'Hello World' ]
