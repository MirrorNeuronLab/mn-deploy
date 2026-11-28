"""Exercise Podman setup and recovery with fake host commands."""

import os
from pathlib import Path
import shutil
import subprocess
import tty

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "install.sh"
UNINSTALL = SCRIPT.with_name("uninstall.sh")
PREPARE = SCRIPT.parent / "scripts/preapare_dev.sh"
START_COMMANDS = [
    pytest.param(SCRIPT, "--start-podman", id="install"),
    pytest.param(UNINSTALL, "--yes", id="uninstall"),
]
FAKE = """#!/bin/bash
name=${0##*/}
echo "$name $*" >> "$TEST_LOG"
case "$name:$*" in
  uname:-s) echo "$TEST_OS";;
  uname:-m) echo arm64;;
  id:-u|id:-g) echo "$TEST_UID";;
  'podman:info --format {{.Host.Security.Rootless}}') test "$TEST_UID" = 0 && echo false || echo true;;
  'podman:info --format {{.Host.RemoteSocket.Path}}') echo "$TEST_SOCKET";;
  'podman:info')
    if [ "$TEST_OS" = Linux ] || [ "$TEST_READY" = yes ]; then exit 0; fi
    case "$TEST_STATE" in
      running|starting) ;;
      *) [ -f "$TEST_ROOT/started" ] || exit 1;;
    esac
    if [ "$TEST_RECOVERS" = yes ] && [ -f "$TEST_ROOT/stopped" ] &&
      [ -f "$TEST_ROOT/started" ]; then exit 0; fi
    probes=0
    if [ -f "$TEST_ROOT/probes" ]; then read -r probes <"$TEST_ROOT/probes"; fi
    echo "$((probes + 1))" >"$TEST_ROOT/probes"
    if [ "$probes" -lt "$TEST_PROBE_DELAY" ]; then
      echo "$TEST_INFO_ERROR" >&2
      exit 1
    fi;;
  'podman:system connection list --format {{.Default}} {{.IsMachine}} {{.Name}} {{.URI}}')
    printf '%s\\n' "$TEST_CONNECTIONS";;
  'podman:machine list --quiet')
    if [ -n "$TEST_STATE" ]; then echo "$TEST_MACHINE_NAME"; fi;;
  'podman:machine inspect --format {{.State}} '*)
    [ "$5" = "$TEST_MACHINE_NAME" ] || exit 95
    if [ -f "$TEST_ROOT/started" ]; then echo running
    elif [ -f "$TEST_ROOT/initialized" ] || [ -f "$TEST_ROOT/stopped" ]; then echo stopped
    elif [ -n "$TEST_STATE" ]; then echo "$TEST_STATE"
    else exit 1; fi;;
  'podman:machine start '*)
    [ "$3" = "$TEST_MACHINE_NAME" ] || exit 95
    if [ "$TEST_FAIL" = yes ]; then echo 'start failed' >&2; exit 1; fi
    touch "$TEST_ROOT/started"
    if [ "$TEST_RACE" = yes ]; then echo 'already running' >&2; exit 1; fi;;
  'podman:machine stop '*)
    [ "$3" = "$TEST_MACHINE_NAME" ] || exit 95
    if [ "$TEST_STOP_FAIL" = yes ]; then echo 'stop failed' >&2; exit 1; fi
    rm -f "$TEST_ROOT/started"
    touch "$TEST_ROOT/stopped";;
  'podman:machine init --memory 8192')
    echo "provider=$CONTAINERS_MACHINE_PROVIDER" >> "$TEST_LOG"
    touch "$TEST_ROOT/initialized";;
  'podman:ps '*|'podman:volume ls '*|'podman:network ls '*) ;;
  'podman:network inspect '*|'podman:image inspect '*) exit 1;;
  'brew:install --formula podman')
    [ "$HOMEBREW_NO_ASK" = 1 ] && [ -z "$HOMEBREW_ASK" ] || exit 1
    if [ ! -e "$TEST_ROOT/bin/podman" ]; then ln -s "$0" "$TEST_ROOT/bin/podman"; fi;;
  'systemctl:'*|'apt-get:update'|'apt-get:install -y --no-install-recommends podman') ;;
  'ps:'*) echo 'Wed Nov 25 12:00:00 2026';;
  'rustc:--print target-libdir --target wasm32-wasip2') echo "$TEST_ROOT/wasm-target";;
  'sleep:1') ;;
  *) exit 95;;
esac
"""


