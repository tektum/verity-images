#!/bin/bash
set -euo pipefail

source_key=${1:?usage: prepare-apk-signing-key.sh SOURCE_KEY PRIVATE_KEY PUBLIC_KEY}
private_key=${2:?usage: prepare-apk-signing-key.sh SOURCE_KEY PRIVATE_KEY PUBLIC_KEY}
public_key=${3:?usage: prepare-apk-signing-key.sh SOURCE_KEY PRIVATE_KEY PUBLIC_KEY}
derived_public="$private_key.pub.der"
expected_public="$private_key.expected.pub.der"

trap 'rm -f "$source_key" "$private_key" "$derived_public" "$expected_public"' EXIT HUP INT TERM
[[ "$(basename "$private_key")" == verity-apk-2026.rsa ]]

openssl rsa -in "$source_key" -check -noout
openssl rsa -traditional -in "$source_key" -out "$private_key"
openssl rsa -in "$private_key" -check -noout
openssl pkey -in "$private_key" -pubout -outform DER > "$derived_public"
openssl pkey -pubin -in "$public_key" -pubout -outform DER > "$expected_public"
cmp --silent "$derived_public" "$expected_public"
rm -f "$source_key" "$derived_public" "$expected_public"
trap - EXIT HUP INT TERM
