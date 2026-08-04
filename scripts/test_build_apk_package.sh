#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
script=$root/scripts/build_apk_package.sh
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM
repository=$work_dir/repository
mkdir -p "$repository/scripts" "$repository/packages/openssl-fips-provider" "$work_dir/bin" "$work_dir/tmp"
export TMPDIR=$work_dir/tmp
cp "$script" "$repository/scripts/"
cp "$root/packages/openssl-fips-provider/melange.yaml" "$repository/packages/openssl-fips-provider/"
cat > "$repository/scripts/test_fips_runtime.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" > "${RUNTIME_RECORD:?}"
EOF
chmod +x "$repository/scripts/test_fips_runtime.sh"

cat > "$work_dir/bin/melange" <<'EOF'
#!/bin/bash
set -euo pipefail
command=${1:?}
shift
case "$command" in
  build)
    recipe=$1
    shift
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --arch) architecture=$2; shift 2 ;;
        --out-dir) out_dir=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    case "${FAKE_MODE:-success}" in
      misleading)
        printf 'build succeeded\n'
        exit 1
        ;;
      interrupt)
        kill -TERM "$PPID"
        exit 143
        ;;
    esac
    mkdir -p "$out_dir"
    make_apk() {
      local path=$1 name=$2 temporary
      temporary=$(mktemp -d)
      version=3.1.2-r3
      [[ "${FAKE_MODE:-}" == unsafe-version && "$name" == openssl-fips-provider ]] && version=bad/name
      printf 'pkgname = %s\npkgver = %s\narch = %s\n' "$name" "$version" "$architecture" > "$temporary/.PKGINFO"
      if [[ "${FAKE_MODE:-}" == duplicate-metadata && "$name" == openssl-fips-provider ]]; then
        printf 'pkgver = 3.1.2-r4\n' >> "$temporary/.PKGINFO"
      fi
      tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -C "$temporary" -czf "$path" .PKGINFO
      rm -rf "$temporary"
    }
    make_apk "$out_dir/openssl-fips-provider-3.1.2-r3.apk" openssl-fips-provider
    make_apk "$out_dir/openssl-fips-provider-doc-3.1.2-r3.apk" openssl-fips-provider-doc
    if [[ "${FAKE_MODE:-}" == duplicate ]]; then
      make_apk "$out_dir/duplicate.apk" openssl-fips-provider
    elif [[ "${FAKE_MODE:-}" == alter-recipe ]]; then
      printf '# altered\n' >> "$recipe"
      GIT_MASTER=1 git update-index --assume-unchanged "$recipe"
    elif [[ "${FAKE_MODE:-}" == advance-head ]]; then
      printf 'advanced\n' > packages/openssl-fips-provider/source.txt
      GIT_MASTER=1 git add packages/openssl-fips-provider/source.txt
      GIT_MASTER=1 git commit -qm advanced
    elif [[ "${FAKE_MODE:-}" == break-git ]]; then
      mv .git "$TMPDIR/git-hidden"
    fi
    ;;
  keygen)
    printf private > "$1"
    printf public > "$1.pub"
    ;;
  sign) ;;
  index)
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == --output ]]; then
        printf index > "$2"
        break
      fi
      shift
    done
    ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$work_dir/bin/melange"

cat > "$work_dir/bin/mv" <<'EOF'
#!/bin/bash
set -euo pipefail
/bin/mv "$@"
if [[ "${FAKE_MODE:-}" == interrupt-after-publish && "$2" == artifact ]]; then
  kill -TERM "$PPID"
fi
EOF
chmod +x "$work_dir/bin/mv"

GIT_MASTER=1 git -C "$repository" init -q
GIT_MASTER=1 git -C "$repository" config user.email test@example.com
GIT_MASTER=1 git -C "$repository" config user.name Test
GIT_MASTER=1 git -C "$repository" add .
GIT_MASTER=1 git -C "$repository" commit -qm baseline

run_build() {
  (
    cd "$repository"
    PATH="$work_dir/bin:$PATH" RUNTIME_RECORD="$work_dir/runtime" \
      bash scripts/build_apk_package.sh "$@"
  )
}

bash -n "$script"
if run_build 2>/dev/null; then
  printf 'missing arguments were accepted\n' >&2
  exit 1
fi

native=$(uname -m)
case "$native" in
  x86_64) foreign=aarch64 ;;
  aarch64) foreign=x86_64 ;;
  *) printf 'unsupported test host: %s\n' "$native" >&2; exit 1 ;;
esac