def invoke(
    tmp_path,
    *args,
    script=SCRIPT,
    host="Darwin",
    installed=True,
    ready=False,
    state="stopped",
    machine_name="podman-machine-default",
    probe_delay=0,
    info_error="Error: unable to connect to Podman socket: dial tcp 127.0.0.1:4321: connect: connection refused",
    recovers=False,
    stop_fails=False,
    uid="1000",
    fail=False,
    race=False,
    connection="",
    selected="",
    connections=None,
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
        "sleep",
        "sudo",
        "cargo",
        "rustc",
        *(["podman"] if installed else []),
    ]:
        path = folder / exe
        path.write_text(FAKE)
        path.chmod(0o755)
    # Keep a missing Podman and the sudo probe isolated from the host.
    for exe in (
        "awk",
        "basename",
        "cat",
        "chmod",
        "dirname",
        "grep",
        "ln",
        "mkdir",
        "rm",
        "rmdir",
        "touch",
        "tr",
    ):
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
        "TEST_MACHINE_NAME": machine_name,
        "TEST_STATE": state,
        "TEST_PROBE_DELAY": str(probe_delay),
        "TEST_INFO_ERROR": info_error,
        "TEST_RECOVERS": "yes" if recovers else "no",
        "TEST_STOP_FAIL": "yes" if stop_fails else "no",
        "TEST_FAIL": "yes" if fail else "no",
        "TEST_RACE": "yes" if race else "no",
        "CONTAINER_HOST": connection,
        "CONTAINER_CONNECTION": selected,
        "TEST_CONNECTIONS": connections
        if connections is not None
        else (f"true true {machine_name} ssh://core@localhost/socket" if state else ""),
        "OPENSHELL_CONTAINER_CONFIG_DIR": str(tmp_path / "openshell"),
        "TEST_SOCKET": reported_socket,
        "PODMAN_HOST_SOCKET": socket_override,
        "HOMEBREW_ASK": "1",
        "HOMEBREW_NO_ASK": "",
    }
    if script == PREPARE:
        (tmp_path / "wasm-target").mkdir()
        sdk = tmp_path / "wasi sdk"
        (sdk / "bin").mkdir(parents=True)
        for name in ("clang", "llvm-ar"):
            (sdk / "bin" / name).symlink_to(shutil.which("true"))
        env["WASI_SDK_PATH"] = str(sdk)
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
            'exec 3>&1\nprint_success(){ :; }; print_error(){ echo "$*" >&2; }; print_step(){ :; }\n'
            + section
            + (
                "\nmn_install_podman_cli"
                if package
                else '\nmn_prepare_runtime_podman && echo "$PODMAN_HOST_SOCKET"'
            ),
        ]
    else:
        cmd = ["/bin/bash", str(script), *args]
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
    if script != UNINSTALL:
        assert runtime.exists() == had_runtime
    return result, calls.read_text() if calls.exists() else ""


@pytest.mark.parametrize("flag", ["--start-podman", "--start-docker"])
def test_ready_engine_and_compatibility_flag(tmp_path, flag):
    result, calls = invoke(tmp_path, flag, ready=True)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "podman info" in calls and "machine start" not in calls


