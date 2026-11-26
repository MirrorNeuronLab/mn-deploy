"""Run the installer against fake host commands in an empty runtime home."""

import os
from pathlib import Path
import shutil
import subprocess
import tty

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
  'podman:info --format {{.Host.RemoteSocket.Path}}') echo "$TEST_SOCKET";;
  'podman:info') test "$TEST_OS" = Linux || test "$TEST_READY" = yes || test -f "$TEST_ROOT/started";;
  'podman:machine inspect') test "$TEST_MACHINE" = yes;;
  'podman:machine start') test "$TEST_FAIL" != yes && touch "$TEST_ROOT/started";;
  'podman:machine init') echo "provider=$CONTAINERS_MACHINE_PROVIDER" >> "$TEST_LOG";;
  'brew:install --formula podman') test "$HOMEBREW_NO_ASK" = 1 && test -z "$HOMEBREW_ASK";;
  'systemctl:'*|'apt-get:update'|'apt-get:install -y --no-install-recommends podman') ;;
  'ps:'*) echo 'Wed Nov 25 12:00:00 2026';;
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
    reported_socket="/run/user/1000/podman/podman.sock",
    socket_override="",
    bootstrap=False,
    package=False,
    stdin=subprocess.DEVNULL,
):
    folder = tmp_path / "bin"
    folder.mkdir()
    for exe in [
        "uname",
        "id",
        "systemctl",
        "brew",
        "apt-get",
        "ps",
        "sudo",
        *(["podman"] if installed else []),
    ]:
        path = folder / exe
        path.write_text(FAKE)
        path.chmod(0o755)
    # Keep a missing Podman and the sudo probe isolated from the host.
    for exe in ("basename", "cat", "chmod", "dirname", "mkdir", "rm", "rmdir", "touch"):
        (folder / exe).symlink_to(shutil.which(exe))
    runtime = tmp_path / "runtime"
    had_runtime = runtime.exists()
    env = {
        **os.environ,
        "PATH": str(folder),
        "HOME": str(tmp_path),
        "MN_HOME": str(runtime),
        "TEST_LOG": str(tmp_path / "calls"),
        "TEST_ROOT": str(tmp_path),
        "TEST_UID": uid,
        "TEST_OS": host,
        "TEST_READY": "yes" if ready else "no",
        "TEST_MACHINE": "yes" if machine else "no",
        "TEST_FAIL": "yes" if fail else "no",
        "CONTAINER_HOST": connection,
        "TEST_SOCKET": reported_socket,
        "PODMAN_HOST_SOCKET": socket_override,
        "HOMEBREW_ASK": "1",
        "HOMEBREW_NO_ASK": "",
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
            'print_success(){ :; }; print_error(){ echo "$*" >&2; }; print_step(){ :; }\n'
            + section
            + (
                "\nmn_install_podman_cli"
                if package
                else '\nmn_prepare_runtime_podman && echo "$PODMAN_HOST_SOCKET"'
            ),
        ]
    else:
        cmd = ["/bin/bash", str(SCRIPT), *args]
    result = subprocess.run(
        cmd,
        env=env,
        stdin=stdin,
        text=True,
        capture_output=True,
        timeout=5,
        start_new_session=True,
    )
    calls = tmp_path / "calls"
    assert runtime.exists() == had_runtime
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
    "reported,override,expected",
    [
        ("/run/podman/podman.sock", "", "/run/podman/podman.sock"),
        (
            "unix:///run/user/501/podman/podman.sock",
            "",
            "/run/user/501/podman/podman.sock",
        ),
        ("", "unix:///custom dir/podman.sock", "/custom dir/podman.sock"),
    ],
)
def test_runtime_uses_absolute_engine_socket(tmp_path, reported, override, expected):
    result, calls = invoke(
        tmp_path,
        bootstrap=True,
        ready=True,
        reported_socket=reported,
        socket_override=override,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert result.stdout.splitlines() == [expected]
    assert ("{{.Host.RemoteSocket.Path}}" in calls) == (not override)


def test_reset_preserves_data_when_machine_reports_an_invalid_socket(tmp_path):
    runtime = tmp_path / "runtime"
    runtime.mkdir()
    marker = runtime / "old-runtime-data"
    marker.write_text("keep this")
    answer = tmp_path / "answer"
    answer.write_text("YES\n")
    with answer.open() as stdin:
        result, calls = invoke(
            tmp_path,
            "--mode",
            "local",
            "--reset",
            "--build-membrane",
            ready=True,
            reported_socket="unix://other-host/run/podman.sock",
            stdin=stdin,
        )
    assert result.returncode != 0
    assert "absolute Podman API socket path" in result.stdout
    assert "Reset stopped before host cleanup" in result.stdout
    assert "podman exec" not in calls
    assert marker.read_text() == "keep this"


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
    assert "machine init" not in calls and "brew install" not in calls


@pytest.mark.parametrize(
    "host,command",
    [
        ("Darwin", "brew install --formula podman"),
        ("Linux", "apt-get install -y --no-install-recommends podman"),
    ],
)
def test_installs_only_the_podman_package(tmp_path, host, command):
    result, calls = invoke(tmp_path, host=host, uid="0", package=True)
    assert result.returncode == 0, result.stdout + result.stderr
    assert command in calls and "desktop" not in calls and "docker" not in calls


@pytest.mark.parametrize(
    "flags,expected",
    [([], "sudo apt-get update"), (["--yes"], "sudo -n apt-get update")],
)
def test_terminal_reset_uses_selected_sudo_mode(tmp_path, flags, expected):
    master, slave = os.openpty()
    try:
        tty.setraw(slave)
        os.write(master, b"YES\n")
        result, calls = invoke(
            tmp_path, "--reset", *flags, host="Linux", installed=False, stdin=slave
        )
    finally:
        os.close(master)
        os.close(slave)
    # Fake sudo records its arguments and fails before any cleanup.
    assert expected in calls.splitlines(), result.stdout + result.stderr
    assert result.returncode != 0
    assert "Reset stopped before host cleanup" in result.stdout
