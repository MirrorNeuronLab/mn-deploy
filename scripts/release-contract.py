#!/usr/bin/env python3
"""Release planning and package-aware blueprint pins; no network or publishing."""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import tomllib
from pathlib import Path


def canonical(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).lower()


def next_release(workspace: Path, repositories: list[str]) -> str:
    versions = set()
    changed = False
    for name in repositories:
        repo = workspace / name
        tags = subprocess.check_output(["git", "-C", str(repo), "tag"], text=True).splitlines()
        tags = [tag for tag in tags if re.fullmatch(r"v\d+\.\d+\.\d+", tag)]
        versions.update(tuple(map(int, tag[1:].split('.'))) for tag in tags)
        if not tags:
            changed = True
            continue
        latest = max(tags, key=lambda tag: tuple(map(int, tag[1:].split('.'))))
        paths = subprocess.check_output(
            ["git", "-C", str(repo), "diff", "--name-only", latest, "HEAD"], text=True
        ).splitlines()
        # Finalization records are the only changes made after tagging.
        if any(not (name == "mn-deploy" and path == "released.md") for path in paths):
            changed = True
    if not changed:
        return ""
    major, minor, patch = max(versions, default=(0, 0, 0))
    return f"{major}.{minor}.{patch + 1}"


def update_blueprints(root: Path, versions: dict[str, str]) -> list[Path]:
    # Match only named exact requirements. Never rewrite arbitrary JSON numbers,
    # blueprint identity versions, external packages, or minimum compatibility ranges.
    pattern = re.compile(r"(?<![\w.-])([A-Za-z0-9][A-Za-z0-9_.-]*)(\[[^\]\n]+\])?(\s*==\s*)(\d+(?:\.\d+)+(?:[-+.][\w.]+)?)(?![\w.*+-])")
    changed = []
    for path in sorted(root.rglob('*')):
        if '.git' in path.parts or not path.is_file() or (path.suffix != '.json' and path.name != 'requirements.txt'):
            continue
        source = path.read_text()
        def replace(match: re.Match) -> str:
            version = versions.get(canonical(match[1]))
            return f"{match[1]}{match[2] or ''}{match[3]}{version}" if version else match[0]
        updated = pattern.sub(replace, source)
        # Manifests also represent dependencies as {package, version} objects.
        if path.suffix == '.json':
            data = json.loads(updated)
            def visit(value):
                if isinstance(value, dict):
                    name = value.get('package')
                    if value.get('type') == 'pip' and value.get('source') == 'gar':
                        name = value.get('name')
                    if isinstance(name, str) and canonical(name) in versions and 'version' in value:
                        value['version'] = versions[canonical(name)]
                    for item in value.values():
                        visit(item)
                elif isinstance(value, list):
                    for item in value:
                        visit(item)
            before = json.dumps(data)
            visit(data)
            if json.dumps(data) != before:
                updated = json.dumps(data, indent=2, ensure_ascii=False) + '\n'
        if updated != source:
            path.write_text(updated)
            changed.append(path)
    return changed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    auto = sub.add_parser('next-version')
    auto.add_argument('workspace', type=Path)
    auto.add_argument('repositories', nargs='+')
    pins = sub.add_parser('blueprints')
    pins.add_argument('index', type=Path)
    pins.add_argument('root', type=Path)
    args = parser.parse_args()
    if args.command == 'next-version':
        print(next_release(args.workspace, args.repositories))
    else:
        packages = tomllib.loads(args.index.read_text())['packages']
        for path in update_blueprints(args.root, {canonical(p['name']): p['version'] for p in packages}):
            print(path)


if __name__ == '__main__':
    main()
