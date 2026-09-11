#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   uv run scripts/test_build_monitor_inventory.py

from __future__ import annotations

from build_monitor_inventory import monitor_inventory


def entry(name: str, version: str, context: str, flavor: str = "plain") -> dict[str, str]:
    return {
        "name": name,
        "tag_version": version,
        "track": "wolfi",
        "context": context,
        "flavor": flavor,
    }


def image(name: str, version: str) -> dict[str, str]:
    return {"name": name, "version": version, "track": "wolfi"}


def exact_multiversion_catalog_is_preserved() -> None:
    catalog = {"images": [image("httpd", "2.4"), image("httpd", "2.4-fips")]}
    matrix = {
        "include": [
            entry("httpd", "2.4", "images/httpd"),
            entry("httpd", "2.4-fips", "images/httpd", "fips"),
        ]
    }
    assert monitor_inventory(catalog, matrix) == {
        "include": [
            {"name": "httpd", "tag_version": "2.4", "context": "images/httpd"},
            {
                "name": "httpd",
                "tag_version": "2.4-fips",
                "context": "images/httpd",
            },
        ]
    }


def retained_version_uses_current_context() -> None:
    catalog = {"images": [image("argocd", "3.7")]}
    matrix = {"include": [entry("argocd", "4.1", "images/argocd")]}
    assert monitor_inventory(catalog, matrix) == {
        "include": [
            {"name": "argocd", "tag_version": "3.7", "context": "images/argocd"}
        ]
    }


def retained_flavor_uses_matching_context() -> None:
    catalog = {"images": [image("caddy", "2.10-fips")]}
    matrix = {
        "include": [
            entry("caddy", "2.11", "images/caddy"),
            entry("caddy", "2.11-fips", "images/caddy", "fips"),
        ]
    }
    assert monitor_inventory(catalog, matrix)["include"][0]["context"] == "images/caddy"


def ambiguous_transition_fails_closed() -> None:
    catalog = {"images": [image("go", "1.24")]}
    matrix = {
        "include": [
            entry("go", "1.26", "images/go/1.26"),
            entry("go", "1.27", "images/go/1.27"),
        ]
    }
    try:
        monitor_inventory(catalog, matrix)
    except SystemExit as error:
        assert "maps to 2 current contexts" in str(error)
    else:
        raise AssertionError("ambiguous retained image context was accepted")


def missing_context_fails_closed() -> None:
    try:
        monitor_inventory({"images": [image("missing", "1")]}, {"include": []})
    except SystemExit as error:
        assert "maps to 0 current contexts" in str(error)
    else:
        raise AssertionError("unmapped published image was accepted")


def main() -> None:
    exact_multiversion_catalog_is_preserved()
    retained_version_uses_current_context()
    retained_flavor_uses_matching_context()
    ambiguous_transition_fails_closed()
    missing_context_fails_closed()
    print("passed scripts/test_build_monitor_inventory.py")


if __name__ == "__main__":
    main()
