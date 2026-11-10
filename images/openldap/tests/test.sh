#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-openldap-test-$$"
confvol="verity-openldap-conf-$$"
datavol="verity-openldap-data-$$"
fixture=$(mktemp -d)
chmod 755 "$fixture"
uri=ldap://127.0.0.1:1389
suffix='dc=verity,dc=test'
rootdn="cn=admin,$suffix"
rootpw=smoke-secret
confdn='cn=admin,cn=config'

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  docker logs "$container" >&2 2>&1 || true
  exit 1
}

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm "$confvol" "$datavol" >/dev/null 2>&1 || true
  rm -rf "$fixture"
}
trap cleanup EXIT INT TERM

# Run one OpenLDAP client or admin tool from the image next to the server.
tool() {
  name=$1
  shift
  docker run --rm --cpus 4 --cap-drop=ALL --read-only --network "container:$container" \
    --entrypoint "/usr/bin/$name" "$image" "$@"
}

# Run one tool with a fixture directory mounted read-only at /fixture.
tool_with_fixture() {
  name=$1
  shift
  docker run --rm --cpus 4 --cap-drop=ALL --read-only --network "container:$container" \
    -v "$fixture:/fixture:ro" --entrypoint "/usr/bin/$name" "$image" "$@"
}

wait_ready() {
  i=0
  until tool ldapsearch -x -H "$uri" -b '' -s base namingContexts >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -lt 30 ] || fail 'slapd did not become ready'
    [ "$(docker inspect --format '{{.State.Running}}' "$container")" = true ] || fail 'slapd exited during startup'
    sleep 1
  done
}

start_server() {
  docker run --name "$container" --cpus 4 --cap-drop=ALL --read-only -d \
    --label verity-test=openldap \
    -v "$confvol:/etc/openldap/slapd.d" -v "$datavol:/var/lib/openldap/openldap-data" \
    "$image" >/dev/null
  wait_ready
}

