#!/usr/bin/env python3
"""Every annotated melange source version has a commit pin Renovate rewrites.

A recipe that checks out `tag: ...${{package.version}}...` (or a var-transform of
it) with `expected-commit` breaks its own build if a version bump leaves the
commit behind. The melange source manager in renovate.json therefore captures
the annotated `package.version` together with the commit, in either form:

- literal: `expected-commit: <40 hex>` on the git-checkout step;
- var: `vars.source-commit: <40 hex>` with `expected-commit: ${{vars.source-commit}}`.

This test proves, for every recipe in the repository, that the manager extracts
exactly that pair from the checkout that consumes the version, and that the
configured replacement rewrites the version and every copy of the commit.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path

import gen_matrix

ROOT = Path(__file__).resolve().parents[1]
RENOVATE = ROOT / "renovate.json"
SHA = re.compile(r"[0-9a-f]{40}")
VERSION_LINE = re.compile(
    r"^  version: [\"']?(?P<value>[^\"'\s#]+)[\"']?[ \t]+#[ \t]*renovate:(?P<annotation>.*)$"
)
CHECKOUT_STEP = re.compile(r"^(?P<indent>[ \t]*)- uses: git-checkout[ \t]*$")
KEY_VALUE = re.compile(r"^(?P<indent>[ \t]*)(?:- )?(?P<key>[A-Za-z0-9_-]+):[ \t]*(?P<value>.*?)[ \t]*$")
VERSION_REF = "${{package.version}}"
SOURCE_COMMIT_REF = "${{vars.source-commit}}"
# A derived extractVersion embeds the literal tag prefix and suffix. Restrict
# them to characters with no regex meaning; anything else needs an explicit
# `extractVersion=` on the annotation.
PLAIN_AFFIX = re.compile(r"[A-Za-z0-9_/-]*")
EXPECTED_TEMPLATE = (
    "{{#if newDigest}}{{{replace '@@VERITY_NEW_VERSION@@' newValue "
    "(replace '^(  version: \\W?)[0-9][0-9A-Za-z.+_-]*' '$1@@VERITY_NEW_VERSION@@' "
    "(replace currentDigest newDigest replaceString))}}}"
    "{{else}}{{{replaceString}}}{{/if}}"
)
EXPECTED_EXTRACT_VERSION_TEMPLATE = (
    "{{#if extractVersion}}{{{extractVersion}}}"
    "{{else}}^{{{tagPrefix}}}(?<version>.+){{{tagSuffix}}}${{/if}}"
)


def source_manager() -> dict:
    managers = json.loads(RENOVATE.read_text(encoding="utf-8"))["customManagers"]
    found = [manager for manager in managers if manager.get("depTypeTemplate") == "source"]
    assert len(found) == 1, "renovate.json must define exactly one melange source manager"
    return found[0]


def python_pattern(pattern: str) -> re.Pattern[str]:
    return re.compile(pattern.replace("(?<", "(?P<"))


def file_patterns(manager: dict) -> list[re.Pattern[str]]:
    patterns = []
    for raw in manager["managerFilePatterns"]:
        assert raw.startswith("/") and raw.endswith("/"), raw
        patterns.append(re.compile(raw[1:-1]))
    return patterns


def unquote(value: str) -> str:
    if len(value) >= 2 and value[0] == value[-1] == "'":
        return value[1:-1].replace("''", "'")
    if len(value) >= 2 and value[0] == value[-1] == '"':
        return json.loads(value)
    return value


def strip_comment(value: str) -> str:
    if value.startswith(("'", '"')):
        return value
    return re.sub(r"[ \t]+#.*$", "", value)


def top_level_block(lines: list[str], name: str) -> list[str]:
    for index, line in enumerate(lines):
        if line == f"{name}:":
            block = []
            for child in lines[index + 1 :]:
                if child and not child[0].isspace() and not child.startswith("#"):
                    break
                block.append(child)
            return block
    return []


def parse_vars(lines: list[str]) -> dict[str, str]:
    result = {}
    for line in top_level_block(lines, "vars"):
        match = re.match(r"^  (?P<key>[A-Za-z0-9_-]+):[ \t]*(?P<value>.*?)[ \t]*$", line)
        if match:
            result[match["key"]] = unquote(strip_comment(match["value"]))
    return result


def parse_var_transforms(lines: list[str]) -> list[dict[str, str]]:
    entries: list[dict[str, str]] = []
    for line in top_level_block(lines, "var-transforms"):
        match = KEY_VALUE.match(line)
        if not match or line.lstrip().startswith("#"):
            continue
        if line.lstrip().startswith("- "):
            entries.append({})
        if entries:
            entries[-1][match["key"]] = unquote(strip_comment(match["value"]))
    return entries


@dataclass(frozen=True)
class Checkout:
    line: int
    fields: dict[str, str]


def parse_checkouts(lines: list[str]) -> list[Checkout]:
    checkouts = []
    for index, line in enumerate(lines):
        step = CHECKOUT_STEP.match(line)
        if not step:
            continue
        step_indent = len(step["indent"])
        fields: dict[str, str] = {}
        cursor = index + 1
        with_indent = None
        while cursor < len(lines):
            current = lines[cursor]
            stripped = current.strip()
            indent = len(current) - len(current.lstrip())
            if stripped and not stripped.startswith("#") and indent <= step_indent:
                break
            if stripped == "with:":
                with_indent = indent
            elif with_indent is not None and stripped and not stripped.startswith("#"):
                if indent <= with_indent:
                    break
                match = KEY_VALUE.match(current)
                if match:
                    fields[match["key"]] = unquote(strip_comment(match["value"]))
            cursor += 1
        checkouts.append(Checkout(index, fields))
    return checkouts


def go_replacement(replacement: str) -> str:
    # melange var-transforms use Go regexp expansion: ${1} or $1.
    return re.sub(r"\$\{?(\d+)\}?", r"\\g<\1>", replacement)


def transformed_vars(transforms: list[dict[str, str]], version: str) -> dict[str, str]:
    result = {}
    for entry in transforms:
        if VERSION_REF not in entry.get("from", ""):
            continue
        source = entry["from"].replace(VERSION_REF, version)
        result[entry["to"]] = re.sub(entry["match"], go_replacement(entry["replace"]), source)
    return result


def render_tag(tag: str, version: str, transforms: list[dict[str, str]]) -> str:
    rendered = tag.replace(VERSION_REF, version)
    for name, value in transformed_vars(transforms, version).items():
        rendered = rendered.replace("${{vars.%s}}" % name, value)
    return rendered


def annotation_fields(annotation: str) -> dict[str, str]:
    return dict(token.split("=", 1) for token in annotation.split() if "=" in token)


def extract(manager: dict, text: str) -> list[re.Match[str]]:
    found = []
    for raw in manager["matchStrings"]:
        found.extend(python_pattern(raw).finditer(text))
    return found


def apply_upgrade(match: re.Match[str], text: str, new_value: str, new_digest: str) -> str:
    """Mirror EXPECTED_TEMPLATE: every commit copy, then the leading version."""
    region = match[0].replace(match["currentDigest"], new_digest)
    region = re.sub(
        r"^(  version: \W?)[0-9][0-9A-Za-z.+_-]*",
        lambda prefix: prefix[1] + new_value,
        region,
        count=1,
    )
    return text[: match.start()] + region + text[match.end() :]


def bumped(version: str) -> str:
    """A different version with the same shape, so a strict extractVersion still matches."""
    digits = [index for index, char in enumerate(version) if char.isdigit()]
    index = digits[-1]
    replacement = "1" if version[index] == "0" else "0"
    return version[:index] + replacement + version[index + 1 :]


def violations(manager: dict, path: str, text: str) -> list[str]:
    """Return why `text` fails the source-pin contract; empty when compliant or out of scope."""
    lines = text.splitlines()
    version_lines = [(index, VERSION_LINE.match(line)) for index, line in enumerate(lines)]
    version_lines = [(index, match) for index, match in version_lines if match]
    if not version_lines:
        return []
    if len(version_lines) != 1:
        return [f"{path}: expected one annotated package.version line"]
    version_index, version_match = version_lines[0]
    version = version_match["value"]
    annotation = annotation_fields(version_match["annotation"])
    transforms = parse_var_transforms(lines)
    derived = set(transformed_vars(transforms, version))
    sources = []
    for checkout in parse_checkouts(lines):
        tag = checkout.fields.get("tag", "")
        if VERSION_REF in tag or any("${{vars.%s}}" % name in tag for name in derived):
            sources.append(checkout)
    if not sources:
        if extract(manager, text):
            return [f"{path}: source manager extracted a git-checkout that does not consume package.version"]
        return []

    problems = []
    if len(sources) != 1:
        problems.append(f"{path}: {len(sources)} git-checkout steps consume package.version; expected one")
        return problems
    checkout = sources[0]
    tag = checkout.fields["tag"]
    expected_commit = checkout.fields.get("expected-commit", "")
    if SHA.fullmatch(expected_commit):
        commit = expected_commit
    elif expected_commit == SOURCE_COMMIT_REF:
        commit = parse_vars(lines).get("source-commit", "")
        if not SHA.fullmatch(commit):
            problems.append(f"{path}: vars.source-commit must be a full 40-hex commit")
    else:
        problems.append(
            f"{path}: expected-commit must be a 40-hex commit or {SOURCE_COMMIT_REF}, "
            f"not {expected_commit!r}"
        )
    if problems:
        return problems

    matches = extract(manager, text)
    if len(matches) != 1:
        return [f"{path}: renovate.json source manager found {len(matches)} matches; expected one"]
    match = matches[0]
    if match.start() != sum(len(line) + 1 for line in lines[:version_index]):
        problems.append(f"{path}: source manager did not start at the package.version line")
    if match["currentValue"] != version:
        problems.append(f"{path}: source manager captured version {match['currentValue']!r}")
    if match["currentDigest"] != commit:
        problems.append(f"{path}: source manager captured commit {match['currentDigest']!r}, not {commit}")
    if match["repository"] != checkout.fields.get("repository"):
        problems.append(f"{path}: source manager captured repository {match['repository']!r}")
    if match.end() != len(text):
        problems.append(f"{path}: source manager replacement must reach the end of the file")
    if text.find(commit) < match.start():
        problems.append(f"{path}: commit {commit} appears above package.version and would go stale")

    if annotation.get("extractVersion"):
        extract_version = annotation["extractVersion"]
    elif match["tagPrefix"] is None:
        problems.append(f"{path}: a var-transform tag needs extractVersion= on the annotation")
        return problems
    else:
        prefix, suffix = match["tagPrefix"], match["tagSuffix"]
        if not (PLAIN_AFFIX.fullmatch(prefix) and PLAIN_AFFIX.fullmatch(suffix)):
            problems.append(f"{path}: tag affixes in {tag!r} need an explicit extractVersion=")
            return problems
        extract_version = f"^{prefix}(?<version>.+){suffix}$"
    extractor = python_pattern(extract_version)
    for candidate in (version, bumped(version)):
        rendered = render_tag(tag, candidate, transforms)
        recovered = extractor.match(rendered)
        if not recovered or recovered["version"] != candidate:
            problems.append(f"{path}: extractVersion {extract_version} does not recover {candidate} from tag {rendered}")
    if problems:
        return problems

    new_value = bumped(version)
    new_digest = "f" * 40 if commit != "f" * 40 else "e" * 40
    updated = apply_upgrade(match, text, new_value, new_digest)
    after = extract(manager, updated)
    if len(after) != 1 or after[0]["currentValue"] != new_value or after[0]["currentDigest"] != new_digest:
        problems.append(f"{path}: an upgrade does not round-trip through the source manager")
    if commit in updated:
        problems.append(f"{path}: an upgrade leaves a stale copy of {commit}")
    return problems


LITERAL_RECIPE = """package:
  name: verity-example
  # yamllint disable-line rule:line-length
  version: "1.2.3"  # renovate: datasource=github-releases depName=example/tool extractVersion=^v(?<version>.+)$
  epoch: 0