run_build openssl-fips-provider "$native"
test "$(find "$repository/artifact" -maxdepth 1 -type f | wc -l)" -eq 3
test -f "$repository/artifact/openssl-fips-provider-3.1.2-r3.apk"
(cd "$repository/artifact" && sha256sum -c SHA256SUMS)
source_sha=$(GIT_MASTER=1 git -C "$repository" rev-parse HEAD)
recipe_sha=$(sha256sum "$repository/packages/openssl-fips-provider/melange.yaml" | cut -d' ' -f1)
apk_sha=$(sha256sum "$repository/artifact/openssl-fips-provider-3.1.2-r3.apk" | cut -d' ' -f1)
jq -e --arg architecture "$native" --arg source_sha "$source_sha" \
  --arg recipe_sha "$recipe_sha" --arg apk_sha "$apk_sha" '
  . == {
    architecture: $architecture,
    identity: {name: "openssl-fips-provider", version: "3.1.2-r3"},
    recipe: {path: "packages/openssl-fips-provider/melange.yaml", sha256: $recipe_sha},
    sourceSha: $source_sha,
    unsignedApkSha256: $apk_sha
  }
' "$repository/artifact/metadata.json" >/dev/null
test -s "$work_dir/runtime"
test -z "$(find "$TMPDIR" -mindepth 1 -print -quit)"
first_metadata=$(sha256sum "$repository/artifact/metadata.json")
run_build openssl-fips-provider "$native"
test "$(sha256sum "$repository/artifact/metadata.json")" = "$first_metadata"

assert_failure_without_artifact() {
  rm -rf "$repository/artifact"
  mkdir "$repository/artifact"
  printf stale > "$repository/artifact/stale.apk"
  if "$@"; then
    printf 'expected failure: %s\n' "$*" >&2
    exit 1
  else
    status=$?
  fi
  if [[ -n "${EXPECTED_STATUS:-}" && "$status" -ne "$EXPECTED_STATUS" ]]; then
    printf 'expected status %s: %s\n' "$EXPECTED_STATUS" "$*" >&2
    exit 1
  fi
  test ! -e "$repository/artifact"
  test -z "$(find "$repository" -maxdepth 1 -name '.artifact.*' -print -quit)"
  test -z "$(find "$TMPDIR" -mindepth 1 -print -quit)"
}

assert_failure_without_artifact run_build ../../images/caddy "$native"
assert_failure_without_artifact run_build missing-package "$native"
assert_failure_without_artifact run_build openssl-fips-provider "$foreign"
FAKE_MODE=duplicate assert_failure_without_artifact run_build openssl-fips-provider "$native"
FAKE_MODE=duplicate-metadata assert_failure_without_artifact run_build openssl-fips-provider "$native"
FAKE_MODE=unsafe-version assert_failure_without_artifact run_build openssl-fips-provider "$native"
FAKE_MODE=alter-recipe assert_failure_without_artifact run_build openssl-fips-provider "$native"
GIT_MASTER=1 git -C "$repository" update-index --no-assume-unchanged -- packages/openssl-fips-provider/melange.yaml
GIT_MASTER=1 git -C "$repository" checkout -q -- packages/openssl-fips-provider/melange.yaml
printf dirty >> "$repository/packages/openssl-fips-provider/melange.yaml"
assert_failure_without_artifact run_build openssl-fips-provider "$native"
GIT_MASTER=1 git -C "$repository" checkout -q -- packages/openssl-fips-provider/melange.yaml
FAKE_MODE=misleading assert_failure_without_artifact run_build openssl-fips-provider "$native"
FAKE_MODE=interrupt assert_failure_without_artifact run_build openssl-fips-provider "$native"
EXPECTED_STATUS=130 FAKE_MODE=interrupt-after-publish assert_failure_without_artifact run_build openssl-fips-provider "$native"
FAKE_MODE=advance-head assert_failure_without_artifact run_build openssl-fips-provider "$native"
rm -rf "$repository/artifact"
mkdir "$repository/artifact"
printf stale > "$repository/artifact/stale.apk"
if FAKE_MODE=break-git run_build openssl-fips-provider "$native"; then
  printf 'git inspection failure was accepted\n' >&2
  exit 1
fi
mv "$TMPDIR/git-hidden" "$repository/.git"
test ! -e "$repository/artifact"
test -z "$(find "$repository" -maxdepth 1 -name '.artifact.*' -print -quit)"
test -z "$(find "$TMPDIR" -mindepth 1 -print -quit)"