# Image contract.
[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 389 ] || fail 'image user is not 389'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/slapd"]' ] || fail 'unexpected image entrypoint'
[ "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = '["-d","stats","-h","ldap://0.0.0.0:1389/","-F","/etc/openldap/slapd.d"]' ] || fail 'unexpected image command'
docker image inspect --format '{{json .Config.Volumes}}' "$image" | grep -F '"/var/lib/openldap/openldap-data"' >/dev/null || fail 'missing data volume'
docker image inspect --format '{{json .Config.Volumes}}' "$image" | grep -F '"/etc/openldap/slapd.d"' >/dev/null || fail 'missing config volume'

# Version and backend identity: slapd 2.7.x, with the mdb backend module shipped.
docker run --rm --cpus 4 "$image" -VV 2>&1 | grep -F 'OpenLDAP: slapd 2.7.2 ' >/dev/null || fail 'slapd version check failed'
docker run --rm --cpus 4 --entrypoint /usr/bin/ldapsearch "$image" -VV 2>&1 | grep -F 'OpenLDAP: ldapsearch 2.7.2 ' >/dev/null || fail 'ldapsearch version check failed'

# Negative: a missing configuration directory is a readable error, not a running server.
if docker run --rm --cpus 4 "$image" -d stats -F /etc/openldap/missing.d > "$fixture/missing.log" 2>&1; then
  fail 'missing configuration unexpectedly succeeded'
fi
grep -Ei 'config|slapd.d|missing' "$fixture/missing.log" >/dev/null || fail 'missing configuration diagnostic not found'

# cn=config with the mdb backend, generated for this test.
cat > "$fixture/config.ldif" <<EOF
dn: cn=config
objectClass: olcGlobal
cn: config
olcPidFile: /var/lib/openldap/openldap-data/slapd.pid

dn: cn=module{0},cn=config
objectClass: olcModuleList
cn: module{0}
olcModulePath: /usr/lib/openldap
olcModuleLoad: back_mdb.so

dn: cn=schema,cn=config
objectClass: olcSchemaConfig
cn: schema

include: file:///etc/openldap/schema/core.ldif
include: file:///etc/openldap/schema/cosine.ldif
include: file:///etc/openldap/schema/inetorgperson.ldif

dn: olcDatabase={0}config,cn=config
objectClass: olcDatabaseConfig
olcDatabase: {0}config
olcRootDN: $confdn
olcRootPW: $rootpw

dn: olcDatabase={1}mdb,cn=config
objectClass: olcDatabaseConfig
objectClass: olcMdbConfig
olcDatabase: {1}mdb
olcDbDirectory: /var/lib/openldap/openldap-data
olcSuffix: $suffix
olcRootDN: $rootdn
olcRootPW: $rootpw
olcDbMaxSize: 67108864
olcDbIndex: objectClass eq
olcAccess: {0}to * by dn.exact="$rootdn" manage by * read
EOF
chmod 644 "$fixture/config.ldif"

docker volume create "$confvol" >/dev/null
docker volume create "$datavol" >/dev/null
docker run --rm --cpus 4 --cap-drop=ALL --read-only \
  -v "$confvol:/etc/openldap/slapd.d" -v "$datavol:/var/lib/openldap/openldap-data" \
  -v "$fixture:/fixture:ro" --entrypoint /usr/bin/slapadd "$image" \
  -n 0 -F /etc/openldap/slapd.d -l /fixture/config.ldif >/dev/null 2>"$fixture/slapadd.log" \
  || { cat "$fixture/slapadd.log" >&2; fail 'slapadd could not load the cn=config fixture (mdb backend missing?)'; }

start_server

# The default command serves the configuration as uid 389 over ldap on 1389.
[ "$(docker inspect --format '{{.Config.User}}' "$container")" = 389 ] || fail 'container is not running as 389'

# Anonymous root DSE shows the configured naming context.
tool ldapsearch -x -H "$uri" -b '' -s base namingContexts | grep -F "namingContexts: $suffix" >/dev/null || fail 'naming context not published'

# Bind: the right password succeeds and reports the DN, a wrong one is rejected.
tool ldapwhoami -x -H "$uri" -D "$rootdn" -w "$rootpw" | grep -Fx "dn:$rootdn" >/dev/null || fail 'authenticated bind did not report the root DN'
if tool ldapwhoami -x -H "$uri" -D "$rootdn" -w wrong-password > "$fixture/badbind.log" 2>&1; then
  fail 'bind with a wrong password unexpectedly succeeded'
fi
grep -F 'Invalid credentials (49)' "$fixture/badbind.log" >/dev/null || fail 'invalid credentials diagnostic not found'

# The mdb backend is the live database behind the suffix.
tool ldapsearch -x -H "$uri" -D "$confdn" -w "$rootpw" -b cn=config -LLL "(olcSuffix=$suffix)" dn \
  | grep -F 'dn: olcDatabase={1}mdb,cn=config' >/dev/null || fail 'suffix is not served by the mdb backend'

# Write: anonymous writes are refused, the authenticated add works.
cat > "$fixture/entries.ldif" <<EOF
dn: $suffix
objectClass: top
objectClass: dcObject
objectClass: organization
dc: verity
o: Verity Test

dn: ou=people,$suffix
objectClass: organizationalUnit
ou: people

dn: uid=smoke,ou=people,$suffix
objectClass: inetOrgPerson
uid: smoke
cn: Smoke User
sn: User
mail: smoke@verity.test
EOF
chmod 644 "$fixture/entries.ldif"
if tool_with_fixture ldapadd -x -H "$uri" -f /fixture/entries.ldif > "$fixture/anon.log" 2>&1; then
  fail 'anonymous ldapadd unexpectedly succeeded'
fi
grep -E 'Insufficient access|Strong.*required|\(50\)|\(8\)' "$fixture/anon.log" >/dev/null || fail 'anonymous write refusal diagnostic not found'
tool_with_fixture ldapadd -x -H "$uri" -D "$rootdn" -w "$rootpw" -f /fixture/entries.ldif >/dev/null || fail 'authenticated ldapadd failed'

# Read back: base entry and the added person.
tool ldapsearch -x -H "$uri" -b "$suffix" -s base -LLL dn o | grep -F 'o: Verity Test' >/dev/null || fail 'base DN entry not found'
tool ldapsearch -x -H "$uri" -b "$suffix" -LLL '(uid=smoke)' mail cn > "$fixture/readback.txt" || fail 'readback search failed'
grep -Fx "dn: uid=smoke,ou=people,$suffix" "$fixture/readback.txt" >/dev/null || fail 'added entry DN not found'
grep -Fx 'mail: smoke@verity.test' "$fixture/readback.txt" >/dev/null || fail 'added entry attribute not found'

# SIGTERM stops slapd cleanly.
docker stop -t 30 "$container" >/dev/null
[ "$(docker inspect --format '{{.State.ExitCode}}' "$container")" = 0 ] || fail 'slapd did not exit cleanly on SIGTERM'
docker rm "$container" >/dev/null

# Restart persistence: the same volumes bring the same data back.
start_server
tool ldapsearch -x -H "$uri" -b "$suffix" -LLL '(uid=smoke)' mail | grep -Fx 'mail: smoke@verity.test' >/dev/null || fail 'entry did not survive restart'
tool ldapwhoami -x -H "$uri" -D "$rootdn" -w "$rootpw" | grep -Fx "dn:$rootdn" >/dev/null || fail 'bind failed after restart'

# Modify and delete round trip with the bundled clients.
cat > "$fixture/modify.ldif" <<EOF
dn: uid=smoke,ou=people,$suffix
changetype: modify
replace: mail
mail: changed@verity.test
EOF
chmod 644 "$fixture/modify.ldif"
tool_with_fixture ldapmodify -x -H "$uri" -D "$rootdn" -w "$rootpw" -f /fixture/modify.ldif >/dev/null || fail 'ldapmodify failed'
tool ldapsearch -x -H "$uri" -b "$suffix" -LLL '(uid=smoke)' mail | grep -Fx 'mail: changed@verity.test' >/dev/null || fail 'modified attribute not found'
tool ldapdelete -x -H "$uri" -D "$rootdn" -w "$rootpw" "uid=smoke,ou=people,$suffix" >/dev/null || fail 'ldapdelete failed'
tool ldapsearch -x -H "$uri" -b "$suffix" -LLL '(uid=smoke)' dn > "$fixture/deleted.txt" || fail 'search after ldapdelete failed'
if grep -F 'dn:' "$fixture/deleted.txt" >/dev/null; then
  fail 'deleted entry is still present'
fi

printf 'SMOKE PASS image=%s\n' "$image"
