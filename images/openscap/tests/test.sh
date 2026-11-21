#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
config="$here/../apko.yaml"
version=$(sed -n 's/^    - openscap=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
work=$(mktemp -d)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

[ -n "$version" ] || fail 'could not read the pinned openscap version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/oscap"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ||
  fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

docker run --rm --network none "$image" --version >"$work/version" 2>&1 ||
  fail "--version failed: $(cat "$work/version")"
grep -Fx "OpenSCAP command line tool (oscap) $version" "$work/version" >/dev/null ||
  fail "--version does not report oscap $version: $(head -n 1 "$work/version")"
for spec in 'XCCDF Version: 1.2' 'OVAL Version: 5.11' 'SCE Version: 1.0' \
  'Schema files: /usr/share/openscap/schemas'; do
  grep -F "$spec" "$work/version" >/dev/null ||
    fail "--version is missing '$spec'"
done
grep -E '^independent +textfilecontent54 +probe_textfilecontent54' "$work/version" >/dev/null ||
  fail '--version does not list the textfilecontent54 probe'

# Inline content: an OVAL file with two textfilecontent54 checks against a
# mounted sshd_config, and an XCCDF 1.2 benchmark with one rule per check.
mkdir -p "$work/content" "$work/target" "$work/out"
chmod 0777 "$work/out"
cat >"$work/content/oval.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<oval_definitions xmlns="http://oval.mitre.org/XMLSchema/oval-definitions-5"
  xmlns:oval="http://oval.mitre.org/XMLSchema/oval-common-5"
  xmlns:ind="http://oval.mitre.org/XMLSchema/oval-definitions-5#independent">
  <generator>
    <oval:schema_version>5.11.2</oval:schema_version>
    <oval:timestamp>2026-01-01T00:00:00</oval:timestamp>
  </generator>
  <definitions>
    <definition class="compliance" id="oval:org.example:def:1" version="1">
      <metadata><title>root login disabled</title><description>PermitRootLogin is no.</description></metadata>
      <criteria><criterion test_ref="oval:org.example:tst:1"/></criteria>
    </definition>
    <definition class="compliance" id="oval:org.example:def:2" version="1">
      <metadata><title>banner enabled</title><description>Banner is set.</description></metadata>
      <criteria><criterion test_ref="oval:org.example:tst:2"/></criteria>
    </definition>
  </definitions>
  <tests>
    <ind:textfilecontent54_test id="oval:org.example:tst:1" version="1" check="all" check_existence="at_least_one_exists" comment="PermitRootLogin no">
      <ind:object object_ref="oval:org.example:obj:1"/>
    </ind:textfilecontent54_test>
    <ind:textfilecontent54_test id="oval:org.example:tst:2" version="1" check="all" check_existence="at_least_one_exists" comment="Banner set">
      <ind:object object_ref="oval:org.example:obj:2"/>
    </ind:textfilecontent54_test>
  </tests>
  <objects>
    <ind:textfilecontent54_object id="oval:org.example:obj:1" version="1">
      <ind:filepath>/target/sshd_config</ind:filepath>
      <ind:pattern operation="pattern match">^PermitRootLogin no$</ind:pattern>
      <ind:instance datatype="int" operation="greater than or equal">1</ind:instance>
    </ind:textfilecontent54_object>
    <ind:textfilecontent54_object id="oval:org.example:obj:2" version="1">
      <ind:filepath>/target/sshd_config</ind:filepath>
      <ind:pattern operation="pattern match">^Banner /etc/issue$</ind:pattern>
      <ind:instance datatype="int" operation="greater than or equal">1</ind:instance>
    </ind:textfilecontent54_object>
  </objects>
</oval_definitions>
XML
cat >"$work/content/xccdf.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<Benchmark xmlns="http://checklists.nist.gov/xccdf/1.2" id="xccdf_org.example_benchmark_smoke" resolved="1" xml:lang="en">
  <status>accepted</status>
  <title>Smoke benchmark</title>
  <description>Two rules against a mounted sshd_config.</description>
  <version>1.0</version>
  <Profile id="xccdf_org.example_profile_smoke">
    <title>Smoke profile</title>
    <select idref="xccdf_org.example_rule_root_login" selected="true"/>
    <select idref="xccdf_org.example_rule_banner" selected="true"/>
  </Profile>
  <Rule id="xccdf_org.example_rule_root_login" selected="false" severity="high">
    <title>Disable root login</title>
    <check system="http://oval.mitre.org/XMLSchema/oval-definitions-5">
      <check-content-ref href="oval.xml" name="oval:org.example:def:1"/>
    </check>
  </Rule>
  <Rule id="xccdf_org.example_rule_banner" selected="false" severity="low">
    <title>Set a login banner</title>
    <check system="http://oval.mitre.org/XMLSchema/oval-definitions-5">
      <check-content-ref href="oval.xml" name="oval:org.example:def:2"/>
    </check>
  </Rule>
</Benchmark>
XML
printf 'Port 22\nPermitRootLogin no\n' >"$work/target/sshd_config"

# The image runs as its own UID on a read-only root; oscap needs a writable
# /tmp for OVAL evaluation and writes results to a world-writable bind mount.
scan() {
  docker run --rm --network none --read-only --cap-drop=ALL \
    --tmpfs /tmp:rw,mode=1777 -v "$work/content:/work:ro" \
    -v "$work/target:/target:ro" -v "$work/out:/out" "$image" "$@"
}

scan info xccdf.xml >"$work/info" 2>&1 || fail "info failed: $(cat "$work/info")"
grep -F 'Id: xccdf_org.example_profile_smoke' "$work/info" >/dev/null ||
  fail "info does not list the smoke profile: $(cat "$work/info")"
scan xccdf validate xccdf.xml >"$work/xvalid" 2>&1 ||
  fail "valid XCCDF rejected: $(cat "$work/xvalid")"
scan oval validate oval.xml >"$work/ovalid" 2>&1 ||
  fail "valid OVAL rejected: $(cat "$work/ovalid")"

# OVAL: definition 1 matches the file, definition 2 does not.
scan oval eval --results /out/oval-results.xml oval.xml >"$work/oval" 2>&1 ||
  fail "oval eval failed: $(cat "$work/oval")"
grep -Fx 'Definition oval:org.example:def:1: true' "$work/oval" >/dev/null ||
  fail "def:1 is not true: $(cat "$work/oval")"
grep -Fx 'Definition oval:org.example:def:2: false' "$work/oval" >/dev/null ||
  fail "def:2 is not false: $(cat "$work/oval")"
grep -F 'definition_id="oval:org.example:def:1" result="true"' "$work/out/oval-results.xml" >/dev/null ||
  fail 'OVAL results file does not record def:1 as true'
grep -F 'definition_id="oval:org.example:def:2" result="false"' "$work/out/oval-results.xml" >/dev/null ||
  fail 'OVAL results file does not record def:2 as false'

# XCCDF: one rule passes and one fails, so oscap exits 2 and records both.
rule_result() {
  sed -n "/<rule-result idref=\"$1\"/,/<\/rule-result>/s/.*<result>\([a-z]*\)<\/result>.*/\1/p" "$2"
}
rc=0
scan xccdf eval --profile xccdf_org.example_profile_smoke \
  --results /out/results.xml --report /out/report.html xccdf.xml >"$work/eval" 2>&1 || rc=$?
test "$rc" -eq 2 || fail "xccdf eval with a failing rule exited $rc, expected 2: $(cat "$work/eval")"
test "$(rule_result xccdf_org.example_rule_root_login "$work/out/results.xml")" = pass ||
  fail 'root_login rule did not pass'
test "$(rule_result xccdf_org.example_rule_banner "$work/out/results.xml")" = fail ||
  fail 'banner rule did not fail'
grep -F 'Set a login banner' "$work/out/report.html" >/dev/null ||
  fail 'HTML report does not name the failing rule'

# Remediating the target flips the failing rule and oscap exits 0.
printf 'Banner /etc/issue\n' >>"$work/target/sshd_config"
scan xccdf eval --profile xccdf_org.example_profile_smoke \
  --results /out/results-fixed.xml xccdf.xml >"$work/eval-fixed" 2>&1 ||
  fail "xccdf eval with all rules passing failed: $(cat "$work/eval-fixed")"
test "$(rule_result xccdf_org.example_rule_banner "$work/out/results-fixed.xml")" = pass ||
  fail 'banner rule did not pass after remediation'

# Negative cases: malformed XML, schema-invalid XCCDF, and an unknown profile.
printf '<Benchmark xmlns="http://checklists.nist.gov/xccdf/1.2"><unclosed>' >"$work/content/broken.xml"
sed 's|<status>accepted</status>|<bogus/>|' "$work/content/xccdf.xml" >"$work/content/invalid.xml"

rc=0
scan xccdf validate broken.xml >"$work/broken" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'malformed XML unexpectedly validated'
grep -F 'Unable to parse XML' "$work/broken" >/dev/null ||
  fail "malformed XML diagnostic is missing: $(cat "$work/broken")"

rc=0
scan xccdf validate invalid.xml >"$work/invalid" 2>&1 || rc=$?
test "$rc" -eq 2 || fail "schema-invalid XCCDF exited $rc, expected 2"
grep -F 'Invalid XCCDF Checklist (1.2) content' "$work/invalid" >/dev/null ||
  fail "schema validation diagnostic is missing: $(cat "$work/invalid")"

rc=0
scan xccdf eval --profile xccdf_org.example_profile_missing xccdf.xml >"$work/noprofile" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'eval with an unknown profile unexpectedly succeeded'
grep -F 'No profile matching suffix' "$work/noprofile" >/dev/null ||
  fail "unknown profile diagnostic is missing: $(cat "$work/noprofile")"

printf 'SMOKE PASS\n'
