#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   uv run scripts/test_gen_apk_matrix.py

import json
import subprocess
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

import gen_apk_matrix


def write_recipe(root: Path, directory: str) -> None:
    recipe = root / directory / "melange.yaml"
    recipe.parent.mkdir(parents=True)
    recipe.write_text("package:\n  name: fixture\n", encoding="utf-8")


def write_state(path: Path, packages: list[tuple[str, str, str]]) -> None:
    path.write_text(
        json.dumps(
            {
                "packages": [
                    {"architecture": architecture, "name": name, "version": version}
                    for name, version, architecture in packages
                ]
            }
        ),
        encoding="utf-8",
    )


def unpublished_tests() -> None:
    with TemporaryDirectory() as temporary_directory:
        root = Path(temporary_directory)
        for directory, text in {
            "packages/current": 'package:\n  name: current\n  version: "1.2"\n  epoch: 4\n',
            "packages/single-arch": "package:\n  name: single-arch\n  version: 2.0\n",
            "images/restic": (
                "# leading comment\n"
                "package:\n"
                "  name: restic-fixture\n"
                '  version: "0.18.1"\n'
                "  epoch: 10  # Rebuild with a patched dependency\n"
                "  copyright:\n"
                "    - license: BSD-2-Clause\n"
                "pipeline:\n"
                "  - uses: go/build\n"
                "    with:\n"
                "      name: other\n"
                "subpackages:\n"
                "  - name: restic-fixture-doc\n"
                "    version: 9.9\n"
            ),
        }.items():
            recipe = root / directory / "melange.yaml"
            recipe.parent.mkdir(parents=True)
            recipe.write_text(text, encoding="utf-8")
        (root / "packages/restic-fixture").mkdir()
        (root / "packages/restic-fixture/melange.yaml").symlink_to("../../images/restic/melange.yaml")
        state = root / "state.json"
        write_state(
            state,
            [
                ("current", "1.2-r4", "aarch64"),
                ("current", "1.2-r4", "x86_64"),
                ("single-arch", "2.0-r0", "x86_64"),
                ("restic-fixture", "0.18.1-r9", "aarch64"),
                ("restic-fixture", "0.18.1-r9", "x86_64"),
            ],
        )
        with patch.object(gen_apk_matrix, "ROOT", root):
            assert gen_apk_matrix.recipe_identity("packages/restic-fixture/melange.yaml") == (
                "restic-fixture",
                "0.18.1-r10",
            )
            assert gen_apk_matrix.recipe_identity("packages/single-arch/melange.yaml") == ("single-arch", "2.0-r0")
            # The previous-commit diff misses a bump merged earlier; the published state does not.
            assert [(entry["package"], entry["architecture"]) for entry in gen_apk_matrix.unpublished(state)["include"]] == [
                ("restic-fixture", "aarch64"),
                ("restic-fixture", "x86_64"),
                ("single-arch", "aarch64"),
                ("single-arch", "x86_64"),
            ]

            write_state(
                state,
                [
                    (name, version, architecture)
                    for name, version in (("current", "1.2-r4"), ("single-arch", "2.0-r0"), ("restic-fixture", "0.18.1-r10"))
                    for architecture in gen_apk_matrix.ARCHITECTURES
                ],
            )
            assert gen_apk_matrix.unpublished(state) == {"include": []}

            (root / "packages/current/melange.yaml").write_text(
                'package:\n  name: renamed\n  version: "1.2"\n', encoding="utf-8"
            )
            try:
                gen_apk_matrix.unpublished(state)
            except gen_apk_matrix.PackageDiscoveryError as error:
                assert "does not match directory current" in str(error)
            else:
                raise AssertionError("recipe name mismatch was admitted")

            (root / "packages/current/melange.yaml").write_text("package:\n  name: current\n", encoding="utf-8")
            try:
                gen_apk_matrix.unpublished(state)
            except gen_apk_matrix.PackageDiscoveryError as error:
                assert "packages/current/melange.yaml" in str(error)
            else:
                raise AssertionError("recipe without a version was admitted")


