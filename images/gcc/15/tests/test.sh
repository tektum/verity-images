#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = /usr/src ]
docker run --rm --network none "$image" --version | grep -q ' 15\.'

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
cat > "$work/smoke.c" <<'EOF'
#include <stdio.h>

int main(void) {
  puts("SMOKE PASS");
  return 0;
}
EOF
docker run --rm --network none -v "$work:/usr/src" "$image" -std=c17 -Wall -Werror smoke.c -o smoke
[ "$(docker run --rm --network none --entrypoint /usr/src/smoke -v "$work:/usr/src:ro" "$image")" = 'SMOKE PASS' ]

printf 'int main(void) { this is invalid C; }\n' > "$work/invalid.c"
if docker run --rm --network none -v "$work:/usr/src" "$image" invalid.c -o invalid >/dev/null 2>&1; then
  exit 1
fi
printf 'SMOKE PASS\n'
