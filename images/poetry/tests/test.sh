#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
config="$(dirname "$0")/../apko.yaml"
version=$(sed -n 's/^    - py3\.13-poetry-bin=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
volume="poetry-smoke-$$"
work=$(mktemp -d)

cleanup() {
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ -n "$version" ] || fail 'could not read the pinned poetry version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/poetry"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

docker run --rm --network none "$image" --version >"$work/version" 2>&1 ||
  fail 'version failed'
grep -Fx "Poetry (version $version)" "$work/version" >/dev/null ||
  fail "version does not report $version: $(cat "$work/version")"

rc=0
docker run --rm --network none "$image" --definitely-invalid >"$work/flag" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid flag unexpectedly succeeded'
grep -F 'The option "--definitely-invalid" does not exist' "$work/flag" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/flag")"

# The project lives in a volume owned by the runtime user; every step is offline.
docker volume create "$volume" >/dev/null || fail 'volume creation failed'
poetry() {
  dir=$1
  shift
  docker run --rm --network none -e POETRY_VIRTUALENVS_IN_PROJECT=true \
    -v "$volume:/work" -w "$dir" "$image" "$@"
}
python() {
  docker run --rm --network none -v "$volume:/work" -w /work/demo \
    --entrypoint /usr/bin/python3.13 "$image" "$@"
}

poetry /work new demo >"$work/new" 2>&1 || fail "poetry new failed: $(cat "$work/new")"
grep -Fx 'Created package demo in demo' "$work/new" >/dev/null ||
  fail "poetry new output is unexpected: $(cat "$work/new")"

poetry /work/demo check >"$work/check" 2>&1 || fail "poetry check failed: $(cat "$work/check")"
grep -Fx 'All set!' "$work/check" >/dev/null || fail "poetry check output: $(cat "$work/check")"

poetry /work/demo version minor >"$work/bump" 2>&1 || fail "poetry version failed: $(cat "$work/bump")"
grep -Fx 'Bumping version from 0.1.0 to 0.2.0' "$work/bump" >/dev/null ||
  fail "poetry version output is unexpected: $(cat "$work/bump")"

poetry /work/demo lock >"$work/lock" 2>&1 || fail "poetry lock failed: $(cat "$work/lock")"
poetry /work/demo check --lock >"$work/check-lock" 2>&1 ||
  fail "poetry check --lock failed: $(cat "$work/check-lock")"

poetry /work/demo install >"$work/install" 2>&1 || fail "poetry install failed: $(cat "$work/install")"
grep -F 'Installing the current project: demo (0.2.0)' "$work/install" >/dev/null ||
  fail "poetry install output is unexpected: $(cat "$work/install")"
poetry /work/demo run python -c 'import demo, sys; print(demo.__file__); print(sys.prefix)' \
  >"$work/run" 2>&1 || fail "poetry run failed: $(cat "$work/run")"
grep -Fx '/work/demo/src/demo/__init__.py' "$work/run" >/dev/null ||
  fail "the project was not installed in development mode: $(cat "$work/run")"
grep -Fx '/work/demo/.venv' "$work/run" >/dev/null ||
  fail "poetry run did not use the project virtualenv: $(cat "$work/run")"

poetry /work/demo build >"$work/build" 2>&1 || fail "poetry build failed: $(cat "$work/build")"
python -c '
import tarfile, zipfile
wheel = zipfile.ZipFile("dist/demo-0.2.0-py3-none-any.whl")
assert "demo/__init__.py" in wheel.namelist(), wheel.namelist()
meta = wheel.read("demo-0.2.0.dist-info/METADATA").decode()
assert "Name: demo" in meta and "Version: 0.2.0" in meta, meta
with tarfile.open("dist/demo-0.2.0.tar.gz") as sdist:
    assert "demo-0.2.0/pyproject.toml" in sdist.getnames(), sdist.getnames()
print("artifacts ok")
' >"$work/artifacts" 2>&1 || fail "built artifacts are invalid: $(cat "$work/artifacts")"

# Adding a dependency needs the package index, so it must fail cleanly offline.
rc=0
poetry /work/demo add requests >"$work/add" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'offline poetry add unexpectedly succeeded'

printf 'SMOKE PASS\n'
