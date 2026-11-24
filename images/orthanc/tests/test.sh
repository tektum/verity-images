#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE [FLAVOR]}
flavor=${2:-plain}
here=$(cd "$(dirname "$0")" && pwd)
name=verity-orthanc-$$
volume=$name-db
work=$(mktemp -d)

cleanup() {
  docker rm -fv "$name" "$name-invalid" "$name-default" >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  docker logs "$name" 2>&1 | tail -n 40 >&2 || true
  exit 1
}

case $flavor in plain | '') ;; *) fail "unsupported flavor $flavor" ;; esac

# Expected versions come from the exact Wolfi pins, so a Renovate bump needs no test edit.
pin() {
  sed -n "s/^[[:space:]]*- $1=\([^=]*\)-r[0-9][0-9]*\$/\1/p" "$here/../apko.yaml"
}
orthanc_version=$(pin orthanc)
dicomweb_version=$(pin orthanc-dicomweb)
explorer2_version=$(pin orthanc-explorer2)
ohif_version=$(pin orthanc-ohif)
for version in "$orthanc_version" "$dicomweb_version" "$explorer2_version" "$ohif_version"; do
  [ -n "$version" ] || fail 'could not read a package pin from apko.yaml'
done

# OCI contract.
[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 ] || fail 'image user is not 65532'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/Orthanc"]' ] ||
  fail 'unexpected entrypoint'
[ "$(docker image inspect -f '{{json .Config.Cmd}}' "$image")" = '["/etc/orthanc/"]' ] ||
  fail 'unexpected command'
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = /var/lib/orthanc/db ] ||
  fail 'unexpected working directory'
[ "$(docker image inspect -f '{{json .Config.Volumes}}' "$image")" = '{"/var/lib/orthanc/db":{}}' ] ||
  fail 'unexpected volumes'
docker run --rm "$image" --version >"$work/version.log" 2>&1 || fail 'Orthanc --version failed'
grep -qx "/usr/bin/Orthanc $orthanc_version" "$work/version.log" ||
  { cat "$work/version.log" >&2; fail "Orthanc --version does not report $orthanc_version"; }

# A tiny Explicit VR Little Endian secondary capture instance (8x8, 8-bit MONOCHROME2).
study_uid=2.25.1129960113100183140071301
series_uid=2.25.1129960113100183140071302
sop_uid=2.25.1129960113100183140071303
patient_id=VERITY-ORTHANC-1
python3 - "$study_uid" "$series_uid" "$sop_uid" "$patient_id" >"$work/smoke.dcm" <<'EOF'
import struct
import sys

study, series, sop, patient = (value.encode() for value in sys.argv[1:5])


def element(group, number, vr, value):
    if len(value) % 2:
        value += b"\0" if vr in ("UI", "OB") else b" "
    head = struct.pack("<HH", group, number) + vr.encode()
    if vr == "OB":
        return head + b"\0\0" + struct.pack("<I", len(value)) + value
    return head + struct.pack("<H", len(value)) + value


def us(value):
    return struct.pack("<H", value)


