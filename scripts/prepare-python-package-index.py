#!/usr/bin/env python3
"""Synchronize release-index versions with each indexed Python project."""

from __future__ import annotations

import argparse
import re
import hashlib
import subprocess
import sys
import tomllib
from pathlib import Path


PACKAGE_BLOCK = re.compile(r"(?ms)^\[\[packages\]\]\n.*?(?=^\[\[packages\]\]\n|\Z)")
VERSION_LINE = re.compile(r'(?m)^version = "[^"]+"$')


def project_release_version(
    pyproject: Path, release_version: str
) -> str:
    data = tomllib.loads(pyproject.read_text(encoding="utf-8"))
    project = data.get("project") or {}
    static_version = project.get("version")
    if isinstance(static_version, str) and static_version:
        return static_version
    if "version" in (project.get("dynamic") or []):
        return release_version
    raise SystemExit(
        f"Python project does not declare a static or dynamic version: {pyproject}"
    )


def numeric_version_key(version: str) -> tuple[int, ...]:
    match = re.fullmatch(r"v?(\d+(?:\.\d+)*)", version)
    return tuple(int(part) for part in match.group(1).split(".")) if match else ()


def git(repo: Path, *args: str) -> str:
    return subprocess.check_output(["git", "-C", str(repo), *args], text=True).strip()


def source_fingerprint(workspace: Path, relative: str, ref: str = "HEAD", *, include_nested: bool = False, legacy: bool = False) -> str:
    """Hash tracked package inputs, excluding nested independently built projects.

    Normalize the static version so preparation itself never causes another bump.
    Include repository-level build configuration for nested packages.
    """
    parts = Path(relative).parts
    repo = workspace / parts[0]
    scope = Path(*parts[1:]).as_posix() if len(parts) > 1 else "."
    rows = git(repo, "ls-tree", "-r", ref, "--", scope).splitlines()
    if scope != ".":
        rows += git(repo, "ls-tree", ref).splitlines()
    digest = hashlib.sha256()
    # Raw tree rows contain blob IDs; sorting those before normalization makes
    # a version-only edit reorder otherwise identical inputs.
    ordered = sorted(set(rows), key=None if legacy else lambda row: row.split("\t", 1)[1])
    for row in ordered:
        metadata, name = row.split("\t", 1)
        mode, kind, oid = metadata.split()
        if kind != "blob" or (scope == "." and not include_nested and name.startswith("packages/")):
            continue
        if name.endswith("pyproject.toml"):
            content = git(repo, "show", f"{ref}:{name}")
            content = re.sub(r'(?m)^version\s*=\s*"[^"\n]+"', 'version = "<release>"', content)
            oid = hashlib.sha256(content.encode()).hexdigest()
        digest.update(f"{mode} {name} {oid}\n".encode())
    return ("" if legacy else "v2:") + digest.hexdigest()


def source_matches(workspace: Path, relative: str, expected: str, *, include_nested: bool = False) -> bool:
    actual = source_fingerprint(workspace, relative, include_nested=include_nested)
    if expected.startswith("v2:"):
        return expected == actual
    if source_fingerprint(workspace, relative, include_nested=include_nested, legacy=True) == expected:
        return True
    # Recover only the original ordering defect across the immediately preceding
    # commit. Its recorded legacy hash must match AND normalized inputs must be
    # identical. This does not rewrite a release snapshot or accept code drift.
    repo = workspace / Path(relative).parts[0]
    parent = subprocess.run(
        ["git", "-C", str(repo), "rev-parse", "--verify", "HEAD^"],
        capture_output=True, text=True,
    )
    if parent.returncode:
        return False
    ref = parent.stdout.strip()
    return (
        source_fingerprint(workspace, relative, ref, include_nested=include_nested, legacy=True) == expected
        and source_fingerprint(workspace, relative, ref, include_nested=include_nested) == actual
    )


def patch_version(version: str) -> str:
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
        raise SystemExit(f"Automatic versioning requires MAJOR.MINOR.PATCH: {version}")
    major, minor, patch = map(int, version.split("."))
    return f"{major}.{minor}.{patch + 1}"