pipeline:
  - uses: git-checkout
    with:
      repository: https://github.com/example/tool
      tag: v${{package.version}}
      expected-commit: 0123456789abcdef0123456789abcdef01234567

  - runs: |
      go build -ldflags="-X main.commit=0123456789abcdef0123456789abcdef01234567" .
"""

VAR_RECIPE = """package:
  name: verity-example
  version: 2.0.0 # renovate: datasource=github-tags depName=example/tool
  epoch: 0

vars:
  source-commit: 89abcdef0123456789abcdef0123456789abcdef

pipeline:
  - uses: git-checkout
    with:
      repository: https://github.com/example/tool
      tag: release-${{package.version}}
      # The tag is annotated; this is the peeled commit.
      expected-commit: ${{vars.source-commit}}
"""

TRANSFORM_RECIPE = """package:
  name: verity-example
  version: "8.4.11"  # renovate: datasource=github-tags depName=example/server extractVersion=^Server-(?<version>8\\.4\\.\\d+)-\\d+$
  epoch: 0

var-transforms:
  - from: ${{package.version}}
    match: '^(\\d+\\.\\d+\\.(\\d+))$'
    replace: 'Server-${1}-${2}'
    to: release-tag

pipeline:
  - uses: git-checkout
    with:
      repository: https://github.com/example/server
      tag: ${{vars.release-tag}}
      expected-commit: 0123456789abcdef0123456789abcdef01234567