sop_class = b"1.2.840.10008.5.1.4.1.1.7"
meta = (
    element(0x0002, 0x0001, "OB", b"\0\1")
    + element(0x0002, 0x0002, "UI", sop_class)
    + element(0x0002, 0x0003, "UI", sop)
    + element(0x0002, 0x0010, "UI", b"1.2.840.10008.1.2.1")
    + element(0x0002, 0x0012, "UI", b"2.25.1129960113100183140071300")
)
dataset = (
    element(0x0008, 0x0016, "UI", sop_class)
    + element(0x0008, 0x0018, "UI", sop)
    + element(0x0008, 0x0020, "DA", b"20261119")
    + element(0x0008, 0x0060, "CS", b"OT")
    + element(0x0010, 0x0010, "PN", b"VERITY^SMOKE")
    + element(0x0010, 0x0020, "LO", patient)
    + element(0x0020, 0x000D, "UI", study)
    + element(0x0020, 0x000E, "UI", series)
    + element(0x0020, 0x0013, "IS", b"1")
    + element(0x0028, 0x0002, "US", us(1))
    + element(0x0028, 0x0004, "CS", b"MONOCHROME2")
    + element(0x0028, 0x0010, "US", us(8))
    + element(0x0028, 0x0011, "US", us(8))
    + element(0x0028, 0x0100, "US", us(8))
    + element(0x0028, 0x0101, "US", us(8))
    + element(0x0028, 0x0102, "US", us(7))
    + element(0x0028, 0x0103, "US", us(0))
    + element(0x7FE0, 0x0010, "OB", bytes(range(0, 256, 4)))
)
group_length = element(0x0002, 0x0000, "UL", struct.pack("<I", len(meta)))
sys.stdout.buffer.write(b"\0" * 128 + b"DICM" + group_length + meta + dataset)
EOF
[ -s "$work/smoke.dcm" ] || fail 'could not generate the DICOM fixture'

# The configuration lives at the default path; the password is per run, never committed.
user=verity
password=$(od -An -N18 -tx1 /dev/urandom | tr -d ' \n')
cat >"$work/orthanc.json" <<EOF
{
  "Name": "verity-orthanc-smoke",
  "StorageDirectory": "/var/lib/orthanc/db",
  "IndexDirectory": "/var/lib/orthanc/db",
  "RemoteAccessAllowed": true,
  "AuthenticationEnabled": true,
  "RegisteredUsers": { "$user": "$password" },
  "Plugins": [
    "/usr/share/orthanc/plugins/libOrthancDicomWeb.so",
    "/usr/share/orthanc/plugins/libOrthancExplorer2.so",
    "/usr/share/orthanc/plugins/libOrthancOHIF.so"
  ],
  "DicomWeb": { "Enable": true, "Root": "/dicom-web/" },
  "OrthancExplorer2": { "Enable": true, "IsDefaultOrthancUI": false },
  "OHIF": { "DataSource": "dicom-web" }
}
EOF
printf '{ "Name": "broken", ' >"$work/invalid.json"
chmod 0644 "$work/orthanc.json" "$work/invalid.json" "$work/smoke.dcm"

# Negative: a malformed configuration stops Orthanc with a clear error.
if docker run --name "$name-invalid" -v "$work/invalid.json:/etc/orthanc/orthanc.json:ro" "$image" \
  >"$work/invalid.log" 2>&1; then
  fail 'malformed configuration unexpectedly started Orthanc'
fi
[ "$(docker inspect -f '{{.State.ExitCode}}' "$name-invalid")" != 0 ] || fail 'malformed configuration exited 0'
grep -q 'The configuration file does not follow the JSON syntax' "$work/invalid.log" ||
  { cat "$work/invalid.log" >&2; fail 'malformed configuration did not fail clearly'; }

http_code() {
  curl --silent --output /dev/null --write-out '%{http_code}' --connect-timeout 2 --max-time 10 "$@" || true
}

published_port() {
  docker port "$1" "$2/tcp" | awk -F: 'NR == 1 { print $NF }'
}

