#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE [FLAVOR]}
flavor=${2:-plain}
[ "$flavor" = plain ] || { echo "unexpected flavor: $flavor" >&2; exit 1; }

[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/rustc"]' ] || { echo 'unexpected entrypoint' >&2; exit 1; }
[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 ] || { echo 'unexpected user' >&2; exit 1; }
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = /app ] || { echo 'unexpected working directory' >&2; exit 1; }
env=$(docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$image")
for value in \
  'RUST_BACKTRACE=1' \
  'CARGO_HOME=/usr/local/cargo' \
  'PATH=/usr/local/cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'; do
  printf '%s\n' "$env" | grep -Fx "$value" >/dev/null || { echo "missing environment: $value" >&2; exit 1; }
done

docker run --rm --network none --entrypoint /bin/sh "$image" -c '
  [ "$(id -u)" = 65532 ]
  [ "$(id -g)" = 65532 ]
  [ -w /app ]
  [ -w /usr/local/cargo ]
'
docker run --rm --network none "$image" --version | grep -q '^rustc 1\.86\.' || { echo 'unexpected rustc version' >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
chmod 777 "$work"
cat >"$work/hello.rs" <<'EOF'
fn main() {
    println!("Hello World");
}
EOF
docker run --rm --network none -v "$work:/app" "$image" hello.rs -o hello
[ "$(docker run --rm --network none -v "$work:/app:ro" --entrypoint /app/hello "$image")" = 'Hello World' ] || { echo 'unexpected Hello World output' >&2; exit 1; }

printf '%s\n' 'fn main( {' >"$work/invalid.rs"
if docker run --rm --network none -v "$work:/app" "$image" invalid.rs -o invalid >/dev/null 2>&1; then
  echo 'malformed Rust compiled successfully' >&2
  exit 1
fi

printf '%s\n' 'SMOKE PASS'