"""


def test_fixtures(manager: dict) -> None:
    for name, text in (("literal", LITERAL_RECIPE), ("var", VAR_RECIPE), ("transform", TRANSFORM_RECIPE)):
        assert violations(manager, name, text) == [], (name, violations(manager, name, text))

    # Both forms move the version and every commit copy, and nothing else.
    literal = extract(manager, LITERAL_RECIPE)[0]
    updated = apply_upgrade(literal, LITERAL_RECIPE, "1.2.4", "f" * 40)
    assert updated == LITERAL_RECIPE.replace('"1.2.3"', '"1.2.4"').replace(literal["currentDigest"], "f" * 40)
    var = extract(manager, VAR_RECIPE)[0]
    updated = apply_upgrade(var, VAR_RECIPE, "2.0.1", "f" * 40)
    assert updated == VAR_RECIPE.replace("2.0.0", "2.0.1").replace(var["currentDigest"], "f" * 40)

    # A recipe with no version annotation is out of scope.
    assert violations(manager, "plain", LITERAL_RECIPE.replace("# renovate:", "# note:")) == []

    regressions = {
        "other commit var": VAR_RECIPE.replace("${{vars.source-commit}}", "${{vars.commit}}"),
        "short commit": LITERAL_RECIPE.replace(
            "expected-commit: 0123456789abcdef0123456789abcdef01234567", "expected-commit: 0123456"
        ),
        "commit above version": LITERAL_RECIPE.replace(
            "package:\n", "# built from 0123456789abcdef0123456789abcdef01234567\npackage:\n", 1
        ),
        "transform without extractVersion": TRANSFORM_RECIPE.replace(
            " extractVersion=^Server-(?<version>8\\.4\\.\\d+)-\\d+$", ""
        ),
        "regex affix without extractVersion": VAR_RECIPE.replace("tag: release-", "tag: release.v"),
        "wrong extractVersion": LITERAL_RECIPE.replace("extractVersion=^v(?<version>.+)$", "extractVersion=^(?<version>.+)$"),
        "second checkout": LITERAL_RECIPE + LITERAL_RECIPE[LITERAL_RECIPE.index("  - uses: git-checkout") :],
        "unrelated var tag": TRANSFORM_RECIPE.replace("    to: release-tag\n", "    to: other-tag\n"),
    }
    for name, text in regressions.items():
        assert violations(manager, name, text), f"fixture {name!r} must be rejected"


def test_repository(manager: dict) -> tuple[int, int]:
    patterns = file_patterns(manager)
    problems = []
    literal = var = 0
    recipes = (path for top in ("images", "packages", "patched") for path in (ROOT / top).rglob("*.y*ml"))
    for path in sorted(recipes):
        relative = path.relative_to(ROOT).as_posix()
        if not any(pattern.search(relative) for pattern in patterns):
            continue
        text = path.read_text(encoding="utf-8")
        found = violations(manager, relative, text)
        problems.extend(found)
        matches = extract(manager, text)
        if not found and matches:
            if SOURCE_COMMIT_REF in matches[0][0]:
                var += 1
            else:
                literal += 1
    assert not problems, "\n".join(problems)
    assert literal and var, "both commit pin forms must stay covered"
    return literal, var


def stream_class(path: Path) -> str:
    """How far an in-stream source bump may go before it moves the published stream.

    gen_matrix publishes the melange version truncated to the width of
    metadata.yaml `versions:`, so `[2]` keeps every 2.x release in the 2 stream
    ("major"), `[1.11]` keeps only 1.11.x ("minor"), and a full version such as
    `[0.27.4]` changes stream on every release. That, a literal or
    vars.upstream-version channel, or a disabled image the build gate skips is
    "manual": no source bump may automerge.
    """
    metadata_path = path.parent / "metadata.yaml"
    relative = path.relative_to(ROOT).as_posix()
    if not relative.startswith("images/") or not metadata_path.is_file():
        return "manual"
    metadata = gen_matrix.parse_metadata(metadata_path)
    text = path.read_text(encoding="utf-8")
    if not metadata.enabled or gen_matrix.block_scalar(text, "vars", "upstream-version") is not None:
        return "manual"
    version = str(metadata.versions[0])
    if not gen_matrix.NUMERIC_VERSION.fullmatch(version):
        return "manual"
    return {1: "major", 2: "minor"}.get(len(version.split(".")), "manual")


def test_stream_rules(manager: dict) -> dict[str, int]:
    rules = [rule for rule in json.loads(RENOVATE.read_text(encoding="utf-8"))["packageRules"]
             if rule.get("matchDepTypes") == ["source"]]
    major_streams = next(rule for rule in rules if rule.get("separateMinorPatch") is False)
    patch_rule = next(rule for rule in rules if rule.get("matchUpdateTypes") == ["patch"])
    minor_rule = next(rule for rule in rules if rule.get("matchUpdateTypes") == ["minor"])
    assert not any("major" in rule.get("matchUpdateTypes", []) and rule.get("automerge") for rule in rules), (
        "major source updates must never automerge"
    )

    patterns = file_patterns(manager)
    classes: dict[str, list[str]] = {"major": [], "minor": [], "manual": []}
    recipes = (path for top in ("images", "packages", "patched") for path in (ROOT / top).rglob("*.y*ml"))
    for path in sorted(recipes):
        relative = path.relative_to(ROOT).as_posix()
        if any(pattern.search(relative) for pattern in patterns) and extract(manager, path.read_text(encoding="utf-8")):
            classes[stream_class(path)].append(relative)

    expected_major = sorted(classes["major"])
    assert major_streams["matchFileNames"] == expected_major, (
        "renovate.json major-version stream list must equal the source recipes whose metadata.yaml "
        f"versions has one component and that are enabled: {expected_major}"
    )
    assert minor_rule["matchFileNames"] == expected_major
    # Only images/** can automerge a patch; manual recipes there are excluded by name.
    expected_patch = ["images/**"] + sorted(
        f"!{relative}" for relative in classes["manual"] if relative.startswith("images/")
    )
    assert patch_rule["matchFileNames"] == expected_patch, (
        "renovate.json in-stream patch exclusions must equal the enabled-image source recipes that "
        f"cannot take an automatic bump: {expected_patch[1:]}"
    )
    return {name: len(paths) for name, paths in classes.items()}


def test_manager_shape(manager: dict) -> None:
    assert manager["datasourceTemplate"] == "git-tags"
    assert manager["packageNameTemplate"] == "{{{repository}}}"
    assert manager["extractVersionTemplate"] == EXPECTED_EXTRACT_VERSION_TEMPLATE
    # apply_upgrade mirrors this template; keep them in lockstep.
    assert manager["autoReplaceStringTemplate"] == EXPECTED_TEMPLATE
    assert len(manager["matchStrings"]) == 2


def main() -> None:
    manager = source_manager()
    test_manager_shape(manager)
    test_fixtures(manager)
    literal, var = test_repository(manager)
    streams = test_stream_rules(manager)
    print(
        f"passed scripts/test_melange_source_pins.py ({literal} literal, {var} var commit pins; "
        f"{streams['major']} major, {streams['minor']} minor, {streams['manual']} manual streams)"
    )


if __name__ == "__main__":
    main()
