#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = /home/bazel ] || fail 'unexpected OCI working directory'
if ! version=$(docker run --rm --network none "$image" --version); then
  fail 'bazel --version failed'
fi
printf '%s\n' "$version" | grep -Eq '^bazel 9\.' || fail 'unexpected Bazel version'
docker run --rm --network none --entrypoint /bin/bash "$image" -c ': > /home/bazel/.writable' || fail '/home/bazel is not writable'

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
chmod 777 "$work"
: > "$work/MODULE.bazel"
cat > "$work/BUILD.bazel" <<'EOF'
genrule(
    name = "artifact",
    outs = ["artifact.txt"],
    cmd = "printf 'bazel-smoke\\n' > $@",
)
EOF
chmod 666 "$work/BUILD.bazel"
docker run --rm -v "$work:/home/bazel" --entrypoint /bin/bash "$image" -eu -c '
  bazel --output_user_root=/tmp/bazel build --color=no --noshow_progress //:artifact
  artifact=$(<bazel-bin/artifact.txt)
  [ "$artifact" = bazel-smoke ] || {
    printf "%s\n" "unexpected Bazel artifact: $artifact" >&2
    exit 1
  }

  printf "genrule(name =\n" > BUILD.bazel
  if negative_output=$(bazel --output_user_root=/tmp/bazel build --color=no --noshow_progress //:artifact 2>&1); then
    printf "%s\n" "$negative_output"
    printf "%s\n" "broken BUILD.bazel unexpectedly succeeded" >&2
    exit 1
  fi
  printf "%s\n" "$negative_output"
  case "$negative_output" in
    *BUILD.bazel*) ;;
    *)
      printf "%s\n" "failure did not identify BUILD.bazel" >&2
      exit 1
      ;;
  esac
' || fail 'deterministic Bazel build failed'
