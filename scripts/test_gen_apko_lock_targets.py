#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   uv run scripts/test_gen_apko_lock_targets.py

from pathlib import Path
from tempfile import TemporaryDirectory
from typing import Final
from unittest.mock import patch

import gen_apko_lock_targets

ROOT: Final = gen_apko_lock_targets.ROOT


def write_image(
    directory: Path,
    *,
    name: str,
    track: str = "wolfi",
    enabled: bool = True,
    versions: str = "1",
    flavors: str | None = None,
    recipe: bool = False,
    flavor_recipe: str | None = None,
    flavor_config: str | None = None,
    wrapper: str | None = None,
    locks: tuple[str, ...] = ("apko.lock.json",),
    config_body: str = "contents:\n  packages:\n    - busybox\n",
) -> None:
    (directory / "tests").mkdir(parents=True)
    (directory / "tests/test.sh").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    (directory / "apko.yaml").write_text(config_body, encoding="utf-8")
    flavor_line = "" if flavors is None else f"flavors: [{flavors}]\n"
    (directory / "metadata.yaml").write_text(
        f"name: {name}\ntrack: {track}\ndescription: Example.\n"
        f"upstream: https://example.com/\nversions: [{versions}]\n"
        f"enabled: {'true' if enabled else 'false'}\n{flavor_line}",
        encoding="utf-8",
    )
    if track == "patched":
        (directory / "source.yaml").write_text(
            f"image: docker.io/example/{name}:1\ndigest: sha256:{'0' * 64}\n"
            "platforms: [linux/amd64, linux/arm64]\n",
            encoding="utf-8",
        )
    if recipe:
        (directory / "melange.yaml").write_text(
            'package:\n  name: example\n  version: "1.0"\n', encoding="utf-8"
        )
    if flavor_recipe is not None:
        (directory / f"{flavor_recipe}.melange.yaml").write_text(
            "package:\n  name: example-flavor\n", encoding="utf-8"
        )
    if flavor_config is not None:
        (directory / f"{flavor_config}.apko.yaml").write_text(config_body, encoding="utf-8")
    if wrapper is not None:
        (directory / f"{wrapper}-wrapper.apko.yaml").write_text(config_body, encoding="utf-8")
    for lock in locks:
        (directory / lock).write_text("{}\n", encoding="utf-8")


def generated(root: Path, image: str | None = None) -> list[dict[str, object]]:
    directories = sorted(path.parent for path in root.glob("**/metadata.yaml"))
    with (
        patch.object(gen_apko_lock_targets, "ROOT", root),
        patch.object(gen_apko_lock_targets.gen_matrix, "image_directories", return_value=directories),
    ):
        return gen_apko_lock_targets.generate(image)["images"]


def refused(root: Path, image: str | None = None) -> str:
    try:
        generated(root, image)
    except gen_apko_lock_targets.LockDiscoveryError as error:
        return str(error)
    raise AssertionError("an unlockable image definition was accepted")


def check_eligibility() -> None:
    with TemporaryDirectory() as temporary:
        root = Path(temporary)
        write_image(root / "images/pure", name="pure")
        write_image(root / "images/sourced", name="sourced", recipe=True)
        write_image(
            root / "images/mixed",
            name="mixed",
            flavors="plain, fips",
            flavor_recipe="fips",
            flavor_config="fips",
            locks=("apko.lock.json", "fips.apko.lock.json"),
        )
        write_image(
            root / "images/dual",
            name="dual",
            flavors="plain, dev",
            flavor_config="dev",
            locks=("apko.lock.json", "dev.apko.lock.json"),
        )
        write_image(root / "images/quarantined", name="quarantined", enabled=False)
        write_image(root / "patched/upstream", name="upstream", track="patched")
        images = generated(root)

        # A pure APKO variant owns a committed lock, so it is refreshable.
        assert [entry["context"] for entry in images] == ["images/dual", "images/mixed", "images/pure"]
        # A melange-backed image resolves its lock during the build from an ephemeral
        # signed package, and a flavor recipe does the same for that flavor only.
        assert [lock["flavor"] for lock in images[1]["locks"]] == ["plain"]
        assert [(lock["flavor"], lock["config"], lock["lockfile"]) for lock in images[0]["locks"]] == [
            ("plain", "images/dual/apko.yaml", "images/dual/apko.lock.json"),
            ("dev", "images/dual/dev.apko.yaml", "images/dual/dev.apko.lock.json"),
        ]
        # Selecting one image keeps its full lock set and drops every other image.
        assert [entry["context"] for entry in generated(root, "images/dual")] == ["images/dual"]
        assert "not an enabled pure APKO image context" in refused(root, "images/quarantined")
        assert "not an enabled pure APKO image context" in refused(root, "patched/upstream")
        assert "not an enabled pure APKO image context" in refused(root, "images/absent")


