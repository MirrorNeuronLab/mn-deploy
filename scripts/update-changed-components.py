#!/usr/bin/env python3
"""Publish changed packages and repair images while keeping Core/installer versions."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import tomllib
from urllib.parse import unquote

SCRIPTS = Path(__file__).resolve().parent
VERSION = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")


def module(filename):
    spec = importlib.util.spec_from_file_location(filename, SCRIPTS / filename)
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


def run(*args, capture=False, env=None):
    result = subprocess.run([str(arg) for arg in args], env=env, check=False,
                            stdout=subprocess.PIPE if capture else None, text=True)
    if result.returncode:
        raise RuntimeError(f"{' '.join(str(arg) for arg in args[:3])} failed (exit {result.returncode}).")
    return result.stdout.strip() if capture else None


def git(repo, *args):
    return run('git', '-C', repo, *args, capture=True)


def default(source, setting):
    match = re.search(r'^' + setting + r'="\$\{' + setting + r':-(v[0-9.]+)\}"$', source, re.M)
    if not match or not VERSION.fullmatch(match[1][1:]):
        raise RuntimeError(f"Cannot read {setting} from install.sh.")
    return match[1]


def pin(source, setting, tag):
    pattern = r'(^' + setting + r'="\$\{' + setting + r':-)[^}]+(\}")'
    updated, count = re.subn(pattern, lambda m: m[1] + tag + m[2], source, flags=re.M)
    if count != 1:
        raise RuntimeError(f"Cannot update {setting} in install.sh.")
    return updated


def component_changed(repo, tag, recorded):
    tree = git(repo, 'rev-parse', 'HEAD^{tree}')
    if recorded:
        return tree != recorded['tree'], tree
    baseline = git(repo, 'rev-parse', '--verify', f'refs/tags/{tag}^{{tree}}')
    return tree != baseline, tree


def plan(workspace, only):
    deploy = workspace / 'mn-deploy'
    source = (deploy / 'install.sh').read_text()
    index = deploy / 'package-index/python-packages.toml'
    index_source = index.read_text()
    previous = tomllib.loads(index_source)['packages']
    inventory = module('prepare-python-package-index.py')
    # Compute the next package set in a disposable index. Source metadata stays
    # untouched until all selected GAR uploads have succeeded.
    with tempfile.TemporaryDirectory(prefix='mn-component-plan-') as directory:
        prepared = Path(directory) / 'index.toml'
        prepared.write_text(index_source)
        if 'python' in only:
            inventory.synchronize(prepared, workspace, 'unused', independent=True,
                                  baseline=default(source, 'MN_DEFAULT_INSTALL_VERSION'),
                                  write_projects=False)
        prepared_source = prepared.read_text()
    packages = tomllib.loads(prepared_source)['packages']
    selected = [new for old, new in zip(previous, packages, strict=True)
                if new['version'] != old['version']]
    manifest_path = deploy / 'package-index/component-sources.json'
    manifest_source = manifest_path.read_text() if manifest_path.exists() else None
    manifest = json.loads(manifest_source) if manifest_source is not None else {}
    components = []
    definitions = [
        ('web-ui', 'mn-web-ui', 'MN_DEFAULT_WEB_UI_VERSION'),
        ('core', 'MirrorNeuron', 'MN_DEFAULT_CORE_VERSION'),
        ('membrane', 'Membrane', 'MN_DEFAULT_MEMBRANE_CONTEXT_ENGINE_VERSION'),
    ]
    for kind, name, setting in definitions:
        if kind not in only:
            continue
        tag = default(source, setting)
        changed, tree = component_changed(workspace / name, tag, manifest.get(f'{kind}:{tag}'))
        if changed:
            target = 'v' + inventory.patch_version(tag[1:]) if kind == 'web-ui' else tag
            components.append(dict(kind=kind, repo=name, version=target, previous=tag, tree=tree))
            manifest[f'{kind}:{target}'] = {'tree': tree}
    repos = sorted(({Path(p['path']).parts[0] for p in packages} if 'python' in only else set()) |
                   {name for kind, name, _ in definitions if kind in only})
    heads = {name: git(workspace / name, 'rev-parse', 'HEAD') for name in repos}
    dirty = [name for name in repos if git(workspace / name, 'status', '--porcelain')]
    metadata = {}
    for package in selected:
        relative = Path(package['path'])
        if relative.is_absolute() or '..' in relative.parts:
            raise RuntimeError(f"Invalid indexed package path: {relative}")
        project_path = workspace / relative / 'pyproject.toml'
        project_source = project_path.read_text()
        project = tomllib.loads(project_source)['project']
        if project.get('version') and project['version'] != package['version']:
            updated, count = re.subn(r'(?m)^version\s*=\s*"[^"\n]+"',
                                    f'version = "{package["version"]}"', project_source, count=1)
            if count != 1:
                raise RuntimeError(f"Cannot pin static Python version: {project_path}")
            metadata[str(relative / 'pyproject.toml')] = updated
    settings = {'mirrorneuron-python-sdk': 'MN_DEFAULT_PYTHON_SDK_VERSION',
                'mirrorneuron-cli': 'MN_DEFAULT_CLI_VERSION', 'mirrorneuron-api': 'MN_DEFAULT_API_VERSION'}
    installer = source
    for package in selected:
        if package['name'] in settings:
            installer = pin(installer, settings[package['name']], 'v' + package['version'])
    compose_source = (deploy / 'docker-compose.yml').read_text()
    compose = compose_source
    for component in components:
        if component['kind'] == 'web-ui':
            installer = pin(installer, 'MN_DEFAULT_WEB_UI_VERSION', component['version'])
            compose, count = re.subn(r'(MN_WEB_UI_PACKAGE_VERSION:\s*\$\{MN_WEB_UI_PACKAGE_VERSION:-)[^}]+(\})',
                                    lambda m: m[1] + component['version'][1:] + m[2], compose)
            if count != 1:
                raise RuntimeError('Cannot pin the Web UI version in docker-compose.yml.')
    support_versions = [default(source, 'MN_DEFAULT_INSTALL_SUPPORT_VERSION')[1:],
                        default(source, 'MN_DEFAULT_AGENT_PACKAGE_INDEX_VERSION')[1:]]
    support_versions += [p.name[1:] for p in (deploy / 'install_support').glob('v*')
                         if VERSION.fullmatch(p.name[1:])]
    support_tag = 'v' + inventory.patch_version(max(support_versions, key=inventory.numeric_version_key))
    if selected or components:
        installer = pin(installer, 'MN_DEFAULT_INSTALL_SUPPORT_VERSION', support_tag)
        installer = pin(installer, 'MN_DEFAULT_AGENT_PACKAGE_INDEX_VERSION', support_tag)
    return dict(packages=selected, components=components, heads=heads, metadata=metadata,
                index=prepared_source, installer=installer, compose=compose,
                original_index=index_source, original_installer=source, original_compose=compose_source,
                manifest=manifest, original_manifest=manifest_source, support=support_tag, dirty=dirty,
                core=default(source, 'MN_DEFAULT_CORE_VERSION'),
                runtime=default(source, 'MN_DEFAULT_INSTALL_VERSION'))


def ensure_sources(workspace, planned):
    for repo, head in planned['heads'].items():
        path = workspace / repo
        if git(path, 'status', '--porcelain'):
            raise RuntimeError(f'Uncommitted changes in {repo}. Commit or stash them, then rerun.')
        if git(path, 'rev-parse', 'HEAD') != head:
            raise RuntimeError(f'{repo} changed during preparation. Rerun the preview.')


def stage_repository(repo, target):
    rows = target.parent / (target.name + '.tar')
    run('git', '-C', repo, 'archive', 'HEAD', '-o', rows)
    import tarfile
    target.mkdir()
    with tarfile.open(rows) as archive:
        archive.extractall(target, filter='data')
    rows.unlink()


def build_python(workspace, planned, directory):
    if not planned['packages']:
        return
    inventory = module('prepare-python-package-index.py')
    index = directory / 'index.toml'
    index.write_text(planned['index'])
    inventory.verify_dependencies(index, workspace)
    ready = directory / 'python-ready.json'
    if ready.exists():
        expected = json.loads(ready.read_text())
        if all((directory / path).is_file() and hashlib.sha256((directory / path).read_bytes()).hexdigest() == digest
               for path, digest in expected.items()):
            return  # Keep identical artifacts across interrupted-upload retries.
        raise RuntimeError(f'Cached build artifacts changed: {directory}. Move this directory aside and retry.')
    artifacts = directory / 'python'
    artifacts.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='mn-component-build-') as staging:
        rows = Path(staging) / 'packages.tsv'
        rows.write_text(''.join(f'{p["name"]}\t{workspace / p["path"]}\t{",".join(p.get("build_formats") or ["sdist", "wheel"])}\t{p["version"]}\n'
                                for p in planned['packages']))
        module('stage-python-release-sources.py').stage_sources(rows, Path(staging) / 'sources')
        for line in rows.read_text().splitlines():
            name, path, formats, version = line.split('\t')
            staged = Path(path)
            relative = next(p['path'] for p in planned['packages'] if p['name'] == name)
            metadata = planned['metadata'].get(str(Path(relative) / 'pyproject.toml'))
            if metadata:
                (staged / 'pyproject.toml').write_text(metadata)
            env = {**os.environ, 'SETUPTOOLS_SCM_PRETEND_VERSION': version,
                   'MEMBRANE_PYTHON_SDK_VERSION': version}
            run(sys.executable, '-m', 'build', staged, '--outdir', artifacts,
                *['--' + fmt for fmt in formats.split(',')], env=env)
    files = sorted(artifacts.iterdir())
    run(sys.executable, '-m', 'twine', 'check', *files)
    module('validate-python-release.py').validate(index, artifacts,
        required_names={p['name'] for p in planned['packages']})
    from packaging.utils import canonicalize_name, parse_sdist_filename, parse_wheel_filename
    from packaging.version import Version
    versions = {canonicalize_name(p['name']): Version(p['version']) for p in planned['packages']}
    for artifact in files:
        name, version, *_ = (parse_wheel_filename(artifact.name) if artifact.suffix == '.whl'
                             else parse_sdist_filename(artifact.name))
        if canonicalize_name(name) not in versions or versions[canonicalize_name(name)] != version:
            raise RuntimeError(f'Unexpected build artifact/version: {artifact.name}')
    ready.write_text(json.dumps({str(p.relative_to(directory)): hashlib.sha256(p.read_bytes()).hexdigest()
                                for p in files}, indent=2) + '\n')


def publish_python(args, planned, directory):
    from packaging.utils import canonicalize_name, parse_sdist_filename, parse_wheel_filename
    scope = [f'--project={args.project}', f'--location={args.location}', f'--repository={args.python_repository}']
    url = f'https://{args.location}-python.pkg.dev/{args.project}/{args.python_repository}/'
    for package in planned['packages']:
        name = canonicalize_name(package['name'])
        artifacts = []
        for path in (directory / 'python').iterdir():
            parsed = parse_wheel_filename(path.name) if path.suffix == '.whl' else parse_sdist_filename(path.name)
            if canonicalize_name(parsed[0]) == name:
                artifacts.append(path)
        def remote_files():
            data = json.loads(run(args.gcloud, 'artifacts', 'files', 'list', *scope,
                                  f'--package={name}', f'--version={package["version"]}', '--format=json', capture=True))
            return {unquote(row['name'].rsplit('/', 1)[-1]).rsplit('/', 1)[-1]: row for row in data}
        remote = remote_files()
        missing = [path for path in artifacts if path.name not in remote]
        if missing:
            run(sys.executable, '-m', 'twine', 'upload', '--non-interactive', '--repository-url', url,
                *missing, env={**os.environ, 'GOOGLE_CLOUD_PROJECT': args.project})
        remote = remote_files()
        import base64
        for path in artifacts:
            item = remote.get(path.name)
            digest = base64.b64encode(hashlib.sha256(path.read_bytes()).digest()).decode()
            if not item or not any(h['type'] == 'SHA256' and h['value'] == digest for h in item.get('hashes', [])):
                raise RuntimeError(f'GAR content verification failed: {name}/{path.name}')
        print(f'✓ Published {name}=={package["version"]}', flush=True)


def publish_component(args, workspace, component, directory):
    kind = component['kind']
    with tempfile.TemporaryDirectory(prefix=f'mn-{kind}-repair-') as staging:
        target = Path(staging) / 'source'
        stage_repository(workspace / component['repo'], target)
        if kind == 'web-ui':
            run('bash', SCRIPTS.parent / 'publish_web_ui_to_google_artifact_registry.sh', '--apply',
                '--version', component['version'], '--web-ui-dir', target,
                '--dist-dir', directory / 'web-ui', '--project', args.project,
                '--location', args.location, '--repository', args.npm_repository)
            return
        image = f'{args.location}-docker.pkg.dev/{args.project}/{args.docker_repository}/' + (
            'mirror-neuron-core' if kind == 'core' else 'membrane-context-engine')
        run(args.gcloud, 'auth', 'configure-docker', f'{args.location}-docker.pkg.dev', '--quiet')
        if args.qemu == 'always' or (args.qemu == 'auto' and os.uname().machine in ('arm64', 'aarch64')
                                     and 'linux/amd64' in args.platforms.split(',')):
            run(args.docker, 'run', '--privileged', '--rm',
                'tonistiigi/binfmt@sha256:400a4873b838d1b89194d982c45e5fb3cda4593fbfd7e08a02e76b03b21166f0',
                '--install', 'amd64')
        metadata = directory / f'{kind}-image.json'
        command = [args.docker, 'buildx', 'build', '--push', '--platform', args.platforms,
                   '--file', str(target / 'Dockerfile'), '--metadata-file', str(metadata),
                   '--label', f'org.opencontainers.image.version={component["version"]}',
                   '--label', f'org.opencontainers.image.revision={git(workspace / component["repo"], "rev-parse", "HEAD")}',
                   '--tag', image + ':' + component['version'],
                   '--tag', image + ':' + component['version'][1:]]
        if kind == 'membrane':
            command += ['--target', 'runtime']
        else:
            command += ['--build-arg', 'CORE_RELEASE_TAG=' + component['version'],
                        '--build-arg', 'CORE_REVISION=' + git(workspace / component['repo'], 'rev-parse', 'HEAD'),
                        '--build-arg', 'ERL_AFLAGS=+JMsingle true']
        if args.update_latest:
            command += ['--tag', image + ':latest']
        command += [str(target)]
        run(*command)
        digest = json.loads(metadata.read_text())['containerimage.digest']
        for tag in [component['version'], component['version'][1:]] + (['latest'] if args.update_latest else []):
            manifest = json.loads(run(args.docker, 'buildx', 'imagetools', 'inspect', image + ':' + tag,
                                      '--format', '{{json .Manifest}}', capture=True))
            if manifest['digest'] != digest:
                raise RuntimeError(f'GAR image verification failed: {image}:{tag}')


def finish(workspace, planned):
    deploy = workspace / 'mn-deploy'
    # Detect concurrent edits before installing any of the prepared metadata.
    for filename, key in [('install.sh', 'original_installer'), ('docker-compose.yml', 'original_compose'),
                          ('package-index/python-packages.toml', 'original_index')]:
        if (deploy / filename).read_text() != planned[key]:
            raise RuntimeError(f'{filename} changed during publishing. Keep the artifacts and rerun the preview.')
    manifest = deploy / 'package-index/component-sources.json'
    if (manifest.read_text() if manifest.exists() else None) != planned['original_manifest']:
        raise RuntimeError('Component source records changed during publishing. Rerun the preview.')
    support = deploy / 'install_support' / planned['support']
    if support.exists():
        raise RuntimeError(f'Immutable support snapshot already exists: {support}')
    (support / 'package-index').mkdir(parents=True)
    (support / 'package-index/python-packages.toml').write_text(planned['index'])
    (support / 'docker-compose.yml').write_text(planned['compose'])
    for path, content in planned['metadata'].items():
        (workspace / path).write_text(content)
    (deploy / 'package-index/python-packages.toml').write_text(planned['index'])
    (deploy / 'package-index/component-sources.json').write_text(json.dumps(planned['manifest'], indent=2) + '\n')
    (deploy / 'docker-compose.yml').write_text(planned['compose'])
    (deploy / 'install.sh').write_text(planned['installer'])


def main():
    parser = argparse.ArgumentParser(description=__doc__, epilog=(
        'Default is a local preview; no builds, Git fetches, version edits or uploads. '
        'Requires Python 3.11+ with packaging (plus build/twine for --apply), clean committed '
        'component repositories, gcloud, npm/Node for Web UI, and Docker Buildx for images. '
        'Apply leaves generated version metadata uncommitted for review.'))
    parser.add_argument('--apply', action='store_true', help='Build, publish, verify, then update component pins/support.')
    parser.add_argument('--plan', '--dry-run', action='store_true', help='Preview only (the default).')
    parser.add_argument('--only', nargs='+', choices=['python', 'web-ui', 'core', 'membrane'],
                        default=['python', 'web-ui', 'core', 'membrane'], help='Limit changed component types.')
    parser.add_argument('--workspace-root', type=Path, default=SCRIPTS.parent.parent)
    parser.add_argument('--project', default=os.environ.get('MN_GAR_PROJECT', 'mirrorneuron-public-packages'))
    parser.add_argument('--location', default=os.environ.get('MN_GAR_LOCATION', 'us-central1'))
    parser.add_argument('--python-repository', default=os.environ.get('MN_GAR_REPOSITORY', 'agent-skills'))
    parser.add_argument('--npm-repository', default=os.environ.get('MN_GAR_NPM_REPOSITORY', 'mirrorneuron-npm'))
    parser.add_argument('--docker-repository', default='mirrorneuron-runtime')
    parser.add_argument('--platforms', default='linux/amd64,linux/arm64')
    parser.add_argument('--qemu', choices=['auto', 'always', 'never'], default='auto')
    parser.add_argument('--update-latest', action='store_true', help='Also move Docker latest tags to repaired images.')
    parser.add_argument('--gcloud', default=os.environ.get('MN_GCLOUD_BIN', 'gcloud'))
    parser.add_argument('--docker', default=os.environ.get('MN_DOCKER_BIN', 'docker'))
    args = parser.parse_args()
    if args.apply and args.plan:
        parser.error('--apply and --plan/--dry-run are mutually exclusive')
    workspace = args.workspace_root.resolve()
    planned = plan(workspace, set(args.only))
    print(f'Core stays {planned["core"]}; installer stays {planned["runtime"]}.', flush=True)
    old = {p['name']: p['version'] for p in tomllib.loads(planned['original_index'])['packages']}
    for package in planned['packages']:
        print(f'==> Python {package["name"]}: {old[package["name"]]} -> {package["version"]}', flush=True)
    for component in planned['components']:
        action = f'{component["previous"]} -> {component["version"]}' if component['kind'] == 'web-ui' else f'repair {component["version"]} from HEAD'
        print(f'==> {component["kind"]}: {action}', flush=True)
    for repo in planned['dirty']:
        print(f'warning: {repo} has uncommitted work; preview uses committed source. Commit or stash before --apply.', flush=True)
    if args.apply:
        ensure_sources(workspace, planned)
    if not planned['packages'] and not planned['components']:
        print('✓ No changed components to publish.')
        return
    print(f'==> New support/package index: {planned["support"]}', flush=True)
    if not args.apply:
        print('Next: rerun with --apply to publish this component set.')
        return
    # Repository configuration/IAM and published package versions remain intact.
    required = ['PYTHON'] if planned['packages'] else []
    if any(c['kind'] == 'web-ui' for c in planned['components']):
        required.append('NPM')
    if any(c['kind'] != 'web-ui' for c in planned['components']):
        required.append('DOCKER')
        run(args.docker, 'info', capture=True)
        run(args.docker, 'buildx', 'version', capture=True)
    for kind in required:
        repo = {'PYTHON': args.python_repository, 'NPM': args.npm_repository, 'DOCKER': args.docker_repository}[kind]
        data = json.loads(run(args.gcloud, 'artifacts', 'repositories', 'describe', repo,
                              f'--project={args.project}', f'--location={args.location}', '--format=json', capture=True))
        if data['format'] != kind or data.get('mode', 'STANDARD_REPOSITORY') != 'STANDARD_REPOSITORY':
            raise RuntimeError(f'{repo} must be a standard {kind} repository.')
        if kind == 'DOCKER' and data.get('dockerConfig', {}).get('immutableTags'):
            raise RuntimeError('Docker repository has immutable tags; same-tag repair is unavailable.')
    run(args.gcloud, 'auth', 'print-access-token', capture=True)
    identity = hashlib.sha256(json.dumps([planned, args.project, args.location, args.python_repository,
                                         args.npm_repository, args.docker_repository, args.platforms,
                                         args.update_latest], sort_keys=True).encode()).hexdigest()[:20]
    directory = workspace / 'mn-deploy/dist/component-updates' / identity
    directory.mkdir(parents=True, exist_ok=True)
    build_python(workspace, planned, directory)
    ensure_sources(workspace, planned)
    publish_python(args, planned, directory)
    for component in planned['components']:
        marker = directory / (component['kind'] + '-published.json')
        if not marker.exists():
            publish_component(args, workspace, component, directory)
            marker.write_text(json.dumps(component) + '\n')
    ensure_sources(workspace, planned)
    finish(workspace, planned)
    print(f'✓ Published component updates; Core {planned["core"]} and installer {planned["runtime"]} unchanged.')
    print('Next: review, commit and push the generated metadata/support snapshot to distribute the updated installer. '
          'Existing runtimes need reinstall/restart to use the fixes.')


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, ValueError, KeyError) as exc:
        print(f'error: {exc}', file=sys.stderr)
        print('Next: resolve the failure and rerun the same command; completed builds/uploads are reused.', file=sys.stderr)
        sys.exit(1)
