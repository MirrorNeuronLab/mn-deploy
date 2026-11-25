"""Run the installer against fake host commands in an empty runtime home."""

import os
from pathlib import Path
import subprocess

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "install.sh"
FAKE = """#!/bin/bash
name=${0##*/}
echo "$name $*" >> "$TEST_LOG"
case "$name:$*" in
  uname:-s) echo "$TEST_OS";;
  uname:-m) echo arm64;;
  id:-u|id:-g) echo "$TEST_UID";;
  'podman:info --format {{.Host.Security.Rootless}}') test "$TEST_UID" = 0 && echo false || echo true;;
  'podman:info --format {{.Host.RemoteSocket.Path}}') echo /run/user/1000/podman/podman.sock;;
  'podman:info') test "$TEST_OS" = Linux || test "$TEST_READY" = yes || test -f "$TEST_ROOT/started";;
  'podman:machine inspect') test "$TEST_MACHINE" = yes;;
  'podman:machine start') test "$TEST_FAIL" != yes && touch "$TEST_ROOT/started";;
  'podman:machine init') echo "provider=$CONTAINERS_MACHINE_PROVIDER" >> "$TEST_LOG";;
  'systemctl:'*|'brew:install podman'|'apt-get:update'|'apt-get:install -y --no-install-recommends podman') ;;
  *) exit 95;;
esac
"""


def invoke(
    tmp_path,
    *args,
    host="Darwin",
    installed=True,
    ready=False,
    machine=True,
    uid="1000",
    fail=False,
    connection="",
    bootstrap=False,
    package=False,
):
    folder = tmp_path / "bin"
    folder.mkdir()
    for exe in [
        "uname",
        "id",
        "systemctl",
        "brew",
        "apt-get",
        *(["podman"] if installed else []),
    ]:
        path = folder / exe
        path.write_text(FAKE)
        path.chmod(0o755)
    env = {
        **os.environ,
        "PATH": f"{folder}:/usr/bin:/bin",
        "HOME": str(tmp_path),
        "MN_HOME": str(tmp_path / "runtime"),
        "TEST_LOG": str(tmp_path / "calls"),
        "TEST_ROOT": str(tmp_path),
        "TEST_UID": uid,
        "TEST_OS": host,
        "TEST_READY": "yes" if ready else "no",
        "TEST_MACHINE": "yes" if machine else "no",
        "TEST_FAIL": "yes" if fail else "no",
        "CONTAINER_HOST": connection,
    }
    if bootstrap or package:
        source = SCRIPT.read_text()
        section = source[
            source.index("function mn_podman_admin()") : source.index(
                "function mn_detect_version_from_podman()"
            )
        ]
        cmd = [
            "/bin/bash",
            "-c",
            'print_success(){ :; }; print_error(){ echo "$*"; }; print_step(){ :; }\n'
            + section
            + ("\nmn_install_podman_cli" if package else "\nmn_prepare_runtime_podman"),
        ]
    else:
        cmd = ["/bin/bash", str(SCRIPT), *args]
    result = subprocess.run(cmd, env=env, text=True, capture_output=True, timeout=5)
    calls = tmp_path / "calls"
    assert not (tmp_path / "runtime").exists()
    return result, calls.read_text() if calls.exists() else ""


@pytest.mark.parametrize("flag", ["--start-podman", "--start-docker"])
def test_ready_engine_and_compatibility_flag(tmp_path, flag):
    result, calls = invoke(tmp_path, flag, ready=True)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "podman info" in calls and "machine start" not in calls


def test_existing_machine_is_started(tmp_path):
    result, calls = invoke(tmp_path, "--start-podman")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "podman machine start" in calls and "machine init" not in calls


def test_fresh_arm_mac_uses_default_workload_machine(tmp_path):
    result, calls = invoke(tmp_path, bootstrap=True, machine=False)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "provider=libkrun" not in calls
    assert "podman machine init" in calls and "podman machine start" in calls


@pytest.mark.parametrize(
    "uid,expected",
    [
        ("0", "systemctl start podman.socket"),
        ("1000", "systemctl --user start podman.socket"),
    ],
)
def test_native_socket_matches_owner(tmp_path, uid, expected):
    result, calls = invoke(tmp_path, "--start-podman", host="Linux", uid=uid)
    assert result.returncode == 0 and expected in calls


@pytest.mark.parametrize(
    "options",
    [
        {"machine": False},
        {"installed": False},
        {"fail": True},
        {"connection": "ssh://example.invalid"},
    ],
)
def test_start_only_reports_errors_without_installing(tmp_path, options):
    result, calls = invoke(tmp_path, "--start-podman", **options)
    assert result.returncode != 0
    assert "machine init" not in calls and "install podman" not in calls


@pytest.mark.parametrize(
    "host,command",
    [
        ("Darwin", "brew install podman"),
        ("Linux", "apt-get install -y --no-install-recommends podman"),
    ],
)
def test_installs_only_the_podman_package(tmp_path, host, command):
    result, calls = invoke(tmp_path, host=host, uid="0", package=True)
    assert result.returncode == 0, result.stdout + result.stderr
    assert command in calls and "desktop" not in calls and "docker" not in calls
