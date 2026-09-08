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
jq -e '
  [.images[] | select((.scan.all // .scan.final) == null)] as $missing |
  if ($missing | length) == 0 then true
  else $missing[0] as $image |
    error("catalog image \($image.name) \($image.version) has no publication scan counts")
  end
' "$catalog" >/dev/null

mkdir -p "$output"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# One database for the whole shard. Each scan document records the descriptor
# that produced it and the SARIF build rejects a shard scanned with two.
grype db update

subjects=$work/subjects.json
: >"$subjects"
selected=0

while IFS=$'\t' read -r name version track reference digest context published; do
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
    --arg reference "$reference" --arg digest "$digest" --arg context "$context" \
    --argjson published "$published" \
    --argjson platforms "[$(
      IFS=,
      printf '%s' "${platforms[*]}"
    )]" '
    {name: $name, version: $version, track: $track, reference: $reference,
     digest: $digest, context: $context, published: $published,
     platforms: $platforms}
  ' >>"$subjects"
  selected=$((selected + 1))
done < <(jq -r --slurpfile images "$images" '
  ($images[0].include |
    map({key: (.name + " " + .tag_version), value: .context}) |
    from_entries) as $context |
  .images[] |
  [.name, .version, .track, .reference, .digest,
   ($context[.name + " " + .version] // ""),
   ((.scan.all // .scan.final) | tojson)] | @tsv
' "$catalog")

if ((selected == 0)); then
  printf '::error title=Empty monitor shard::Shard %s of %s selected no image.\n' \
    "$shard" "$shards" >&2
  exit 1
fi

jq --slurp --argjson shard "$shard" --argjson shards "$shards" \
  --slurpfile catalog "$catalog" '
  {shard: $shard,
   shards: $shards,
   catalog: {schemaVersion: $catalog[0].schemaVersion,
             publishedAt: $catalog[0].publishedAt,
             source: $catalog[0].source,
             images: ($catalog[0].images | length)},
   subjects: .}
' "$subjects" >"$output/manifest.json"