# Without a configuration file Orthanc keeps its built-in defaults: remote REST
# clients are refused and data goes to the volume through the
# /etc/orthanc/OrthancStorage link. No helper container is used, because a
# second platform of the same helper digest cannot be pulled on one daemon.
docker run -d --name "$name-default" --read-only --cap-drop ALL -p 127.0.0.1::8042 "$image" >/dev/null
default_port=$(published_port "$name-default" 8042)
[ -n "$default_port" ] || fail 'default container did not publish 8042'
i=0
until [ "$(http_code "http://127.0.0.1:$default_port/system")" = 401 ]; do
  i=$((i + 1))
  [ "$(docker inspect -f '{{.State.Running}}' "$name-default")" = true ] ||
    { docker logs "$name-default" >&2; fail 'default container exited during startup'; }
  [ "$i" -lt 180 ] || { docker logs "$name-default" >&2; fail 'default container did not reject a remote client'; }
  sleep 1
done
docker logs "$name-default" 2>&1 | grep -q 'remote access is not allowed' ||
  fail 'default configuration does not restrict the REST API to loopback clients'
docker logs "$name-default" 2>&1 | grep -q 'Storage directory: /etc/orthanc/OrthancStorage' ||
  fail 'default configuration did not use the OrthancStorage link'
docker rm -fv "$name-default" >/dev/null

start() {
  docker run -d --name "$name" --read-only --cap-drop ALL \
    -v "$volume:/var/lib/orthanc/db" -v "$work/orthanc.json:/etc/orthanc/orthanc.json:ro" \
    -p 127.0.0.1::8042 -p 127.0.0.1::4242 "$image" >/dev/null
  port=$(published_port "$name" 8042)
  [ -n "$port" ] || fail 'port 8042 is not published'
  dicom_port=$(published_port "$name" 4242)
  [ -n "$dicom_port" ] || fail 'port 4242 is not published'
  url=http://127.0.0.1:$port
  i=0
  until curl --fail --silent --connect-timeout 2 --max-time 10 -u "$user:$password" "$url/system" \
    >"$work/system.json"; do
    i=$((i + 1))
    [ "$(docker inspect -f '{{.State.Running}}' "$name")" = true ] || fail 'Orthanc exited during startup'
    [ "$i" -lt 180 ] || fail 'Orthanc did not become ready on /system'
    sleep 1
  done
}

api() {
  curl --fail --silent --show-error --max-time 60 -u "$user:$password" "$@"
}

docker volume create "$volume" >/dev/null
start

[ "$(jq -r .Version "$work/system.json")" = "$orthanc_version" ] ||
  fail "/system Version is not $orthanc_version"
[ "$(jq -r .Name "$work/system.json")" = verity-orthanc-smoke ] ||
  fail 'configuration at /etc/orthanc/orthanc.json was not loaded'
[ "$(jq -r '.HttpPort, .DicomPort' "$work/system.json" | tr '\n' ' ')" = '8042 4242 ' ] ||
  fail 'unexpected HTTP or DICOM port'
[ "$(jq -r .PluginsEnabled "$work/system.json")" = true ] || fail 'plugins are not enabled'

# Negative: authentication is enforced.
[ "$(http_code "$url/system")" = 401 ] || fail 'unauthenticated request was not rejected'
[ "$(http_code -u "$user:wrong-password" "$url/system")" = 401 ] || fail 'wrong password was not rejected'

# Every shipped plugin is loaded at its packaged version.
api "$url/plugins" >"$work/plugins.json" || fail '/plugins request failed'
for plugin in dicom-web orthanc-explorer-2 ohif; do
  jq -e --arg p "$plugin" 'index($p) != null' "$work/plugins.json" >/dev/null ||
    { cat "$work/plugins.json" >&2; fail "plugin $plugin is not loaded"; }
done
[ "$(api "$url/plugins/dicom-web" | jq -r .Version)" = "$dicomweb_version" ] ||
  fail "DICOMweb plugin is not $dicomweb_version"
[ "$(api "$url/plugins/ohif" | jq -r .Version)" = "$ohif_version" ] || fail "OHIF plugin is not $ohif_version"
# Wolfi builds Explorer 2 from the release tag without PLUGIN_VERSION, so it reports "mainline".
explorer2_reported=$(api "$url/plugins/orthanc-explorer-2" | jq -r .Version)
case $explorer2_reported in
  "$explorer2_version" | mainline) ;;
  *) fail "unexpected Orthanc Explorer 2 version: $explorer2_reported" ;;
