#!/bin/bash
set -euo pipefail

payload=${1:?usage: monitor_sboms.sh PAYLOAD}
repository=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}
run_url=${RUN_URL:?RUN_URL is required}
jq -e '
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
  .schema_version == 1 and
  (.delivery_id | type == "string" and test("^[a-f0-9]{64}$")) and
  (.logical_image_ref | type == "string" and test("^[A-Za-z0-9._/@:+-]+@sha256:[a-f0-9]{64}$")) and
  (.package_name | type == "string" and test("^[A-Za-z0-9._/@+-]{1,128}$")) and
  (.ecosystem | type == "string" and test("^[A-Za-z0-9._-]{1,64}$")) and
  (.version | type == "string" and test("^[A-Za-z0-9._:+~-]{1,128}$")) and
  (.vuln_id | type == "string" and test("^[A-Za-z0-9._-]{1,64}$")) and
  ((if has("severity") then .severity else "unknown" end) as $severity |
    ($severity == null) or
    (($severity | type == "string") and ($severity | length <= 256) and
      ((["unknown", "negligible", "low", "medium", "high", "critical"] | index($severity) != null) or
       ($severity | cvss)))) and
  (.platforms | type == "array" and length > 0) and
  all(.platforms[]; (.platform | test("^linux/(amd64|arm64)$")) and (.image_ref | test("^[A-Za-z0-9._/@:+-]+@sha256:[a-f0-9]{64}$")))
' "$payload" >/dev/null
delivery=$(jq -er .delivery_id "$payload")
title=$(jq -r '"[CVE] \(.package_name)@\(.version) \(.vuln_id)"' "$payload")
issues=$(gh api --paginate --slurp "repos/${repository}/issues?state=all&labels=squawk&per_page=100")
issue=$(jq -c --arg delivery "$delivery" '[.[][] | select(has("pull_request") | not) | select((.body // "") | contains("<!-- squawk-delivery:" + $delivery + " -->"))] | if length > 1 then error("duplicate Squawk delivery issues") else .[0] // null end' <<<"$issues")
body=$(mktemp)
trap 'rm -f "$body"' EXIT
jq -r --arg run "$run_url" '
  "<!-- squawk-delivery:\(.delivery_id) -->\nSquawk reported **\(.vuln_id)** for `\(.package_name)@\(.version)` in `\(.ecosystem)`.\n\n- Logical image: \(.logical_image_ref)\n- Severity: \(.severity // "unknown")\n- Workflow: \($run)\n\n| Platform | Digest |\n|---|---|\n" + ([.platforms[] | "| \(.platform) | `\(.image_ref)` |"] | join("\n"))
' "$payload" > "$body"
number=$(jq -r '.number // empty' <<<"$issue")
if [[ -z "$number" ]]; then
  gh label create squawk --repo "$repository" --color 5319E7 --description "Squawk vulnerability alert" --force
  gh issue create --repo "$repository" --title "$title" --body-file "$body" --label squawk
else
  [[ $(jq -r .state <<<"$issue") != closed ]] || gh issue reopen "$number" --repo "$repository"
  gh issue edit "$number" --repo "$repository" --body-file "$body"
fi
