def metric($allowed):
  split(":") as $part |
  (($part | length) == 2) and (($allowed[$part[0]] // []) | index($part[1]) != null);
def metrics($allowed):
  split("/") as $parts | (($parts | length) > 1) and all($parts[]; metric($allowed));
def vector($versions; $allowed):
  split("/") as $parts |
  ($versions | index($parts[0]) != null) and (($parts | length) > 1) and
  all($parts[1:][]; metric($allowed));
def cvss:
  if startswith("CVSS:3.") then
    vector(["CVSS:3.0", "CVSS:3.1"]; {
      AV:["N","A","L","P"], AC:["L","H"], PR:["N","L","H"], UI:["N","R"],
      S:["U","C"], C:["N","L","H"], I:["N","L","H"], A:["N","L","H"],
      E:["X","H","F","P","U"], RL:["X","O","T","W","U"], RC:["X","C","R","U"],
      CR:["X","H","M","L"], IR:["X","H","M","L"], AR:["X","H","M","L"],
      MAV:["X","N","A","L","P"], MAC:["X","L","H"], MPR:["X","N","L","H"],
      MUI:["X","N","R"], MS:["X","U","C"], MC:["X","N","L","H"],
      MI:["X","N","L","H"], MA:["X","N","L","H"]
    })
  elif startswith("CVSS:4.0/") then
    vector(["CVSS:4.0"]; {
      AV:["N","A","L","P"], AC:["L","H"], AT:["N","P"], PR:["N","L","H"],
      UI:["N","P","A"], VC:["H","L","N"], VI:["H","L","N"], VA:["H","L","N"],
      SC:["H","L","N"], SI:["H","L","N"], SA:["H","L","N"], E:["X","A","P","U"],
      CR:["X","H","M","L"], IR:["X","H","M","L"], AR:["X","H","M","L"],
      MAV:["X","N","A","L","P"], MAC:["X","L","H"], MAT:["X","N","P"],
      MPR:["X","N","L","H"], MUI:["X","N","P","A"], MVC:["X","H","L","N"],
      MVI:["X","H","L","N"], MVA:["X","H","L","N"], MSC:["X","H","L","N"],
      MSI:["X","H","L","N","S"], MSA:["X","H","L","N","S"],
      S:["X","N","P"], AU:["X","N","Y"], R:["X","A","U","I"],
      V:["X","D","C"], RE:["X","L","M","H"], U:["X","Clear","Green","Amber","Red"]
    })
  elif startswith("AV:") then
    metrics({
      AV:["L","A","N"], AC:["H","M","L"], Au:["M","S","N"],
      C:["N","P","C"], I:["N","P","C"], A:["N","P","C"],
      E:["ND","U","POC","F","H"], RL:["ND","OF","TF","W","U"],
      RC:["ND","UC","UR","C"], CDP:["ND","N","L","LM","MH","H"],
      TD:["ND","N","L","M","H"], CR:["ND","L","M","H"],
      IR:["ND","L","M","H"], AR:["ND","L","M","H"]
    })
  else false end;
def severity:
  . as $severity |
  $severity == null or
  (($severity | type == "string") and ($severity | length <= 256) and
    ((["unknown", "negligible", "low", "medium", "high", "critical"] | index($severity) != null) or
     ($severity | cvss)));
def digest_ref:
  type == "string" and test("^[A-Za-z0-9._/@:+-]+@sha256:[a-f0-9]{64}$");
def decimal_string: type == "string" and test("^[1-9][0-9]*$");
def hex: type == "string" and test("^[a-f0-9]{64}$");
def integer: type == "number" and floor == . and . >= -9007199254740991 and . <= 9007199254740991;
def identifier($maximum):
  type == "string" and length > 0 and length <= $maximum and test("^[A-Za-z0-9._/@:+~-]+$");
def finding:
  (.delivery_id | hex) and
  (.package_name | identifier(128)) and
  (.ecosystem | type == "string" and test("^[A-Za-z0-9._:-]{1,64}$")) and
  (.version | identifier(128)) and
  (.vuln_id | type == "string" and test("^[A-Za-z0-9._-]{1,64}$")) and
  ((if has("severity") then .severity else "unknown" end) | severity);
def platform_identity($image):
  (.platform | test("^linux/(amd64|arm64)$")) and
  (.image_ref | digest_ref) and
  ((.image_ref | split("@sha256:")[0]) == ($image | split("@sha256:")[0]));
def finding_platforms($image):
  type == "array" and length > 0 and all(.[]; platform_identity($image));
def platform_set($image):
  type == "array" and length == 2 and
  ([.[].platform] | sort == ["linux/amd64", "linux/arm64"]) and
  ([.[].image_ref] | unique | length == 2) and
  all(.[]; platform_identity($image));
def source_hint:
  (.installation_id | decimal_string) and (.repository_id | decimal_string);
def wakeup:
  (.delivery_id | hex) and
  (.logical_image_ref | digest_ref) and
  if .schema_version == 1 then
    finding and (.logical_image_ref as $image | .platforms | finding_platforms($image))
  else
    .schema_version == 2 and .event == "reconcile" and (.source | source_hint)
  end;
def checkpoint_common:
  (.checkpoint_id | hex) and
  (.revision | integer and . > 0) and
  (.payload_sha256 | hex) and
  (.logical_image_ref | digest_ref) and
  (.source.installation_id | decimal_string) and
  (.source.repository_id | decimal_string) and
  (.source.ingestion_delivery_id | type == "string" and test("^[A-Za-z0-9._:-]{1,128}$"));
def inventory_checkpoint:
  .logical_image_ref as $image |
  .coverage.evaluated_at as $evaluated |
  (.platforms | map({key: .platform, value: .image_ref}) | from_entries) as $covered |
  (.coverage.status == "complete") and
  ($evaluated | integer) and
  (.coverage.advisory_feed_checked_at | integer) and
  (.coverage.advisory_feed_checked_at <= $evaluated) and
  (.coverage.feed_checkpoint_ids | type == "array" and length > 0 and (unique | length) == length and all(.[]; hex)) and
  (.coverage.unsupported_components == []) and
  (.platforms | platform_set($image)) and
  all(.platforms[];
    .status == "complete" and (.sbom_sha256 | hex) and (.indexed_at | integer) and
    .indexed_at <= $evaluated) and
  (.findings | type == "array") and
  ([.findings[].delivery_id] | unique | length) == (.findings | length) and
  all(.findings[];
    finding and
    (.platforms | type == "array" and length > 0 and length <= 2 and (unique | length) == length) and
    all(.platforms[]; $covered[.] != null));
def retirement_checkpoint:
  (.retired_at | integer) and
  (.authoritative_source_event_id | type == "string" and test("^[A-Za-z0-9._:-]{1,128}$")) and
  (.replacement.logical_image_ref | digest_ref) and
  (.replacement.logical_image_ref != .logical_image_ref) and
  ((.replacement.logical_image_ref | split("@sha256:")[0]) == (.logical_image_ref | split("@sha256:")[0])) and
  (.replacement.published_at | integer) and
  (.replacement.published_at <= .retired_at) and
  (.replacement.run_url | type == "string" and test("^https://github\\.com/tektum/verity-images/actions/runs/[1-9][0-9]*$"));
def ready_checkpoint:
  .schema_version == 2 and .state == "ready" and
  (.checkpoint | checkpoint_common) and
  (.checkpoint |
    if .kind == "inventory_snapshot" then inventory_checkpoint
    elif .kind == "retirement" then retirement_checkpoint
    else false end);
if $mode == "wakeup" then wakeup
elif $mode == "checkpoint" then ready_checkpoint
else false end
