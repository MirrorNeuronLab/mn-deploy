"""Offline end-to-end tests: every gcloud invocation uses a fake executable."""
import json
import os
from pathlib import Path
import subprocess
import sys

import pytest


ENTRY = Path(__file__).resolve().parents[1] / 'CLEARN_GAR.sh'
PROJECT = 'mirrorneuron-public-packages'


@pytest.fixture
def registry(tmp_path):
    data = {'repositories': [], 'packages': {}, 'versions': {}, 'tags': {}}
    for location, repository, fmt in [('us-central1', 'python', 'PYTHON'), ('europe-west1', 'npm', 'NPM'), ('us', 'runtime', 'DOCKER'), ('us', 'archives', 'GENERIC')]:
        root = f'projects/{PROJECT}/locations/{location}/repositories/{repository}'
        package = root + '/packages/' + ('%40scope%2Fui' if fmt == 'NPM' else 'example')
        data['repositories'].append({'name': root, 'format': fmt, 'mode': 'STANDARD_REPOSITORY'})
        data['packages'][repository] = [{'name': package}]
        ids = ['sha256:old', 'sha256:new', 'sha256:unknown', 'sha256:shared'] if fmt == 'DOCKER' else ['1.3.9', '1.3.47', '1.3.48', '1.3.100', '1.3.48-rc.1', 'unknown']
        data['versions'][repository] = [{'name': package + '/versions/' + version} for version in ids]
        aliases = {'v1.3.47': 'sha256:old', '1.3.47': 'sha256:old', 'v1.3.48': 'sha256:new', 'latest': 'sha256:new', 'v1.2.0': 'sha256:shared', 'v2.0.0': 'sha256:shared'} if fmt == 'DOCKER' else {}
        data['tags'][repository] = [{'name': package + '/tags/' + tag, 'version': package + '/versions/' + version} for tag, version in aliases.items()]
    state = tmp_path / 'state.json'
    state.write_text(json.dumps(data))
    log = tmp_path / 'calls.jsonl'
    fake = tmp_path / 'gcloud'
    fake.write_text(f'''#!{sys.executable}
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ['FAKE_LOG'], 'a') as out:
    out.write(json.dumps(args) + '\\n')
data = json.loads(Path(os.environ['FAKE_STATE']).read_text())
if args[1:3] == ['versions', 'delete']:
    sys.exit(1 if os.environ.get('FAIL_DELETE') else 0)
kind = args[1]
if os.environ.get('FAIL_INVENTORY') and kind == 'versions':
    sys.exit(1)
if kind == 'repositories':
    result = data[kind]
else:
    repo = next(a.split('=', 1)[1] for a in args if a.startswith('--repository='))
    result = data[kind][repo]
if os.environ.get('CHANGE_PLAN') and kind == 'tags':
    count = sum(1 for line in Path(os.environ['FAKE_LOG']).read_text().splitlines() if json.loads(line)[1] == 'repositories')
    if count > 1 and result:
        result = []
print(json.dumps(result))
''')
    fake.chmod(0o755)
    env = {**os.environ, 'MN_GCLOUD_BIN': str(fake), 'MN_CLEAN_GAR_PYTHON': sys.executable, 'FAKE_LOG': str(log), 'FAKE_STATE': str(state), 'MN_GAR_PROJECT': PROJECT}

    def run(*args, answer='YES\n', **extra):
        result = subprocess.run([str(ENTRY), *args], input=answer, capture_output=True, text=True, env={**env, **extra}, timeout=15)
        calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        deleted = [call[3] for call in calls if call[1:3] == ['versions', 'delete']]
        return result, calls, deleted
    return run


def test_cutoff_across_formats_and_locations(registry):
    result, calls, deleted = registry('-v', '1.3.48')
    assert result.returncode == 0, result.stderr
    assert 'Type YES' in result.stdout
    assert len(deleted) == 10  # Three older versions per language/generic repo, one Docker digest.
    assert any('europe-west1' in name for name in deleted)
    assert any('%40scope%2Fui' in name for name in deleted)
    assert any(name.endswith('sha256:old') for name in deleted)
    assert not any(name.endswith(('1.3.48', '1.3.100', 'sha256:new', 'sha256:shared', 'sha256:unknown', '/unknown')) for name in deleted)
    assert '--location=all' in calls[0]
    assert all('--delete-tags' in call and '--quiet' in call for call in calls if call[2] == 'delete')
    assert 'tags: 1.3.47, v1.3.47' in result.stdout


def test_all_includes_unknown_and_untagged_versions(registry):
    result, calls, deleted = registry('-a')
    assert result.returncode == 0, result.stderr
    assert len(deleted) == 22
    assert any(name.endswith('/unknown') for name in deleted)
    assert any(name.endswith('sha256:unknown') for name in deleted)
    assert not any(call[1] == 'repositories' and call[2] == 'delete' for call in calls)


@pytest.mark.parametrize('answer', ['yes\n', 'Y\n', 'YES \n', '\n', ''])
def test_exact_confirmation_required(registry, answer):
    result, _, deleted = registry('-a', answer=answer)
    assert result.returncode == 0
    assert not deleted
    assert 'Cancelled' in result.stdout


def test_dry_run_never_deletes_or_prompts(registry):
    result, _, deleted = registry('-v', 'v1.3.48', '--dry-run')
    assert result.returncode == 0
    assert not deleted
    assert 'Type YES' not in result.stdout


@pytest.mark.parametrize('args', [[], ['-a', '-v', '1.3.48'], ['-v', ''], ['-v', 'banana'], ['-v', '1.03.48']])
def test_bad_arguments_do_not_access_registry(registry, args):
    result, calls, deleted = registry(*args)
    assert result.returncode != 0
    assert not calls and not deleted


def test_inventory_failure_never_partially_deletes(registry):
    result, _, deleted = registry('-a', FAIL_INVENTORY='1')
    assert result.returncode != 0
    assert not deleted


def test_moving_docker_tags_requires_new_confirmation(registry):
    result, _, deleted = registry('-v', '1.3.48', CHANGE_PLAN='1')
    assert result.returncode != 0
    assert 'plan changed' in result.stderr
    assert not deleted


def test_delete_failure_stops_and_reports_progress(registry):
    result, _, deleted = registry('-a', FAIL_DELETE='1')
    assert result.returncode != 0
    assert len(deleted) == 1
    assert '0/22 deletions completed' in result.stderr
