"""Offline startup contract: execute launchers with fake Erlang executables."""
import os
from pathlib import Path
import subprocess

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]


def launcher():
    value = yaml.safe_load((ROOT / "docker-compose.yml").read_text())
    import shlex
    return shlex.split(value["services"]["mirror-neuron-core"]["command"].replace("$$", "$"))


def executable(path, body):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("#!/bin/sh\n" + body + "\n")
    path.chmod(0o755)


@pytest.mark.parametrize("release", [True, False])
@pytest.mark.parametrize("name", ["", "nonode@nohost", "a", "@host", "a@", "a@b@c", "bad name@host", "a@.host"])
def test_rejects_unnamed_and_malformed_startup(tmp_path, release, name):
    executable(tmp_path / "bin/mirror_neuron" if release else tmp_path / "mix", "touch unexpected-start")
    result = subprocess.run(launcher(), cwd=tmp_path,
                            env={**os.environ, "MN_NODE_NAME": name, "MN_COOKIE": "test-secret"},
                            capture_output=True, text=True)
    assert result.returncode != 0
    assert "error:" in result.stderr
    assert not (tmp_path / "unexpected-start").exists()


@pytest.mark.parametrize("release", [True, False])
def test_named_startup_uses_same_identity_in_both_modes(tmp_path, release):
    executable(tmp_path / "epmd", "exit 0")
    executable(tmp_path / "erts-test/bin/epmd", "exit 0")
    executable(tmp_path / "bin/mirror_neuron", 'printf "%s %s" "$RELEASE_DISTRIBUTION" "$RELEASE_NODE"') if release else None
    executable(tmp_path / "elixir", 'printf "%s\\n" "$@"')
    name = "mirror_neuron_test@127.0.0.1"
    result = subprocess.run(launcher(), cwd=tmp_path,
                            env={**os.environ, "PATH": f"{tmp_path}:{os.environ['PATH']}",
                                 "MN_NODE_NAME": name, "MN_COOKIE": "test-secret"},
                            capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    assert name in result.stdout
    assert ("name " if release else "--name\n") in result.stdout


def test_bundled_startup_contract_matches_when_checkout_available():
    bundled = Path.home() / "Projects/otterdesk-desktop-app/resources/mirror-neuron-runtime"
    if not bundled.is_dir():
        pytest.skip("OtterDesk checkout is not available")
    deploy = yaml.safe_load((ROOT / "docker-compose.yml").read_text())
    desktop = yaml.safe_load((bundled / "docker-compose.yml").read_text())
    assert deploy["services"]["mirror-neuron-core"]["command"] == desktop["services"]["mirror-neuron-core"]["command"]
    for source in [(ROOT / "install.sh").read_text(), (bundled / "install.sh").read_text()]:
        assert "MN_DETECT_IDENTITY_INVALID" in source
        assert "s/^MN_NODE_NAME=//p" in source
        assert "mn runtime start failed; starting MirrorNeuron Docker Compose runtime." not in source
        assert 'runtime_compose up -d mirror-neuron-core' not in source
