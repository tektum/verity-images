#!/bin/bash
set -euo pipefail

root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
reserver="$root/.github/scripts/reserve-apk-release-identity.sh"
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM

make_package() {
  local path=$1 architecture=$2 name=$3 version=$4 epoch=$5 package_dir
  package_dir=$(mktemp -d "$work_dir/package.XXXXXX")
  printf 'pkgname = %s\npkgver = %s\n' "$name" "$version" > "$package_dir/.PKGINFO"
  printf 'package:\n  epoch: %s\n' "$epoch" > "$package_dir/.melange.yaml"
  tar -C "$package_dir" -cf "$path" .PKGINFO .melange.yaml
  rm -rf "$package_dir"
}

make_archive() {
  local tag=$1 version=$2 epoch=$3 package_dir
  for architecture in x86_64 aarch64; do
    package_dir="$work_dir/archive-$tag/apk/$architecture"
    mkdir -p "$package_dir"
    make_package "$package_dir/openssl-fips-provider-$version.apk" "$architecture" openssl-fips-provider "$version" "$epoch"
  done
  tar --zstd -C "$work_dir/archive-$tag" -cf "$work_dir/$tag.tar.zst" apk
}

identity() {
  jq -cn --arg name openssl-fips-provider --arg version 3.1.2-r3 --argjson epoch 3 \
    '{schemaVersion:1,packages:["aarch64","x86_64"] | map({architecture:.,name:$name,version:$version,epoch:$epoch})}'
}

write_gh() {
  cat > "$work_dir/bin/gh" <<'GH'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$GH_LOG"
case "$1" in
  api)
    cat "$GH_RELEASES"
    ;;
  release)
    case "$2" in
      download)
        cp "$GH_ARCHIVES/$3.tar.zst" "${@: -1}/verity-apk-repository.tar.zst"
        ;;
      create)
        tag=$3
        notes=${@: -1}
        reservation=$(printf '%s\n' "$notes" | sed -n 's/^<!-- apk-release-identity: \(.*\) -->$/\1/p')
        jq --arg tag "$tag" --arg body "$(printf '%s\n' "$notes")" \
          '. + [{tag_name:$tag,draft:true,body:$body,assets:[]}]' "$GH_RELEASES" > "$GH_RELEASES.next"
        mv "$GH_RELEASES.next" "$GH_RELEASES"
        ;;
      *) exit 64 ;;
    esac
    ;;
  *) exit 64 ;;
esac
GH
  chmod +x "$work_dir/bin/gh"
}

run() {
  local tag=$1
  GH_ARCHIVES="$work_dir" GH_LOG="$work_dir/log" GH_RELEASES="$work_dir/releases.json" \
    PATH="$work_dir/bin:$PATH" "$reserver" tektum/verity-images "$tag" 0123456789012345678901234567890123456789 \
    "$work_dir/x86_64.apk" "$work_dir/aarch64.apk"
}

expect_failure() {
  set +e
  run "$@"
  local status=$?
  set -e
  [[ $status -ne 0 ]]
}

mkdir "$work_dir/bin"
make_package "$work_dir/x86_64.apk" x86_64 openssl-fips-provider 3.1.2-r3 3
make_package "$work_dir/aarch64.apk" aarch64 openssl-fips-provider 3.1.2-r3 3
write_gh

make_archive apk-repo-v0001 3.1.2-r3 3
printf '[{"tag_name":"apk-repo-v0001","draft":false,"body":"legacy","assets":[{"name":"verity-apk-repository.tar.zst"}]}]\n' > "$work_dir/releases.json"
expect_failure apk-repo-v0003
grep -Fq 'release create' "$work_dir/log" && exit 1

make_package "$work_dir/x86_64.apk" x86_64 openssl-fips-provider 3.1.2-r2 2
make_package "$work_dir/aarch64.apk" aarch64 openssl-fips-provider 3.1.2-r2 2
make_archive apk-repo-v0002 3.1.2-r2 2
printf '[{"tag_name":"apk-repo-v0002","draft":false,"body":"legacy","assets":[{"name":"verity-apk-repository.tar.zst"}]}]\n' > "$work_dir/releases.json"
expect_failure apk-repo-v0003
make_package "$work_dir/x86_64.apk" x86_64 openssl-fips-provider 3.1.2-r3 3
make_package "$work_dir/aarch64.apk" aarch64 openssl-fips-provider 3.1.2-r3 3

jq -n --arg body "<!-- apk-release-identity: $(identity) -->" \
  '[{tag_name:"apk-repo-v0002",draft:true,body:$body,assets:[]}]' > "$work_dir/releases.json"
expect_failure apk-repo-v0003

printf '[{"tag_name":"apk-repo-v0002","draft":true,"body":"<!-- apk-release-identity: bad -->","assets":[]}]\n' > "$work_dir/releases.json"
expect_failure apk-repo-v0003
printf '[{"tag_name":"apk-repo-v0002","draft":true,"body":"missing","assets":[]}]\n' > "$work_dir/releases.json"
expect_failure apk-repo-v0003

printf '[]\n' > "$work_dir/releases.json"
run apk-repo-v0003
expect_failure apk-repo-v0004
make_package "$work_dir/x86_64.apk" x86_64 openssl-fips-provider 3.1.2-r4 4
make_package "$work_dir/aarch64.apk" aarch64 openssl-fips-provider 3.1.2-r4 4
run apk-repo-v0004
grep -Fq 'api --paginate --slurp repos/tektum/verity-images/releases?per_page=100' "$work_dir/log"
grep -Fq 'release create apk-repo-v0003' "$work_dir/log"
grep -Fq 'release create apk-repo-v0004' "$work_dir/log"
[[ $(grep -n -m1 -F 'api --paginate --slurp repos/tektum/verity-images/releases?per_page=100' "$work_dir/log" | cut -d: -f1) -lt \
  $(grep -n -m1 -F 'release create apk-repo-v0003' "$work_dir/log" | cut -d: -f1) ]]
