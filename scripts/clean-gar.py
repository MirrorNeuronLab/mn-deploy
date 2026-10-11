#!/usr/bin/env python3
"""Inventory and explicitly confirm GAR version deletion. Uses only the stdlib."""
from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
import os
import re
import subprocess
import sys
from urllib.parse import unquote


@dataclass(frozen=True)
class Deletion:
    name: str
    tags: tuple[str, ...]


class GcloudDeleteError(RuntimeError):
    def __init__(self, message: str, parent: str | None = None):
        super().__init__(message)
        self.parent = parent


def version_key(value: str):
    """Compare numeric releases and common SemVer/PEP 440 prereleases, not text."""
    match = re.fullmatch(
        r'v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)'
        r'(?:(?:-?)(alpha|beta|rc|a|b|dev)\.?([0-9]+))?'
        r'(?:\+[0-9A-Za-z.-]+)?', value,
    )
    if not match:
        return None
    major, minor, patch, pre, number = match.groups()
    stage = {'dev': 0, 'a': 1, 'alpha': 1, 'b': 2, 'beta': 2, 'rc': 3, None: 4}[pre]
    return int(major), int(minor), int(patch), stage, int(number or 0)


def run_gcloud(binary: str, *args: str, listing: bool = True):
    command = [binary, 'artifacts', *args]
    if listing:
        command.append('--format=json')
    result = subprocess.run(command, text=True, capture_output=True)
    if result.returncode:
        # Avoid forwarding arbitrary credential-bearing CLI diagnostics.
        raise RuntimeError(f"gcloud {' '.join(args[:2])} failed (exit {result.returncode}); check authentication, permissions, and repository state, then retry.")
    if not listing:
        return None
    data = json.loads(result.stdout)
    if not isinstance(data, list) or any(not isinstance(item, dict) for item in data):
        raise ValueError('Expected a JSON resource list from gcloud')
    return data


def delete_version(binary: str, item: Deletion, project: str) -> None:
    """Delete one version, reporting a validated same-package OCI parent if blocked."""
    command = [binary, 'artifacts', 'versions', 'delete', item.name,
               f'--project={project}', '--delete-tags', '--quiet']
    result = subprocess.run(command, text=True, capture_output=True)
    if result.returncode == 0:
        return

    # GAR rejects deleting a child manifest while an OCI index still references
    # it. Only recognize a digest and package reported by GAR; never execute or
    # trust an arbitrary resource path from CLI output.
    output = result.stderr + '\n' + result.stdout
    if (re.search(r'"code"\s*:\s*5', output)
            and item.name in output
            and re.search(r'\bwas not found\b', output)):
        # Removing an OCI index may also remove a selected child version. Treat
        # GAR's exact-resource 404 as complete when that child is later reached.
        return
    match = re.search(
        r'manifest has referenced parents:\s*([^\s/]+(?:/[^\s/]+)*)/manifests/(sha256:[0-9a-f]{64})',
        output,
    )
    parent = None
    if match:
        package_path, digest = match.groups()
        package_prefix, marker, _ = item.name.partition('/versions/')
        package_id = unquote(package_prefix.rsplit('/packages/', 1)[-1]) if marker else ''
        if package_path == package_id:
            parent = f'{package_prefix}/versions/{digest}'
    raise GcloudDeleteError(
        f"gcloud artifacts versions delete failed (exit {result.returncode}); "
        "check authentication, permissions, and repository state, then retry.",
        parent=parent,
    )


def resource_name(row: dict, prefix: str) -> str:
    name = row.get('name')
    if not isinstance(name, str) or not name.startswith(prefix) or not name[len(prefix):] or any(ord(c) < 32 for c in name):
        raise ValueError(f'Unexpected GAR resource outside {prefix}')
    return name


def package_resource(row: dict, repository: str) -> tuple[str, str]:
    """gcloud ListPackages strips the resource prefix and unescapes /, +, ^.

    Version/tag commands retain full resource names. Reconstruct only a short
    package ID under the repository we explicitly listed; never rebase a full
    resource from another project or repository.
    """
    prefix = repository + '/packages/'
    value = row.get('name')
    if not isinstance(value, str) or not value or any(ord(c) < 32 for c in value):
        raise ValueError(f'Invalid GAR package name under {repository}')
    if value.startswith('projects/'):
        full_name = resource_name(row, prefix)
        encoded = full_name[len(prefix):]
    else:
        encoded = value.replace('/', '%2F').replace('+', '%2B').replace('^', '%5E')
        full_name = prefix + encoded
    package_id = encoded.replace('%2F', '/').replace('%2B', '+').replace('%5E', '^')
    return full_name, package_id