def check_lockable_inputs() -> None:
    with TemporaryDirectory() as temporary:
        root = Path(temporary)
        # A pure APKO flavor without its committed lock has nothing reviewable to refresh.
        write_image(root / "images/unlocked", name="unlocked", flavors="plain, dev", flavor_config="dev")
        write_image(root / "images/valid", name="valid")
        assert [entry["context"] for entry in generated(root, "images/valid")] == ["images/valid"]
        assert "missing dev.apko.lock.json" in refused(root)

    with TemporaryDirectory() as temporary:
        root = Path(temporary)
        # A template needing build-time substitution cannot be locked directly.
        write_image(
            root / "images/templated",
            name="templated",
            config_body='contents:\n  repositories:\n    - "@local @LOCAL_REPOSITORY@"\n',
        )
        assert "needs build-time substitution" in refused(root)

    with TemporaryDirectory() as temporary:
        root = Path(temporary)
        # A wrapper config is the build input, so it is also the lock input.
        write_image(
            root / "images/wrapped",
            name="wrapped",
            flavors="plain, fips",
            flavor_config="fips",
            wrapper="fips",
            locks=("apko.lock.json", "fips.apko.lock.json"),
        )
        locks = generated(root)[0]["locks"]
        assert (locks[1]["config"], locks[1]["lockfile"]) == (
            "images/wrapped/fips-wrapper.apko.yaml",
            "images/wrapped/fips.apko.lock.json",
        )


def check_branch_isolation() -> None:
    with TemporaryDirectory() as temporary:
        root = Path(temporary)
        write_image(root / "images/redis", name="redis")
        write_image(root / "images/go/1.26", name="go", versions="1.26")
        images = generated(root)
        # One image-local branch per image, derived from its context and never the base branch.
        assert [entry["branch"] for entry in images] == ["apko-lock/images-go-1.26", "apko-lock/images-redis"]
        assert all(entry["branch"].startswith("apko-lock/") for entry in images)

    with TemporaryDirectory() as temporary:
        root = Path(temporary)
        # Two contexts must never share one refresh branch.
        write_image(root / "images/go-1.26", name="go", versions="1.26")
        write_image(root / "images/go/1.26", name="go", versions="1.26")
        assert "collide on one refresh branch name" in refused(root)


def check_repository_targets() -> None:
    images = gen_apko_lock_targets.generate()["images"]
    contexts = [entry["context"] for entry in images]
    assert contexts == sorted(contexts)
    assert len({entry["branch"] for entry in images}) == len(images)
    for entry in images:
        assert entry["context"].startswith("images/")
        assert entry["branch"] == f"apko-lock/{entry['context'].replace('/', '-')}"
        for lock in entry["locks"]:
            assert (ROOT / lock["config"]).is_file()
            assert (ROOT / lock["lockfile"]).is_file()
            assert (ROOT / lock["lockfile"]).read_bytes().endswith(b"}\n")
    selected = {entry["context"]: entry for entry in images}
    # httpd publishes a pure APKO FIPS flavor from the signed repository.
    assert [lock["flavor"] for lock in selected["images/httpd"]["locks"]] == ["plain", "fips"]
    # go/1.26 keeps a committed plain lock while its FIPS flavor is recipe-backed.
    assert [lock["flavor"] for lock in selected["images/go/1.26"]["locks"]] == ["plain"]
    # A melange-backed image and a quarantined definition are never refreshed.
    assert "images/caddy" not in selected
    assert "images/go/1.24" not in selected


def main() -> None:
    check_eligibility()
    check_lockable_inputs()
    check_branch_isolation()
    check_repository_targets()
    print("passed scripts/test_gen_apko_lock_targets.py")


if __name__ == "__main__":
    main()
