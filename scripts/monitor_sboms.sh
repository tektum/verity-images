#!/bin/bash
set -euo pipefail

# Scans one shard of the published catalog. Every subject is resolved from its
# immutable reference, its attested per-platform SPDX SBOM is verified against
# the publishing identity, and Grype evaluates that SBOM against one
# vulnerability database. No image layer is pulled and no image is rebuilt.

catalog=${1:?usage: monitor_sboms.sh CATALOG IMAGES SHARD SHARDS OUTPUT}
images=${2:?usage: monitor_sboms.sh CATALOG IMAGES SHARD SHARDS OUTPUT}
shard=${3:?usage: monitor_sboms.sh CATALOG IMAGES SHARD SHARDS OUTPUT}
shards=${4:?usage: monitor_sboms.sh CATALOG IMAGES SHARD SHARDS OUTPUT}
output=${5:?usage: monitor_sboms.sh CATALOG IMAGES SHARD SHARDS OUTPUT}

identity='https://github.com/tektum/verity-images/.github/workflows/build.yaml@refs/heads/main'
issuer='https://token.actions.githubusercontent.com'

if ! [[ "$shards" =~ ^[1-9][0-9]*$ ]]; then
  printf 'invalid shard count: %s\n' "$shards" >&2
  exit 2
fi
if ! [[ "$shard" =~ ^(0|[1-9][0-9]*)$ ]] || ((shard >= shards)); then
  printf 'invalid shard index: %s\n' "$shard" >&2
  exit 2
fi

# A truncated inventory would silently retire code scanning alerts, so both
# inputs are validated before the first subject is selected.
jq -e '.schemaVersion == 2 and (.images | length > 0)' "$catalog" >/dev/null
jq -e '(.include | length) > 0' "$images" >/dev/null
jq -e --slurp '
  ([.[0].images[] | [.name, .version]] | sort) ==
  ([.[1].include[] | [.name, .tag_version]] | sort)
' "$catalog" "$images" >/dev/null