esac
for page in /app/explorer.html /ui/app/ /ohif/ /dicom-web/app/client/index.html; do
  content_type=$(api --output /dev/null --write-out '%{content_type}' "$url$page") || fail "GET $page failed"
  case $content_type in text/html*) ;; *) fail "GET $page returned $content_type" ;; esac
done

# REST upload and byte-exact download.
api -X POST -H 'Content-Type: application/dicom' --data-binary "@$work/smoke.dcm" "$url/instances" \
  >"$work/upload.json" || fail 'DICOM upload failed'
[ "$(jq -r .Status "$work/upload.json")" = Success ] || { cat "$work/upload.json" >&2; fail 'upload not stored'; }
instance=$(jq -r .ID "$work/upload.json")
api "$url/instances/$instance/file" >"$work/download.dcm" || fail 'DICOM download failed'
cmp -s "$work/smoke.dcm" "$work/download.dcm" || fail 'downloaded instance differs from the upload'
[ "$(api "$url/instances/$instance/simplified-tags" | jq -r .PatientID)" = "$patient_id" ] ||
  fail 'stored instance has the wrong PatientID'

# DICOMweb QIDO-RS and WADO-RS.
api -H 'Accept: application/dicom+json' "$url/dicom-web/studies?PatientID=$patient_id" >"$work/qido.json" ||
  fail 'QIDO-RS query failed'
[ "$(jq -r '.[0]["0020000D"].Value[0]' "$work/qido.json")" = "$study_uid" ] ||
  { cat "$work/qido.json" >&2; fail 'QIDO-RS did not return the study'; }
api -H 'Accept: multipart/related; type="application/dicom"' \
  "$url/dicom-web/studies/$study_uid/series/$series_uid/instances/$sop_uid" >"$work/wado.bin" ||
  fail 'WADO-RS retrieve failed'
python3 - "$work/smoke.dcm" "$work/wado.bin" <<'EOF' || fail 'WADO-RS response does not contain the instance'
import sys

fixture, response = (open(path, "rb").read() for path in sys.argv[1:3])
sys.exit(0 if fixture in response else 1)
EOF

# DICOM listener: C-ECHO to the container address on 4242 succeeds, and an echo
# to a closed port fails, so the positive result is not vacuous.
address=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$name")
[ -n "$address" ] || fail 'container has no network address'
api -X PUT -d "{\"AET\":\"ORTHANC\",\"Host\":\"$address\",\"Port\":4242}" "$url/modalities/self" >/dev/null ||
  fail 'could not declare the self modality'
api -X POST -d '{"Timeout":30}' "$url/modalities/self/echo" >/dev/null || fail 'C-ECHO on 4242 failed'
api -X PUT -d "{\"AET\":\"ORTHANC\",\"Host\":\"$address\",\"Port\":4243}" "$url/modalities/closed" >/dev/null ||
  fail 'could not declare the closed modality'
[ "$(http_code -u "$user:$password" -X POST -d '{"Timeout":5}' "$url/modalities/closed/echo")" != 200 ] ||
  fail 'C-ECHO to a closed port unexpectedly succeeded'

# SIGTERM stops Orthanc cleanly.
docker stop -t 60 "$name" >/dev/null
[ "$(docker inspect -f '{{.State.ExitCode}}' "$name")" = 0 ] || fail 'Orthanc did not exit 0 on SIGTERM'
docker rm "$name" >/dev/null

# Persistence: a new container on the same volume serves the same instance.
start
api "$url/statistics" >"$work/statistics.json" || fail '/statistics request failed'
[ "$(jq -r .CountInstances "$work/statistics.json")" = 1 ] || fail 'instance count did not persist'
api "$url/instances/$instance/file" >"$work/persisted.dcm" || fail 'persisted instance is missing'
cmp -s "$work/smoke.dcm" "$work/persisted.dcm" || fail 'persisted instance differs from the upload'

printf 'orthanc %s smoke test passed\n' "$orthanc_version"
