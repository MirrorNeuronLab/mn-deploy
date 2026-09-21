"""Offline Docker cleanup regressions; never invoke the full uninstaller."""
import json
import os
from pathlib import Path
import subprocess
import sys

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / 'uninstall.sh'


@pytest.mark.parametrize('worker_project', ['mirror-neuron-workers', 'custom-workers'])
@pytest.mark.parametrize('scenario', ['normal', 'external', 'attached', 'inventory', 'remove', 'empty'])
def test_worker_cleanup(tmp_path, worker_project, scenario):
    state = tmp_path / 'state.json'
    state.write_text(json.dumps({'containers': [] if scenario == 'empty' else ['core', 'worker'], 'calls': []}))
    docker = tmp_path / 'docker'
    docker.write_text(f'#!{sys.executable}\n' + '''import json, os, sys
from pathlib import Path
p = Path(os.environ['STATE'])
s = json.loads(p.read_text())
a = sys.argv[1:]
s['calls'].append(a)
scenario = os.environ['SCENARIO']
worker = os.environ['WORKER']
project = next((x.split('=', 2)[-1] for x in a if x.startswith('label=')), '')
code = 0
if a[0] == 'ps':
    if scenario == 'inventory' and project == worker:
        code = 1
    else:
        name = 'core' if project == 'runtime' else 'worker' if project == worker else ''
        if name in s['containers']: print(name)
elif a[0] == 'rm':
    if scenario == 'remove' and a[-1] == 'worker': code = 1
    else: s['containers'].remove(a[-1])
elif a[:2] == ['volume', 'ls']:
    if scenario != 'empty': print(project + '-data')
elif a[:2] == ['volume', 'rm']:
    if s['containers']: code = 1
elif a[:2] == ['network', 'ls']:
    if project == 'runtime' and scenario != 'empty': print('network-id runtime-network')
elif a[:2] == ['network', 'rm']:
    if s['containers'] or scenario == 'attached': code = 1
elif a[:2] == ['network', 'inspect']:
    code = 1
else:
    raise AssertionError(a)
p.write_text(json.dumps(s))
sys.exit(code)
''')
    docker.chmod(0o755)
    source = SCRIPT.read_text()
    functions = source[source.index('function remove_compose_project_resources()'):source.index('function remove_docker_runtime_project()')]
    result = subprocess.run(['bash', '-c', '''set -e
exec 3>&1
print_error() { printf 'error: %s\\n' "$1"; }
COMPOSE_PROJECT_NAME=runtime
WORKER_COMPOSE_PROJECT_NAME="$WORKER"
DOCKER_NETWORK_NAME=runtime-network
DOCKER_NETWORK_EXTERNAL_KNOWN=Y
DOCKER_NETWORK_EXTERNAL=N
[ "$SCENARIO" != external ] || DOCKER_NETWORK_EXTERNAL=Y
''' + functions + '\nremove_compose_project_resources\n'], env={**os.environ, 'PATH': f'{tmp_path}:/usr/bin:/bin', 'STATE': str(state), 'SCENARIO': scenario, 'WORKER': worker_project}, capture_output=True, text=True)
    final = json.loads(state.read_text())
    assert (result.returncode == 0) == (scenario in {'normal', 'external', 'empty'}), result.stdout + result.stderr
    calls = final['calls']
    assert all('prune' not in call for call in calls)
    if scenario in {'normal', 'external'}:
        assert final['containers'] == []
        worker_rm = calls.index(['rm', '-f', 'worker'])
        assert all(i > worker_rm for i, call in enumerate(calls) if call[:2] in [['volume', 'rm'], ['network', 'rm']])
    if scenario == 'external':
        assert not any(call[:2] == ['network', 'rm'] for call in calls)
    if scenario == 'attached':
        assert 'runtime-network' in result.stdout
    if scenario == 'inventory':
        assert 'Could not list containers' in result.stdout
    if scenario == 'remove':
        assert 'Could not remove container worker' in result.stdout
        assert not any(call[:2] == ['network', 'rm'] for call in calls)
