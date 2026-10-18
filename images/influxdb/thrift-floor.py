"""Lift thrift 0.17 to a fixed release in the InfluxDB 3 dependency graph.

parquet 55 and the influxdb3_core git crates pin thrift 0.17, which carries
CVE-2026-43868 (fixed in 0.23.0). Cargo cannot raise a dependent's own
requirement, so patch copies of those crates: the registry parquet crate and
every crate of the influxdb3_core revision recorded in Cargo.lock. Run from the
checkout root after the Cargo.lock pins; the caller re-locks the workspace
afterwards.

The requirement is written as an exact `=THRIFT_VERSION` so the relocked
workspace cannot float to a newer release.

usage: python3 thrift-floor.py THRIFT_VERSION
"""
import glob, os, pathlib, re, subprocess, sys, tomllib

FLOOR = "=" + sys.argv[1]
ROOT = pathlib.Path("/tmp/influx-patched")
ROOT.mkdir()
CORE = "https://github.com/influxdata/influxdb3_core"

with open("Cargo.lock", "rb") as handle:
    lock = tomllib.load(handle)
core_names, revs = set(), set()
for pkg in lock["package"]:
    source = pkg.get("source", "")
    if source.startswith("git+" + CORE + "?rev="):
        core_names.add(pkg["name"])
        revs.add(source.split("?rev=")[1].split("#")[0])
assert len(revs) == 1, revs
rev = revs.pop()

core = ROOT / "core"
subprocess.run(["git", "init", "-q", str(core)], check=True)
subprocess.run(["git", "-C", str(core), "fetch", "-q", "--depth", "1", CORE, rev], check=True)
subprocess.run(["git", "-C", str(core), "checkout", "-q", "FETCH_HEAD"], check=True)
head = subprocess.run(["git", "-C", str(core), "rev-parse", "HEAD"], check=True, capture_output=True, text=True).stdout.strip()
assert head == rev, (head, rev)

dirs = {}
for manifest in core.rglob("Cargo.toml"):
    data = tomllib.loads(manifest.read_text())
    if "package" in data:
        dirs[data["package"]["name"]] = manifest.parent
assert core_names <= dirs.keys(), core_names - dirs.keys()

pattern = re.compile(r'^(thrift\s*=\s*(?:\{\s*version\s*=\s*)?)"0\.17(?:\.0)?"', re.M)
patched = []
for name in sorted(core_names):
    manifest = dirs[name] / "Cargo.toml"
    text = manifest.read_text()
    updated = pattern.sub(lambda m: m.group(1) + '"' + FLOOR + '"', text)
    if updated != text:
        manifest.write_text(updated)
        patched.append(name)
assert {"parquet_file", "trace_exporters", "workspace-hack"} <= set(patched), patched

version = next(p["version"] for p in lock["package"] if p["name"] == "parquet" and p.get("source", "").startswith("registry+"))
subprocess.run(["cargo", "fetch"], check=True)
home = os.environ.get("CARGO_HOME") or os.path.expanduser("~/.cargo")
(source,) = glob.glob(f"{home}/registry/src/*/parquet-{version}")
parquet = ROOT / "parquet"
subprocess.run(["cp", "-r", source, str(parquet)], check=True)
manifest = parquet / "Cargo.toml"
text = manifest.read_text()
old = '[dependencies.thrift]\nversion = "0.17"\n'
assert old in text
# thrift 0.23 adds a UUID read method to its protocol trait.
text = text.replace(old, '[dependencies.uuid]\nversion = "1"\ndefault-features = false\n\n[dependencies.thrift]\nversion = "' + FLOOR + '"\n', 1)
manifest.write_text(text)
source_file = parquet / "src" / "thrift.rs"
text = source_file.read_text()
anchor = "    fn read_string(&mut self) -> thrift::Result<String> {"
assert text.count(anchor) == 1
text = text.replace(anchor, "    fn read_uuid(&mut self) -> thrift::Result<uuid::Uuid> {\n        thrift_unimplemented!()\n    }\n\n" + anchor, 1)
source_file.write_text(text)

tables = re.findall(r"(?m)^\[[^\]\n]+\]", pathlib.Path("Cargo.toml").read_text())
# The appended entries are only valid as the tail of the root [patch.crates-io] table.
assert tables and tables[-1] == "[patch.crates-io]", tables[-1:]
with open("Cargo.toml", "a") as out:
    out.write(f'parquet = {{ path = "{parquet}" }}\n\n[patch."{CORE}"]\n')
    for name in sorted(core_names):
        out.write(f'{name} = {{ path = "{dirs[name]}" }}\n')