def main() -> None:
    with TemporaryDirectory() as temporary_directory:
        root = Path(temporary_directory)
        write_recipe(root, "packages/zeta")
        write_recipe(root, "packages/alpha")
        write_recipe(root, "images/caddy")
        write_recipe(root, "images/traefik")

        write_recipe(root, "packages/Bad Name")
        with patch.object(gen_apk_matrix, "ROOT", root):
            try:
                gen_apk_matrix.package_recipes()
            except gen_apk_matrix.PackageDiscoveryError as error:
                assert "Bad Name" in str(error)
            else:
                raise AssertionError("invalid package directory was admitted")
        (root / "packages/Bad Name/melange.yaml").unlink()
        (root / "packages/Bad Name").rmdir()

        with patch.object(gen_apk_matrix, "ROOT", root):
            all_packages = {
                "include": [
                    {
                        "architecture": "aarch64",
                        "package": "alpha",
                        "recipe": "packages/alpha/melange.yaml",
                    },
                    {
                        "architecture": "x86_64",
                        "package": "alpha",
                        "recipe": "packages/alpha/melange.yaml",
                    },
                    {
                        "architecture": "aarch64",
                        "package": "zeta",
                        "recipe": "packages/zeta/melange.yaml",
                    },
                    {
                        "architecture": "x86_64",
                        "package": "zeta",
                        "recipe": "packages/zeta/melange.yaml",
                    },
                ]
            }
            assert gen_apk_matrix.generate(None, None) == all_packages

        for changed_path in (
            "scripts/build_apk_package.sh",
            "scripts/gen_apk_matrix.py",
        ):
            with (
                patch.object(gen_apk_matrix, "ROOT", root),
                patch.object(gen_apk_matrix, "changed_paths", return_value={changed_path}),
            ):
                assert gen_apk_matrix.generate("base", "head") == all_packages

        with (
            patch.object(gen_apk_matrix, "ROOT", root),
            patch.object(
                gen_apk_matrix,
                "changed_paths",
                return_value={"packages/zeta/source.patch", "images/caddy/melange.yaml"},
            ),
        ):
            assert gen_apk_matrix.generate("base", "head") == {
                "include": [
                    {
                        "architecture": "aarch64",
                        "package": "zeta",
                        "recipe": "packages/zeta/melange.yaml",
                    },
                    {
                        "architecture": "x86_64",
                        "package": "zeta",
                        "recipe": "packages/zeta/melange.yaml",
                    },
                ]
            }

        source = root / "images/caddy/melange.yaml"
        source.write_text("package:\n  name: linked\npipeline:\n  - uses: go/remediate\n", encoding="utf-8")
        linked = root / "packages/linked/melange.yaml"
        linked.parent.mkdir()
        linked.symlink_to("../../images/caddy/melange.yaml")
        with patch.object(gen_apk_matrix, "ROOT", root):
            assert gen_apk_matrix.package_recipes()["linked"] == "packages/linked/melange.yaml"
            for changed in (
                {"images/caddy/melange.yaml"},
                {"packages/linked/melange.yaml"},
                {"pipelines/go/remediate.yaml"},
            ):
                with patch.object(gen_apk_matrix, "changed_paths", return_value=changed):
                    entries = gen_apk_matrix.generate("base", "head")["include"]
                    assert [(entry["package"], entry["architecture"]) for entry in entries] == [
                        ("linked", "aarch64"),
                        ("linked", "x86_64"),
                    ]
            for changed in ({"images/traefik/melange.yaml"}, {"pipelines/unrelated.yaml"}):
                with patch.object(gen_apk_matrix, "changed_paths", return_value=changed):
                    assert gen_apk_matrix.generate("base", "head") == {"include": []}

            with TemporaryDirectory() as outside_directory:
                outside = Path(outside_directory) / "melange.yaml"
                outside.write_text("package:\n  name: outside\n", encoding="utf-8")
                for target in (outside, root / "missing.yaml"):
                    linked.unlink()
                    linked.symlink_to(target)
                    try:
                        gen_apk_matrix.package_recipes()
                    except gen_apk_matrix.PackageDiscoveryError as error:
                        assert "invalid package recipe path" in str(error)
                    else:
                        raise AssertionError("outside or dangling recipe link was admitted")
                directory_link = root / "packages/outside"
                directory_link.symlink_to(outside_directory, target_is_directory=True)
                linked.unlink()
                linked.symlink_to("../../images/caddy/melange.yaml")
                try:
                    gen_apk_matrix.package_recipes()
                except gen_apk_matrix.PackageDiscoveryError as error:
                    assert "packages/outside/melange.yaml" in str(error)
                else:
                    raise AssertionError("outside directory recipe link was admitted")
                directory_link.unlink()
            linked.unlink()
            linked.symlink_to("../../images/caddy/melange.yaml")

        subprocess.run(["git", "init", "-q", str(root)], check=True)
        subprocess.run(["git", "-C", str(root), "config", "user.email", "test@example.com"], check=True)
        subprocess.run(["git", "-C", str(root), "config", "user.name", "Test"], check=True)
        subprocess.run(["git", "-C", str(root), "add", "."], check=True)
        subprocess.run(["git", "-C", str(root), "commit", "-qm", "base"], check=True)
        base = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        changed_path = "packages/alpha/source\n.patch"
        (root / changed_path).write_text("changed\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(root), "add", "."], check=True)
        subprocess.run(["git", "-C", str(root), "commit", "-qm", "head"], check=True)
        head = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        with patch.object(gen_apk_matrix, "ROOT", root):
            assert gen_apk_matrix.changed_paths(base, head) == {changed_path}
            assert [entry["package"] for entry in gen_apk_matrix.generate(base, head)["include"]] == [
                "alpha",
                "alpha",
            ]
    unpublished_tests()


if __name__ == "__main__":
    main()