def synchronize(index_file: Path, workspace_root: Path, release_version: str, *, independent: bool = False, baseline: str = "", dry_run: bool = False) -> str:
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

    sdk_entries = [p for p in packages if Path(p["path"]).parts[0] == "mn-python-sdk"]
    sdk_version = None
    sdk_hash = None
    if independent and sdk_entries:
        sdk_hash = source_fingerprint(workspace_root, "mn-python-sdk", include_nested=True)
        previous_hashes = [p.get("source_hash") for p in sdk_entries]
        if not all(previous_hashes) and baseline:
            previous_hashes = [source_fingerprint(workspace_root, "mn-python-sdk", baseline, include_nested=True)]
        previous = max((str(p["version"]) for p in sdk_entries), key=numeric_version_key)
        sdk_changed = any(not h or not source_matches(workspace_root, "mn-python-sdk", h, include_nested=True) for h in previous_hashes)
        sdk_version = patch_version(previous) if sdk_changed else previous

    updates: dict[Path, str] = {}
    rendered: list[str] = []
    position = 0
    for package, block_match in zip(packages, blocks, strict=True):
        rendered.append(source[position : block_match.start()])
        block = block_match.group(0)
        pyproject = workspace_root / str(package["path"]) / "pyproject.toml"
        if not pyproject.is_file():
            raise SystemExit(f"Indexed package is missing pyproject.toml: {pyproject}")
        version = project_release_version(pyproject, release_version)
        if independent:
            fingerprint = source_fingerprint(workspace_root, str(package["path"]))
            previous_hash = package.get("source_hash")
            if not previous_hash and baseline:
                try:
                    previous_hash = source_fingerprint(workspace_root, str(package["path"]), baseline)
                except subprocess.CalledProcessError:
                    pass  # Newly indexed repositories have no baseline tag.
            previous = str(package["version"])
            changed = not previous_hash or not source_matches(workspace_root, str(package["path"]), previous_hash)
            project = tomllib.loads(pyproject.read_text())["project"]
            if project.get("version"):
                declared = str(project["version"])
                if numeric_version_key(declared) < numeric_version_key(previous):
                    raise SystemExit(f"Static version regressed for {package['name']}: {declared} < {previous}")
                version = patch_version(previous) if changed and declared == previous else declared
            else:
                version = patch_version(previous) if changed else previous
            if Path(package["path"]).parts[0] == "mn-python-sdk":
                # Runtime catalog defaults derive component pins from SDK identity.
                version, fingerprint = sdk_version, sdk_hash
            if 'source_hash = ' in block:
                block = re.sub(r'(?m)^source_hash = "[^"]*"$', f'source_hash = "{fingerprint}"', block)
            else:
                block = block.rstrip() + f'\nsource_hash = "{fingerprint}"\n\n'
            if project.get("version") and version != project["version"]:
                updates[pyproject] = re.sub(
                    r'(?m)^version\s*=\s*"[^"\n]+"',
                    f'version = "{version}"', pyproject.read_text(), count=1,
                )
        if dry_run:
            state = f"{package['version']} -> {version}" if version != package['version'] else f"{version} (unchanged)"
            print(f"{package['name']}: {state}", file=sys.stderr)
        updated, count = VERSION_LINE.subn(f'version = "{version}"', block)
        if count != 1:
            raise SystemExit(
                f"Package index entry must contain exactly one version: {package['name']}"
            )
        rendered.append(updated)
        position = block_match.end()
    rendered.append(source[position:])
    if not dry_run:
        for path, content in updates.items():
            path.write_text(content, encoding="utf-8")
        index_file.write_text("".join(rendered), encoding="utf-8")

    comparable = [
        version for version in previous_versions if numeric_version_key(version)
    ]
    if not comparable:
        raise SystemExit(
            f"Could not determine the previous release version from {index_file}"
        )
    return max(comparable, key=numeric_version_key).lstrip("vV")


def verify_sources(index_file: Path, workspace_root: Path) -> None:
    for package in tomllib.loads(index_file.read_text())["packages"]:
        expected = package.get("source_hash")
        if not expected:
            continue  # Historical release indexes predate source fingerprints.
        sdk = Path(package["path"]).parts[0] == "mn-python-sdk"
        scope = "mn-python-sdk" if sdk else package["path"]
        repo = workspace_root / Path(scope).parts[0]
        if git(repo, "status", "--porcelain"):
            raise SystemExit(f"Uncommitted source changes in {repo}; publishing requires the prepared source.")
        if not source_matches(workspace_root, scope, expected, include_nested=sdk):
            raise SystemExit(f"Source changed after version preparation: {package['name']}; prepare a new release.")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("index_file", type=Path)
    parser.add_argument("workspace_root", type=Path)
    parser.add_argument("release_version")
    parser.add_argument("--independent", action="store_true")
    parser.add_argument("--baseline", default="")
    parser.add_argument("--verify-source", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    if args.verify_source:
        verify_sources(args.index_file, args.workspace_root)
        return
    print(
        synchronize(
            args.index_file.resolve(),
            args.workspace_root.resolve(),
            args.release_version,
            independent=args.independent,
            baseline=args.baseline,
            dry_run=args.dry_run,
        )
    )


if __name__ == "__main__":
    main()