jq -e '
  [.images[] | select((.scan.all // .scan.final) == null)] as $missing |
  if ($missing | length) == 0 then true
  else $missing[0] as $image |
    error("catalog image \($image.name) \($image.version) has no publication scan counts")
  end
' "$catalog" >/dev/null

catalog_sha256="sha256:$(sha256sum "$catalog" | cut -d' ' -f1)"
inventory_sha256="sha256:$(sha256sum "$images" | cut -d' ' -f1)"

mkdir -p "$output"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Grype hydrates one signed database archive into SQLite. The hydrated file is
# not byte-deterministic across runners, so cross-shard identity uses the
# archive checksum from status while a local before/after hash detects mutation.
grype db update
grype db status --output json >"$work/db-status.json"
db_path=$(jq -er 'select(.valid == true) | .path' "$work/db-status.json")
[[ -f "$db_path" ]] || {
  printf 'Grype database path is not a file: %s\n' "$db_path" >&2
  exit 1
}
local_db_checksum="sha256:$(sha256sum "$db_path" | cut -d' ' -f1)"
archive_checksum=$(jq -er '
  .from |
  capture("[?&]checksum=sha256%3A(?<digest>[0-9a-f]{64})(?:&|$)"; "i") |
  "sha256:" + .digest
' "$work/db-status.json")
jq --arg checksum "$archive_checksum" '
  {schemaVersion, built, from, checksum: $checksum} |
  select((.schemaVersion | length) > 0 and (.built | length) > 0)
' "$work/db-status.json" >"$work/database.json"
# Every later Grype process opens this exact file. Disable its normal automatic
# update path and verify the file again before emitting any report.
export GRYPE_DB_AUTO_UPDATE=false



subjects=$work/subjects.json
: >"$subjects"
selected=0

while IFS=$'\t' read -r name version track reference digest input_digest context published; do

  # Shard membership is a stable function of the logical image stream, so an
  # image keeps one code scanning category across runs and rebuilds.
  stream=$(printf '%s@%s' "$name" "$version" | sha256sum | cut -c1-8)
  if ((16#$stream % shards != shard)); then
    continue
  fi
  if [[ -z "$context" ]]; then
    printf '::error title=Unknown published image::%s %s has no image definition.\n' \
      "$name" "$version" >&2
    exit 1
  fi
  cosign verify-attestation --type spdxjson --certificate-identity "$identity" \
    --certificate-oidc-issuer "$issuer" "$reference" >"$work/attestation.json"
  platforms=()
  for arch in amd64 arm64; do
    selection=$work/selection-$arch.json
    predicate=$work/sbom-$arch.spdx.json
    scan=scan-$name-$version-$arch.json
    # A published image without an attested SBOM for both platforms is a
    # coverage failure: the shard fails and its alerts stay untouched.
    # Republishing a reproducible digest appends another verified attestation,
    # so the newest SBOM is the one that describes the current build.
    jq --slurp --exit-status --arg suffix "-verity-platform-$arch" '
      map(.payload | @base64d | fromjson |
          select(.predicateType == "https://spdx.dev/Document") |
          select(.predicate.name | endswith($suffix)) |
          .predicate) |
      if length == 0 then error("no \($suffix) SPDX predicate") else . end |
      {attestations: length,
       sbom: (sort_by(.creationInfo.created // "") | last)}
    ' "$work/attestation.json" >"$selection"
    jq '.sbom' "$selection" >"$predicate"
    grype "sbom:$predicate" --output json --file "$output/$scan"
    platforms+=("$(jq -c --arg platform "linux/$arch" --arg scan "$scan" \
      '{platform: $platform, scan: $scan, attestations: .attestations,
        created: (.sbom.creationInfo.created // null)}' "$selection")")
  done
  jq -cn --arg name "$name" --arg version "$version" --arg track "$track" \
    --arg reference "$reference" --arg digest "$digest" --arg inputDigest "$input_digest" \
    --arg context "$context" --argjson published "$published" \
    --argjson platforms "[$(
      IFS=,
      printf '%s' "${platforms[*]}"
    )]" '
    {name: $name, version: $version, track: $track, reference: $reference,
     digest: $digest, inputDigest: $inputDigest, context: $context,
     published: $published, platforms: $platforms}
  ' >>"$subjects"
  selected=$((selected + 1))
done < <(jq -r --slurpfile images "$images" '
  ($images[0].include |
    map({key: (.name + " " + .tag_version), value: .context}) |
    from_entries) as $context |
  .images[] |
  [.name, .version, .track, .reference, .digest, .inputDigest,
   ($context[.name + " " + .version] // ""),
   ((.scan.all // .scan.final) | tojson)] | @tsv
' "$catalog")


final_db_checksum="sha256:$(sha256sum "$db_path" | cut -d' ' -f1)"
if [[ "$final_db_checksum" != "$local_db_checksum" ]]; then
  printf 'Grype database changed during shard scan: %s -> %s\n' \
    "$local_db_checksum" "$final_db_checksum" >&2
  exit 1
fi

if ((selected == 0)); then
  printf '::error title=Empty monitor shard::Shard %s of %s selected no image.\n' \
    "$shard" "$shards" >&2
  exit 1
fi

jq --slurp --argjson shard "$shard" --argjson shards "$shards" \
  --arg catalogSha256 "$catalog_sha256" --arg inventorySha256 "$inventory_sha256" \
  --slurpfile catalog "$catalog" --slurpfile database "$work/database.json" '
  {shard: $shard,
   shards: $shards,
   catalog: {schemaVersion: $catalog[0].schemaVersion,
             publishedAt: $catalog[0].publishedAt,
             source: $catalog[0].source,
             images: ($catalog[0].images | length),
             sha256: $catalogSha256,
             inventorySha256: $inventorySha256},
   database: $database[0],
   subjects: .}
' "$subjects" >"$output/manifest.json"