@pytest.mark.parametrize(("script", "flag"), START_COMMANDS)
@pytest.mark.parametrize("scenario", ["stopped", "starting", "running", "racing"])
def test_waits_for_the_existing_machine_api(tmp_path, script, flag, scenario):
    runtime = tmp_path / "runtime"
    runtime.mkdir()
    result, calls = invoke(
        tmp_path,
        flag,
        script=script,
        state="stopped" if scenario == "racing" else scenario,
        race=scenario == "racing",
        probe_delay=2,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    commands = calls.splitlines()
    assert commands.count("podman machine start podman-machine-default") == (
        1 if scenario in {"stopped", "racing"} else 0
    )
    assert "machine init" not in calls and "machine stop" not in calls
    assert "already running" not in result.stderr
    last_probe = len(commands) - 1 - commands[::-1].index("podman info")
    assert "sleep 1" in commands[:last_probe]
    if script == UNINSTALL:
        assert not runtime.exists()
        assert last_probe < next(
            index for index, cmd in enumerate(commands) if cmd.startswith("podman ps ")
        )


@pytest.mark.parametrize(("script", "flag"), START_COMMANDS)
def test_restarts_unreachable_running_machine(tmp_path, script, flag):
    runtime = tmp_path / "runtime"
    runtime.mkdir()
    result, calls = invoke(
        tmp_path, flag, script=script, state="running", probe_delay=99, recovers=True
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert "Restarting Podman machine podman-machine-default once" in result.stdout
    commands = calls.splitlines()
    stop = "podman machine stop podman-machine-default"
    start = "podman machine start podman-machine-default"
    assert commands.count(stop) == commands.count(start) == 1
    stop_index = commands.index(stop)
    start_index = commands.index(start)
    last_probe = commands.index("podman info", start_index + 1)
    assert "sleep 1" in commands[:stop_index]
    assert stop_index < start_index < last_probe
    if script == UNINSTALL:
        assert not runtime.exists()
        assert last_probe < next(
            index for index, cmd in enumerate(commands) if cmd.startswith("podman ps ")
        )


@pytest.mark.parametrize(("script", "flag"), START_COMMANDS)
@pytest.mark.parametrize("stop_fails", [False, True])
def test_recovery_failure_preserves_runtime_files(tmp_path, script, flag, stop_fails):
    runtime = tmp_path / "runtime"
    runtime.mkdir()
    marker = runtime / "old-runtime-data"
    marker.touch()
    result, calls = invoke(
        tmp_path,
        flag,
        script=script,
        state="running",
        probe_delay=99,
        stop_fails=stop_fails,
    )
    assert result.returncode != 0
    if stop_fails:
        assert "Could not stop Podman machine" in result.stdout
    else:
        assert (
            "Podman machine podman-machine-default is still unreachable"
            in result.stdout
        )
    commands = calls.splitlines()
    assert commands.count("podman machine stop podman-machine-default") == 1
    assert commands.count("podman machine start podman-machine-default") == (
        0 if stop_fails else 1
    )
    assert "podman ps" not in calls and marker.exists()


@pytest.mark.parametrize(
    "options",
    [
        {"state": "starting"},
        {"state": "running", "info_error": "ssh: unable to authenticate"},
    ],
)
def test_skips_restart_when_the_vm_is_booting_or_refusal_is_not_reported(
    tmp_path, options
):
    result, calls = invoke(tmp_path, "--start-podman", probe_delay=99, **options)
    assert result.returncode != 0
    assert "machine stop" not in calls and "machine start" not in calls


@pytest.mark.parametrize(
    ("options", "ready"),
    [
        ({"installed": False, "state": ""}, True),
        ({"state": "running", "probe_delay": 99, "recovers": True}, True),
        ({"state": "running", "probe_delay": 99}, False),
    ],
)
def test_developer_setup_prepares_podman_and_keeps_stdout_for_the_sdk(
    tmp_path, options, ready
):
    result, calls = invoke(tmp_path, script=PREPARE, **options)
    assert (result.returncode == 0) == ready, result.stderr
    assert result.stdout == (str(tmp_path / "wasi sdk") + "\n" if ready else "")
    if ready:
        assert "Podman is ready" in result.stderr
    else:
        assert "Could not prepare Podman" in result.stderr
    if options["state"]:
        assert "podman machine stop podman-machine-default" in calls
    else:
        assert (
            "brew install --formula podman" in calls and "podman machine init" in calls
        )
    assert "podman machine start podman-machine-default" in calls


@pytest.mark.parametrize(("script", "flag"), START_COMMANDS)
def test_starts_the_machine_for_the_selected_rootful_connection(tmp_path, script, flag):
    result, calls = invoke(
        tmp_path,
        flag,
        script=script,
        machine_name="custom-machine",
        selected="custom-machine-root",
        connections=(
            "true false remote ssh://root@example.invalid/socket\n"
            "false true custom-machine-root ssh://root@localhost/socket"
        ),
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert "podman machine start custom-machine" in calls.splitlines()


@pytest.mark.parametrize(("script", "flag"), START_COMMANDS)
def test_unreachable_default_remote_does_not_start_a_local_machine(
    tmp_path, script, flag
):
    result, calls = invoke(
        tmp_path,
        flag,
        script=script,
        connections=(
            "true false remote ssh://root@example.invalid/socket\n"
            "false true podman-machine-default ssh://core@localhost/socket"
        ),
    )
    assert result.returncode != 0
    assert "selected Podman connection is unreachable" in result.stdout
    assert "podman machine" not in calls and "podman ps" not in calls


def test_uninstall_does_not_initialize_a_machine(tmp_path):
    result, calls = invoke(tmp_path, "--yes", script=UNINSTALL, state="")
    assert result.returncode != 0
    assert "No Podman machine connection is selected" in result.stdout
    assert "podman machine" not in calls and "podman ps" not in calls


def test_fresh_arm_mac_uses_default_workload_machine(tmp_path):
    result, calls = invoke(tmp_path, bootstrap=True, state="")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "provider=libkrun" not in calls
    assert (
        "podman machine init --memory 8192" in calls and "podman machine start" in calls
    )


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


@pytest.mark.parametrize(
    ("options", "error"),
    [
        (
            {"ready": True, "reported_socket": "unix://other-host/run/podman.sock"},
            "absolute Podman API socket path",
        ),
        ({"state": "running", "probe_delay": 99}, "still unreachable"),
    ],
)
def test_reset_preserves_data_when_podman_is_unusable(tmp_path, options, error):
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
            script=SCRIPT.with_name("install_dev.sh"),
            stdin=stdin,
            **options,
        )
    assert result.returncode != 0
    assert error in result.stdout
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
        {"state": ""},
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
