#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
helper="$root/.github/scripts/prepare-apk-signing-key.sh"
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM

key="$work_dir/key.pem"
public_key="$work_dir/key.pub.pem"
openssl genrsa -traditional -out "$key" 2048
openssl pkey -in "$key" -pubout -out "$public_key"

run_success() {
  local source_key=$1
  local private_key="$work_dir/verity-apk-2026.rsa"
  "$helper" "$source_key" "$private_key" "$public_key"
  [[ ! -e "$source_key" ]]
  [[ ! -e "$private_key.pub.der" ]]
  [[ ! -e "$private_key.expected.pub.der" ]]
  [[ "$(basename "$private_key")" == verity-apk-2026.rsa ]]
  grep -q -- 'BEGIN RSA PRIVATE KEY' "$private_key"
  cmp <(openssl pkey -in "$private_key" -pubout -outform DER) \
    <(openssl pkey -pubin -in "$public_key" -pubout -outform DER)
  rm -f "$private_key"
}

pkcs8="$work_dir/pkcs8.pem"
openssl pkcs8 -topk8 -nocrypt -in "$key" -out "$pkcs8"
run_success "$pkcs8"

pkcs1="$work_dir/pkcs1.pem"
cp "$key" "$pkcs1"
run_success "$pkcs1"

run_failure() {
  local source_key=$1
  local private_key=$2
  if "$helper" "$source_key" "$private_key" "$public_key"; then
    exit 1
  fi
  [[ ! -e "$source_key" ]]
  [[ ! -e "$private_key" ]]
  [[ ! -e "$private_key.pub.der" ]]
  [[ ! -e "$private_key.expected.pub.der" ]]
}

malformed="$work_dir/malformed.pem"
printf 'not a key\n' > "$malformed"
run_failure "$malformed" "$work_dir/verity-apk-2026.rsa"

ec_key="$work_dir/ec.pem"
openssl ecparam -name prime256v1 -genkey -noout -out "$ec_key"
run_failure "$ec_key" "$work_dir/verity-apk-2026.rsa"

other_key="$work_dir/other.pem"
other_public="$work_dir/other.pub.pem"
openssl genrsa -traditional -out "$other_key" 2048
openssl pkey -in "$other_key" -pubout -out "$other_public"
mismatch="$work_dir/mismatch.pem"
cp "$key" "$mismatch"
if "$helper" "$mismatch" "$work_dir/verity-apk-2026.rsa" "$other_public"; then
  exit 1
fi
[[ ! -e "$mismatch" ]]
[[ ! -e "$work_dir/verity-apk-2026.rsa" ]]
[[ ! -e "$work_dir/verity-apk-2026.rsa.pub.der" ]]
[[ ! -e "$work_dir/verity-apk-2026.rsa.expected.pub.der" ]]

wrong_name="$work_dir/wrong-name.pem"
cp "$key" "$wrong_name"
run_failure "$wrong_name" "$work_dir/wrong-name.rsa"
