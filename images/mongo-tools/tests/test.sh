#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^    - mongo-tools=\([0-9][0-9.]*\)-r[0-9]*$/\1/p' \
  "$(dirname "$0")/../apko.yaml")
[ -n "$expected_version" ] || { printf '%s\n' 'mongo-tools package pin not found' >&2; exit 1; }
mongo_index='docker.io/library/mongo:8.0@sha256:d97fea17ccb8d004cd137be8dab54d70d0df11be69c9f422aefe4484c8414ab7'
backend="verity-mongo-tools-mongo-$$"
network="verity-mongo-tools-network-$$"
volume="verity-mongo-tools-dump-$$"

cleanup() {
  docker rm -f "$backend" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  docker volume rm "$volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# OCI contract.
user=$(docker image inspect -f '{{.Config.User}}' "$image")
[ "$user" = 65532 ] || fail "image user is $user, want 65532"
command=$(docker image inspect -f '{{json .Config.Entrypoint}} {{json .Config.Cmd}}' "$image")
[ "$command" = 'null ["/usr/bin/mongodump","--version"]' ] || fail "unexpected entrypoint/cmd: $command"
workdir=$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")
[ "$workdir" = /work ] || fail "unexpected working directory: $workdir"

# Default command and every shipped tool report the pinned version.
default_out=$(timeout 60 docker run --rm --network none "$image" 2>&1) ||
  fail "default command failed: $default_out"
case $default_out in
  "mongodump version: $expected_version"*) ;;
  *) fail "default command printed '$default_out', want mongodump version $expected_version" ;;
esac
for tool in bsondump mongodump mongoexport mongofiles mongoimport mongorestore mongostat mongotop; do
  out=$(timeout 60 docker run --rm --network none "$image" "$tool" --version 2>&1) ||
    fail "$tool --version failed: $out"
  case $out in
    *"$expected_version"*) ;;
    *) fail "$tool --version printed '$out', want $expected_version" ;;
  esac
done

# Unsupported flag is rejected.
if out=$(timeout 60 docker run --rm --network none "$image" mongodump --no-such-flag 2>&1); then
  fail 'mongodump accepted an unknown flag'
fi

# Pull the pinned MongoDB index by its per-platform child digest after verifying
# the index bytes against the pin.
image_arch=$(docker image inspect -f '{{.Architecture}}' "$image")
mongo_raw=$(docker buildx imagetools inspect --raw "$mongo_index") ||
  fail 'cannot inspect the MongoDB fixture index'
[ "sha256:$(printf '%s' "$mongo_raw" | sha256sum | cut -d' ' -f1)" = "${mongo_index#*@}" ] ||
  fail 'MongoDB fixture index digest mismatch'
mongo_digest=$(printf '%s' "$mongo_raw" |
  jq -r --arg arch "$image_arch" '
    [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
    | if length == 1 then .[0] else empty end') ||
  fail 'cannot resolve the MongoDB fixture digest'
case $mongo_digest in
  sha256:*) ;;
  *) fail "no unique linux/$image_arch MongoDB fixture in $mongo_index" ;;
esac
mongo=${mongo_index%%:*}@$mongo_digest
docker pull --quiet --platform "linux/$image_arch" "$mongo" >/dev/null || fail 'cannot pull the MongoDB fixture'

docker network create --internal "$network" >/dev/null
docker run --name "$backend" -d --network "$network" --network-alias mongo "$mongo" >/dev/null
mongosh() {
  docker exec "$backend" mongosh --quiet "mongodb://127.0.0.1:27017/smoke" --eval "$1"
}
attempts=0
until mongosh 'db.runCommand({ping: 1}).ok' 2>/dev/null | grep -qx 1; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 120 ] || { docker logs "$backend" >&2; fail 'MongoDB fixture did not become ready'; }
  sleep 1
done

mongosh '
  db.fruit.insertMany([
    {_id: 1, name: "apple", tags: ["red", "green"], price: NumberDecimal("1.25")},
    {_id: 2, name: "banana", nested: {origin: "EC", weight: 120}},
    {_id: 3, name: "cherry", when: ISODate("2026-01-02T03:04:05Z"), raw: BinData(0, "AAEC")}
  ]);
  db.fruit.createIndex({name: 1}, {unique: true, name: "name_unique"});
  db.veg.insertOne({_id: "kale", leafy: true});' >/dev/null ||
  fail 'cannot seed the MongoDB fixture'

