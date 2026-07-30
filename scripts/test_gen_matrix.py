#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   uv run scripts/test_gen_matrix.py

from gen_matrix import generate


def main() -> None:
    entries = [entry for entry in generate(None)["include"] if entry["name"] == "caddy"]
    assert {(entry["version"], entry["flavor"]) for entry in entries} == {
        (version, flavor)
        for version in ("2.11.0", "2.11.1", "2.11.2", "2.11.3", "2.11.4")
        for flavor in ("plain", "fips")
    }
    assert {
        (entry["version"], entry["flavor"])
        for entry in entries
        if entry["latest"] or entry["major"]
    } == {("2.11.4", "plain"), ("2.11.4", "fips")}


if __name__ == "__main__":
    main()
