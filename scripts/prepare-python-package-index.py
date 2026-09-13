#!/usr/bin/env python3
"""Synchronize release-index versions with each indexed Python project."""

from __future__ import annotations

import argparse
import re
import tomllib
from pathlib import Path


PACKAGE_BLOCK = re.compile(r"(?ms)^\[\[packages\]\]\n.*?(?=^\[\[packages\]\]\n|\Z)")
VERSION_LINE = re.compile(r'(?m)^version = "[^"]+"$')


def project_release_version(
    pyproject: Path, release_version: str, *, require_dynamic: bool = False
) -> str:
    data = tomllib.loads(pyproject.read_text(encoding="utf-8"))
    project = data.get("project") or {}
    static_version = project.get("version")
    if isinstance(static_version, str) and static_version:
        if require_dynamic:
            raise SystemExit(
                f"SDK component must use the shared release version via "
                f"project.dynamic: {pyproject}"
            )
        return static_version
    if "version" in (project.get("dynamic") or []):
        return release_version
    raise SystemExit(
        f"Python project does not declare a static or dynamic version: {pyproject}"
    )


def numeric_version_key(version: str) -> tuple[int, ...]:
    match = re.fullmatch(r"v?(\d+(?:\.\d+)*)", version)
    return tuple(int(part) for part in match.group(1).split(".")) if match else ()


def synchronize(index_file: Path, workspace_root: Path, release_version: str) -> str:
    source = index_file.read_text(encoding="utf-8")
    data = tomllib.loads(source)
    packages = data.get("packages") or []
    if not packages:
        raise SystemExit(f"No packages found in {index_file}")

    indexed_paths = {str(package["path"]) for package in packages}
    sdk_packages_root = workspace_root / "mn-python-sdk" / "packages"
    missing = sorted(
        str(pyproject.parent.relative_to(workspace_root))
        for pyproject in sdk_packages_root.glob("*/pyproject.toml")
        if str(pyproject.parent.relative_to(workspace_root)) not in indexed_paths
    )
    if missing:
        raise SystemExit(
            "SDK component projects are missing from the Python package index: "
            + ", ".join(missing)
        )

    previous_versions = [str(package.get("version") or "") for package in packages]
    blocks = list(PACKAGE_BLOCK.finditer(source))
    if len(blocks) != len(packages):
        raise SystemExit(f"Could not match every package block in {index_file}")

    rendered: list[str] = []
    position = 0
    for package, block_match in zip(packages, blocks, strict=True):
        rendered.append(source[position : block_match.start()])
        block = block_match.group(0)
        pyproject = workspace_root / str(package["path"]) / "pyproject.toml"
        if not pyproject.is_file():
            raise SystemExit(f"Indexed package is missing pyproject.toml: {pyproject}")
        version = project_release_version(
            pyproject,
            release_version,
            require_dynamic=sdk_packages_root in pyproject.parents,
        )
        updated, count = VERSION_LINE.subn(f'version = "{version}"', block)
        if count != 1:
            raise SystemExit(
                f"Package index entry must contain exactly one version: {package['name']}"
            )
        rendered.append(updated)
        position = block_match.end()
    rendered.append(source[position:])
    index_file.write_text("".join(rendered), encoding="utf-8")

    comparable = [
        version for version in previous_versions if numeric_version_key(version)
    ]
    if not comparable:
        raise SystemExit(
            f"Could not determine the previous release version from {index_file}"
        )
    return max(comparable, key=numeric_version_key).lstrip("vV")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("index_file", type=Path)
    parser.add_argument("workspace_root", type=Path)
    parser.add_argument("release_version")
    args = parser.parse_args()
    print(
        synchronize(
            args.index_file.resolve(),
            args.workspace_root.resolve(),
            args.release_version,
        )
    )


if __name__ == "__main__":
    main()