snapshot='EJSON.stringify({
  fruit: db.fruit.find().sort({_id: 1}).toArray(),
  veg: db.veg.find().sort({_id: 1}).toArray(),
  indexes: db.fruit.getIndexes().map(i => i.name + ":" + EJSON.stringify(i.key) + ":" + !!i.unique).sort()
}, {relaxed: false})'
before=$(mongosh "$snapshot") || fail 'cannot snapshot seeded data'
case $before in
  *apple*banana*cherry*kale*name_unique*) ;;
  *) fail "seed snapshot is incomplete: $before" ;;
esac

# Dump as the image user into a volume mounted on the working directory.
# Docker seeds the empty volume with the image's /work ownership (65532).
docker volume create "$volume" >/dev/null
dump_log=$(timeout 120 docker run --rm --network "$network" -v "$volume:/work" "$image" \
  mongodump --uri mongodb://mongo:27017 --db smoke --out /work/dump 2>&1) ||
  fail "mongodump failed: $dump_log"
listing=$(docker run --rm --network none -v "$volume:/d:ro" --entrypoint /bin/sh "$mongo" -c \
  'cd /d/dump/smoke && for f in fruit.bson fruit.metadata.json veg.bson veg.metadata.json; do [ -s "$f" ] && echo "$f"; done; grep -c name_unique fruit.metadata.json') ||
  fail "cannot inspect the dump volume: $listing"
[ "$listing" = "fruit.bson
fruit.metadata.json
veg.bson
veg.metadata.json
1" ] || fail "unexpected dump contents: $listing (log: $dump_log)"

# bsondump decodes the dump offline.
bson=$(timeout 60 docker run --rm --network none -v "$volume:/work:ro" "$image" \
  bsondump --quiet /work/dump/smoke/fruit.bson 2>&1) || fail "bsondump failed: $bson"
case $bson in
  *'"name":"banana"'*) ;;
  *) fail "bsondump output lacks banana: $bson" ;;
esac

mongosh 'db.dropDatabase().ok' | grep -qx 1 || fail 'cannot drop the smoke database'
gone=$(mongosh 'db.fruit.countDocuments() + db.veg.countDocuments()')
[ "$gone" = 0 ] || fail "database still has $gone documents after drop"

restore_log=$(timeout 120 docker run --rm --network "$network" -v "$volume:/work:ro" "$image" \
  mongorestore --uri mongodb://mongo:27017 /work/dump 2>&1) ||
  fail "mongorestore failed: $restore_log"
case $restore_log in
  *'4 document(s) restored successfully. 0 document(s) failed to restore.'*) ;;
  *) fail "unexpected mongorestore summary: $restore_log" ;;
esac

after=$(mongosh "$snapshot") || fail 'cannot snapshot restored data'
[ "$after" = "$before" ] || fail "restored data differs:
before: $before
after:  $after"

# The restored unique index is enforced.
if mongosh 'db.fruit.insertOne({_id: 9, name: "apple"})' >/dev/null 2>&1; then
  fail 'restored unique index was not enforced'
fi

# Negative: an unreachable host fails with a connection error.
if out=$(timeout 120 docker run --rm --network "$network" -v "$volume:/work" "$image" \
  mongodump --uri 'mongodb://no-such-mongo:27017/?serverSelectionTimeoutMS=3000' --out /work/dump/x 2>&1); then
  fail "mongodump succeeded against an unreachable host: $out"
fi
case $out in
  *'Failed: can'\''t create session: '*|*'server selection'*) ;;
  *) fail "unexpected unreachable-host error: $out" ;;
esac
if out=$(timeout 120 docker run --rm --network "$network" -v "$volume:/work:ro" "$image" \
  mongorestore --uri 'mongodb://no-such-mongo:27017/?serverSelectionTimeoutMS=3000' /work/dump 2>&1); then
  fail "mongorestore succeeded against an unreachable host: $out"
fi
case $out in
  *'server selection'*|*'connect'*) ;;
  *) fail "unexpected unreachable-host restore error: $out" ;;
esac

# Negative: restoring a missing path fails.
if out=$(timeout 60 docker run --rm --network "$network" "$image" \
  mongorestore --uri mongodb://mongo:27017 /work/missing 2>&1); then
  fail "mongorestore accepted a missing dump path: $out"
fi

printf '%s\n' "mongo-tools $expected_version smoke test passed"