def inventory(binary: str, project: str, cutoff, delete_all: bool):
    plan = []
    skipped = []
    repositories = run_gcloud(binary, 'repositories', 'list', f'--project={project}', '--location=all')
    for repo in repositories:
        name = resource_name(repo, f'projects/{project}/locations/')
        match = re.fullmatch(r'projects/[^/]+/locations/([^/]+)/repositories/([^/]+)', name)
        if not match:
            raise ValueError(f'Invalid repository resource: {name}')
        if repo.get('mode') == 'VIRTUAL_REPOSITORY':
            skipped.append(f'{name}: virtual repository has no stored artifacts')
            continue
        location, repository = match.groups()
        scope = [f'--project={project}', f'--location={location}', f'--repository={repository}']
        packages = run_gcloud(binary, 'packages', 'list', *scope)
        for package in packages:
            package_name, package_id = package_resource(package, name)
            package_scope = [*scope, f'--package={package_id}']
            versions = run_gcloud(binary, 'versions', 'list', *package_scope)
            # Tags are needed both for Docker version identity and for the exact
            # deletion preview, including aliases removed by --delete-tags.
            tags = run_gcloud(binary, 'tags', 'list', *package_scope)
            by_version: dict[str, list[str]] = {}
            for tag in tags:
                tag_name = resource_name(tag, package_name + '/tags/')
                target = tag.get('version')
                if not isinstance(target, str) or not target.startswith(package_name + '/versions/'):
                    raise ValueError(f'Invalid tag target: {tag_name}')
                by_version.setdefault(target, []).append(unquote(tag_name.rsplit('/', 1)[1]))
            for version in versions:
                full_name = resource_name(version, package_name + '/versions/')
                version_id = unquote(full_name[len(package_name + '/versions/'):])
                aliases = tuple(sorted(by_version.get(full_name, [])))
                if delete_all:
                    selected = True
                else:
                    candidates = [version_key(tag) for tag in aliases] if repo.get('format') == 'DOCKER' else [version_key(version_id)]
                    comparable = [key for key in candidates if key is not None]
                    selected = bool(comparable) and all(key < cutoff for key in comparable)
                    if not comparable:
                        skipped.append(f'{full_name}: no comparable release version')
                if selected:
                    plan.append(Deletion(full_name, aliases))
    if len({item.name for item in plan}) != len(plan):
        raise ValueError('Duplicate version resources in GAR inventory')
    return sorted(plan, key=lambda item: item.name), sorted(skipped)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        prog='CLEARN_GAR.sh', description='Delete GAR package versions across all repository locations in one project.',
        epilog='Requires gcloud and Python 3.10+. Always lists deletions and requires exact YES. Repositories and IAM remain intact. Cutoff mode skips unversioned artifacts; -a includes them. Independent packages below the cutoff are deleted even if a release still depends on them. OCI parent manifests are deleted before selected child manifests that they reference.',
    )
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('-v', '--version', help='Delete versions strictly older than MAJOR.MINOR.PATCH (optional v prefix).')
    mode.add_argument('-a', '--all', action='store_true', help='Delete every stored package version, including untagged images.')
    parser.add_argument('--project', default=os.environ.get('MN_GAR_PROJECT', 'mirrorneuron-public-packages'))
    parser.add_argument('--dry-run', action='store_true', help='List the deletion plan without prompting or deleting.')
    args = parser.parse_args(argv)
    if not re.fullmatch(r'[a-z][a-z0-9-]*[a-z0-9]|[0-9]+', args.project):
        parser.error('Invalid Google Cloud project ID or number')
    if args.version is not None and not re.fullmatch(r'v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)', args.version):
        parser.error('-v requires MAJOR.MINOR.PATCH, for example 1.3.48')
    cutoff = version_key(args.version) if args.version else None
    binary = os.environ.get('MN_GCLOUD_BIN', 'gcloud')
    print(f'==> Inspecting GAR project {args.project}, all locations', flush=True)
    plan, skipped = inventory(binary, args.project, cutoff, args.all)
    for note in skipped:
        print(f'Skip: {note}')
    for item in plan:
        print(f'Delete: {item.name}' + (f' (tags: {", ".join(item.tags)})' if item.tags else ''))
    print(f'==> {len(plan)} version(s) selected for deletion')
    if not plan or args.dry_run:
        return 0
    print('warning: This permanently deletes the listed artifacts and their tags. Existing releases or installations may depend on them.')
    try:
        answer = input('Type YES to delete: ')
    except EOFError:
        answer = ''
    if answer != 'YES':
        print('Cancelled. Nothing deleted.')
        return 0
    # A release may have moved a Docker tag while the operator reviewed the plan.
    # Require a fresh confirmation if that changes the selected resources/tags.
    current, _ = inventory(binary, args.project, cutoff, args.all)
    if current != plan:
        raise RuntimeError('Registry deletion plan changed during confirmation. Nothing deleted. Run again to review the new plan.')
    completed = 0
    deleted: set[str] = set()
    by_name = {item.name: item for item in plan}
    pending = list(plan)
    while pending:
        item = pending.pop(0)
        print(f'==> Deleting {item.name}', flush=True)
        try:
            delete_version(binary, item, args.project)
        except GcloudDeleteError as exc:
            if exc.parent and exc.parent != item.name and exc.parent in by_name and exc.parent not in deleted:
                # The complete plan was explicitly confirmed and revalidated.
                # Move the referenced parent ahead of this child, then retry.
                parent_item = by_name[exc.parent]
                pending = [queued for queued in pending if queued.name != exc.parent]
                pending.insert(0, item)
                pending.insert(0, parent_item)
                print(f'    GAR requires parent manifest first: {parent_item.name}', flush=True)
                continue
            detail = f' Parent manifest {exc.parent} is outside the confirmed deletion plan.' if exc.parent else ''
            raise RuntimeError(f'{exc}{detail} Stopped at {item.name}; {completed}/{len(plan)} deletions completed. Run again to inspect what remains.') from exc
        completed += 1
        deleted.add(item.name)
    print(f'✓ Deleted {completed} version(s). Repositories retained.')
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError) as exc:
        print(f'error: {exc}', file=sys.stderr)
        raise SystemExit(1)
    except KeyboardInterrupt:
        print('\nCancelled.', file=sys.stderr)
        raise SystemExit(130)
