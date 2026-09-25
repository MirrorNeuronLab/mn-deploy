"""Offline release-policy regressions using isolated Git repositories and wheels."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import zipfile

import pytest


def module(filename):
    spec = importlib.util.spec_from_file_location(filename, Path(__file__).with_name(filename))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


indexer = module('prepare-python-package-index.py')
contract = module('release-contract.py')
validator = module('validate-python-release.py')


def test_release_preparation_reads_package_index_with_bash_32(tmp_path):
    release = Path(__file__).resolve().parents[1] / 'release_all.sh'
    source, separator, _ = release.read_text().partition('\nwhile [[ "$#" -gt 0 ]]')
    assert separator
    functions = tmp_path / 'release-functions.sh'
    functions.write_text(source)

    index = tmp_path / 'package-index' / 'python-packages.toml'
    index.parent.mkdir()
    index.write_text('''\
[[packages]]
name = "mirrorneuron-python-sdk"
path = "mn-python-sdk"
version = "1.3.51"

[[packages]]
name = "mirrorneuron-cli"
path = "mn-cli"
version = "1.3.52"

[[packages]]
name = "mirrorneuron-api"
path = "mn-api"
version = "1.3.51"

[[packages]]
name = "example"
path = "mn-api/component with spaces"
version = "1.0.0"
''')
    shell = '''\
source "$FUNCTIONS_FILE"
VERSION=1.3.55
TAG=v1.3.55
MN_RELEASE_BASELINE=v1.3.54
REPOSITORIES=(mn-api no-packages)
python3() {
  if [[ "$1" == */scripts/prepare-python-package-index.py ]]; then
    return 0
  fi
  "$TEST_PYTHON" "$@"
}
set_compose_web_ui_version() { :; }
prepare_install_support_snapshot() { :; }
set_installer_default_version() { printf 'PIN:%s=%s\\n' "$1" "$2"; }
commit_and_push_if_changed() {
  printf 'COMMIT:%s' "$1"
  shift 2
  printf ' <%s>' "$@"
  printf '\\n'
}
prepare_release_metadata
'''
    result = subprocess.run(
        ['bash', '-c', shell],
        capture_output=True,
        text=True,
        env={**os.environ, 'FUNCTIONS_FILE': str(functions), 'TEST_PYTHON': sys.executable},
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout.splitlines() == [
        'PIN:MN_DEFAULT_CORE_VERSION=v1.3.55',
        'PIN:MN_DEFAULT_WEB_UI_VERSION=v1.3.55',
        'PIN:MN_DEFAULT_AGENT_PACKAGE_INDEX_VERSION=v1.3.55',
        'PIN:MN_DEFAULT_MEMBRANE_CONTEXT_ENGINE_VERSION=v1.3.55',
        'PIN:MN_DEFAULT_INSTALL_VERSION=v1.3.55',
        'PIN:MN_DEFAULT_PYTHON_SDK_VERSION=v1.3.51',
        'PIN:MN_DEFAULT_CLI_VERSION=v1.3.52',
        'PIN:MN_DEFAULT_API_VERSION=v1.3.51',
        'COMMIT:mn-deploy <install.sh> <package-index/python-packages.toml> '
        '<docker-compose.yml> <install_support/v1.3.55>',
        'COMMIT:mn-api <pyproject.toml> <component with spaces/pyproject.toml>',
    ]


def git(repo, *args):
    return subprocess.check_output(['git', '-C', str(repo), *args], text=True).strip()


def repository(root, name='repo'):
    repo = root / name
    repo.mkdir()
    git(repo, 'init', '-q')
    git(repo, 'config', 'user.email', 'test@example.invalid')
    git(repo, 'config', 'user.name', 'Test')
    return repo


def commit(repo):
    git(repo, 'add', '.')
    git(repo, 'commit', '-qm', 'fixture')


def test_independent_versions_and_retry(tmp_path):
    repo = repository(tmp_path)
    for name in ('one', 'two'):
        project = repo / name
        project.mkdir()
        (project / 'pyproject.toml').write_text(f'[project]\nname = "{name}"\ndynamic = ["version"]\n')
        (project / 'code.py').write_text('value = 1\n')
    commit(repo)
    git(repo, 'tag', 'v1.2.3')
    index = tmp_path / 'index.toml'
    index.write_text(''.join(f'[[packages]]\nname = "{n}"\npath = "repo/{n}"\nversion = "1.2.3"\n\n' for n in ('one', 'two')))
    (repo / 'one/code.py').write_text('value = 2\n')
    commit(repo)
    indexer.synchronize(index, tmp_path, '1.9.0', independent=True, baseline='v1.2.3')
    data = indexer.tomllib.loads(index.read_text())['packages']
    assert [p['version'] for p in data] == ['1.2.4', '1.2.3']
    before = index.read_text()
    indexer.synchronize(index, tmp_path, '1.9.0', independent=True, baseline='v1.2.3')
    assert index.read_text() == before


def test_static_version_bump_does_not_cause_another_bump(tmp_path):
    repo = repository(tmp_path)
    project = repo / 'pyproject.toml'
    project.write_text('[project]\nname = "one"\nversion = "1.2.3"\n')
    (repo / 'code.py').write_text('old\n')
    commit(repo)
    git(repo, 'tag', 'v1.2.3')
    (repo / 'code.py').write_text('new\n')
    commit(repo)
    index = tmp_path / 'index.toml'
    index.write_text('[[packages]]\nname = "one"\npath = "repo"\nversion = "1.2.3"\n')
    indexer.synchronize(index, tmp_path, '1.9.0', independent=True, baseline='v1.2.3')
    assert 'version = "1.2.4"' in project.read_text()
    commit(repo)
    before = index.read_text()
    indexer.synchronize(index, tmp_path, '1.9.0', independent=True)
    assert index.read_text() == before


def test_auto_release_noop_and_numeric_tag_order(tmp_path):
    repo = repository(tmp_path)
    (repo / 'code').write_text('one')
    commit(repo)
    git(repo, 'tag', 'v1.2.9')
    git(repo, 'tag', 'v1.2.10')
    assert contract.next_release(tmp_path, ['repo']) == ''
    (repo / 'code').write_text('two')
    commit(repo)
    assert contract.next_release(tmp_path, ['repo']) == '1.2.11'


def test_blueprint_pins_are_package_aware(tmp_path):
    manifest = tmp_path / 'manifest.json'
    manifest.write_text(json.dumps({'version': '1.2.3', 'requirements': ['one[x]==1.2.3', 'external==1.2.3', 'two>=1.2.3'], 'skills': [{'package': 'two', 'version': '1.2.3'}]}))
    contract.update_blueprints(tmp_path, {'one': '1.2.4', 'two': '2.0.0'})
    data = json.loads(manifest.read_text())
    assert data['version'] == '1.2.3'
    assert data['requirements'] == ['one[x]==1.2.4', 'external==1.2.3', 'two>=1.2.3']
    assert data['skills'][0]['version'] == '2.0.0'


def test_wheel_gate_catches_blueprint_extra_conflict(tmp_path):
    index = tmp_path / 'index.toml'
    index.write_text('[[packages]]\nname="one"\nversion="1.0.0"\n[[packages]]\nname="two"\nversion="2.0.0"\n')
    for name, version, requirement in [('one', '1.0.0', 'Requires-Dist: two<2; extra == "blueprint"\n'), ('two', '2.0.0', '')]:
        with zipfile.ZipFile(tmp_path / f'{name}-{version}-py3-none-any.whl', 'w') as wheel:
            wheel.writestr(f'{name}-{version}.dist-info/METADATA', f'Metadata-Version: 2.1\nName: {name}\nVersion: {version}\n{requirement}')
    with pytest.raises(SystemExit, match='one requires two<2'):
        validator.validate(index, tmp_path)


def test_sdk_components_remain_a_runtime_version_group(tmp_path):
    repo = repository(tmp_path, 'mn-python-sdk')
    (repo / 'packages/common').mkdir(parents=True)
    for path, name in [(repo, 'mirrorneuron-python-sdk'), (repo / 'packages/common', 'mn-python-sdk-common')]:
        (path / 'pyproject.toml').write_text(f'[project]\nname="{name}"\ndynamic=["version"]\n')
    commit(repo)
    git(repo, 'tag', 'v1.2.3')
    (repo / 'packages/common/code.py').write_text('changed\n')
    commit(repo)
    index = tmp_path / 'index.toml'
    index.write_text('[[packages]]\nname="mirrorneuron-python-sdk"\npath="mn-python-sdk"\nversion = "1.2.3"\n\n[[packages]]\nname="mn-python-sdk-common"\npath="mn-python-sdk/packages/common"\nversion = "1.2.3"\n')
    indexer.synchronize(index, tmp_path, '1.9.0', independent=True, baseline='v1.2.3')
    assert [p['version'] for p in indexer.tomllib.loads(index.read_text())['packages']] == ['1.2.4', '1.2.4']


def test_gar_records_update_without_relabeling_payload_sources(tmp_path):
    path = tmp_path / 'manifest.json'
    records = [{'type': 'pip', 'source': source, 'name': 'one', 'version': '1.0.0'} for source in ('gar', 'payload')]
    path.write_text(json.dumps({'skill_dependencies': records}))
    contract.update_blueprints(tmp_path, {'one': '1.2.4'})
    assert [p['version'] for p in json.loads(path.read_text())['skill_dependencies']] == ['1.2.4', '1.0.0']


def test_publishing_rejects_source_changed_after_preparation(tmp_path):
    repo = repository(tmp_path)
    (repo / 'pyproject.toml').write_text('[project]\nname="one"\ndynamic=["version"]\n')
    commit(repo)
    index = tmp_path / 'index.toml'
    index.write_text('[[packages]]\nname="one"\npath="repo"\nversion = "1.0.0"\n')
    indexer.synchronize(index, tmp_path, '1.1.0', independent=True)
    indexer.verify_sources(index, tmp_path)
    (repo / 'code.py').write_text('new code\n')
    with pytest.raises(SystemExit, match='Uncommitted source'):
        indexer.verify_sources(index, tmp_path)
    commit(repo)
    with pytest.raises(SystemExit, match='Source changed'):
        indexer.verify_sources(index, tmp_path)


def test_package_preview_never_writes_static_project_or_index(tmp_path):
    repo = repository(tmp_path)
    project = repo / 'pyproject.toml'
    project.write_text('[project]\nname="one"\nversion="1.0.0"\n')
    commit(repo)
    index = tmp_path / 'index.toml'
    index.write_text('[[packages]]\nname="one"\npath="repo"\nversion = "1.0.0"\n')
    before = (project.read_text(), index.read_text())
    indexer.synchronize(index, tmp_path, '1.1.0', independent=True, dry_run=True)
    assert (project.read_text(), index.read_text()) == before


def test_static_metadata_commit_does_not_reorder_fingerprint_inputs(tmp_path):
    import hashlib

    repo = repository(tmp_path)
    project = repo / 'optimizer'
    project.mkdir()
    old = '[project]\nname="optimizer"\nversion="1.3.47"\n'
    new = old.replace('1.3.47', '1.3.48')

    def blob_id(content):
        data = content.encode()
        return hashlib.sha1(f'blob {len(data)}\0'.encode() + data).hexdigest()

    low, high = sorted([blob_id(old), blob_id(new)])
    # A blob between the two metadata IDs proves the old sorter changes order.
    code = next(f'value = {i}\n' for i in range(10000) if low < blob_id(f'value = {i}\n') < high)
    (project / 'pyproject.toml').write_text(old)
    (project / 'code.py').write_text(code)
    commit(repo)
    legacy = indexer.source_fingerprint(tmp_path, 'repo/optimizer', legacy=True)
    stable = indexer.source_fingerprint(tmp_path, 'repo/optimizer')
    (project / 'pyproject.toml').write_text(new)
    commit(repo)
    assert indexer.source_fingerprint(tmp_path, 'repo/optimizer', legacy=True) != legacy
    assert indexer.source_fingerprint(tmp_path, 'repo/optimizer') == stable
    assert indexer.source_matches(tmp_path, 'repo/optimizer', legacy)
    index = tmp_path / 'index.toml'
    index.write_text(f'[[packages]]\nname="optimizer"\npath="repo/optimizer"\nversion = "1.3.48"\nsource_hash = "{legacy}"\n')
    indexer.verify_sources(index, tmp_path)
    indexer.synchronize(index, tmp_path, '1.3.49', independent=True)
    record = indexer.tomllib.loads(index.read_text())['packages'][0]
    assert record['version'] == '1.3.48'
    assert record['source_hash'] == stable
    (project / 'code.py').write_text('actual new behavior\n')
    commit(repo)
    assert not indexer.source_matches(tmp_path, 'repo/optimizer', legacy)
    assert not indexer.source_matches(tmp_path, 'repo/optimizer', stable)
