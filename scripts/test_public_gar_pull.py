"""Offline Docker credential/daemon contracts; never contacts a real daemon."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys

import pytest

SOURCE = (Path(__file__).resolve().parents[1] / 'install.sh').read_text()
PUBLIC = 'us-central1-docker.pkg.dev/mirrorneuron-public-packages/mirrorneuron-runtime/'


def function(name):
    return re.findall(r'^function ' + name + r'\(\) [({]\n.*?^[})](?=\n\n)', SOURCE, re.M | re.S)


def run_pull(tmp_path, *, target='core', host='', context='', endpoint='', status=0, image=None):
    config = tmp_path / 'caller config'
    config.mkdir()
    original = '{"credHelpers":{"us-central1-docker.pkg.dev":"gcloud"}}'
    (config / 'config.json').write_text(original)
    bin_dir = tmp_path / 'bin'
    bin_dir.mkdir()
    docker = bin_dir / 'docker'
    docker.write_text(f'''#!{sys.executable}
import json, os, pathlib, sys
args = sys.argv[1:]
if args[:2] == ['context', 'inspect']:
    print(os.environ['TEST_ENDPOINT'])
elif args[0] == 'pull':
    config = pathlib.Path(os.environ['DOCKER_CONFIG'])
    with open(os.environ['TEST_LOG'], 'a') as log:
        log.write(json.dumps({{'image': args[1], 'config': str(config), 'host': os.getenv('DOCKER_HOST'), 'context': os.getenv('DOCKER_CONTEXT'), 'auth': os.getenv('DOCKER_AUTH_CONFIG')}}) + '\\n')
    if args[1].startswith({PUBLIC!r}) and (config / 'config.json').exists():
        sys.exit(99)  # An expired gcloud credential helper would fail here.
    sys.exit(int(os.environ['TEST_STATUS']))
elif args[:2] == ['image', 'inspect']:
    fmt = args[3]
    if 'image.version' in fmt: print('v1.3.57')
    elif 'image.revision' in fmt: print('revision')
    elif 'RepoDigests' in fmt: print(args[-1] + '@sha256:' + 'a' * 64)
''')
    docker.chmod(0o755)
    selected_image = image or PUBLIC + ('mirror-neuron-core' if target == 'core' else 'membrane-context-engine') + ':v1.3.57'
    script = '\n'.join(function('mn_pull_public_gar_image')) + '\n'
    if target == 'core':
        script += '\n'.join(function('install_core_from_gar')) + '\n'
        script += 'core_gar_image_for_tag() { printf "%s" "$TEST_IMAGE"; }\n'
        call = 'install_core_from_gar'
    else:
        script += function('pull_context_engine_image')[int(target)] + '\n'
        script += 'read_env_value() { printf "%s" "$TEST_IMAGE"; }\n'
        call = 'pull_context_engine_image'
    script += '''
print_detail() { :; }
print_error() { echo "$*" >&2; }
print_success() { :; }
print_warning() { :; }
runtime_compose() { echo "compose:$*"; }
'''
    script += call + '\n'
    result = subprocess.run(['bash', '-euc', script], capture_output=True, text=True, timeout=10,
                            env={**os.environ, 'PATH': f'{bin_dir}:{os.environ["PATH"]}',
                                 'DOCKER_CONFIG': str(config), 'DOCKER_HOST': host,
                                 'DOCKER_CONTEXT': context, 'DOCKER_AUTH_CONFIG': '{"auths":{}}',
                                 'DOCKER_HOST_SOCKET': '/platform/docker.sock',
                                 'TEST_ENDPOINT': endpoint, 'TEST_STATUS': str(status),
                                 'TEST_LOG': str(tmp_path / 'log'), 'TEST_IMAGE': selected_image,
                                 'CORE_RELEASE_TAG': 'v1.3.57', 'INSTALL_DIR': str(tmp_path / 'installed'),
                                 'INSTALL_METADATA_FILE': str(tmp_path / 'installed/metadata.json'),
                                 'RUNTIME_COMPOSE_ENV': 'unused', 'TMPDIR': str(tmp_path)})
    assert (config / 'config.json').read_text() == original
    assert (tmp_path / 'log').exists(), result.stderr
    records = [json.loads(line) for line in (tmp_path / 'log').read_text().splitlines()]
    return result, records, config


@pytest.mark.parametrize('target', ['core', '0', '1', '2'])
@pytest.mark.parametrize('host,context,endpoint,expected', [
    ('', '', '', 'unix:///platform/docker.sock'),
    ('', '', 'unix:///desktop/docker.sock', 'unix:///desktop/docker.sock'),
    ('tcp://explicit:2376', '', 'unix:///unused.sock', 'tcp://explicit:2376'),
    ('tcp://ignored:2376', 'desktop-linux', 'unix:///selected.sock', 'unix:///selected.sock'),
])
def test_public_pulls_bypass_helpers_and_preserve_daemon(tmp_path, target, host, context, endpoint, expected):
    result, records, config = run_pull(tmp_path, target=target, host=host, context=context, endpoint=endpoint)
    assert result.returncode == 0, result.stderr
    assert len(records) == 1
    record = records[0]
    assert record['host'] == expected
    assert record['context'] is None
    assert record['auth'] is None
    assert record['config'] != str(config)
    assert not Path(record['config']).exists()
    if target == 'core':
        metadata = json.loads((tmp_path / 'installed/metadata.json').read_text())
        assert metadata['core_image_digest'] == 'sha256:' + 'a' * 64


@pytest.mark.parametrize('target', ['core', '0', '1', '2'])
def test_public_pull_failure_cleans_config_and_stops(tmp_path, target):
    result, records, _ = run_pull(tmp_path, target=target, status=7)
    assert result.returncode != 0
    assert 'Could not pull' in result.stderr
    assert len(records) == 1
    assert not Path(records[0]['config']).exists()
    assert not (tmp_path / 'installed/metadata.json').exists()


def test_private_core_override_keeps_credentials(tmp_path):
    result, records, config = run_pull(tmp_path, image='private.example/core:v1.3.57', host='tcp://private:2376')
    assert result.returncode == 0, result.stderr
    assert records[0]['config'] == str(config)
    assert records[0]['host'] == 'tcp://private:2376'
