"""Run the local installer up to the first Podman call with offline fixtures."""

from pathlib import Path
import shutil
import subprocess

import pytest

INSTALLER = Path(__file__).resolve().parents[1] / "install.sh"


@pytest.fixture
def local_install(tmp_path):
    workspace = tmp_path / "source workspace"
    installer = workspace / "mn-deploy/install.sh"
    installer.parent.mkdir(parents=True)
    shutil.copyfile(INSTALLER, installer)
    for name in (
        "MirrorNeuron/Dockerfile",
        "mn-cli/Cargo.toml",
        "mn-api/Cargo.toml",
        "mn-python-sdk/packages/runtime/pyproject.toml",
        "Membrane/Dockerfile",
        "Membrane/mn-context-engine/Cargo.toml",
    ):
        path = workspace / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.touch()

    runtime = tmp_path / "account/.mn"
    runtime.mkdir(parents=True)
    commands = tmp_path / "commands"
    commands.touch()
    tools = tmp_path / "tools"
    tools.mkdir()
    # Keep host Cargo off PATH even on Ubuntu hosts with a system Cargo package.
    for name in "basename cat chmod dirname mkdir mktemp mv ps rm rmdir uname".split():
        (tools / name).symlink_to(shutil.which(name))
    cargo_home = tmp_path / "cargo home"
    cargo = cargo_home / "bin/cargo"
    cargo.parent.mkdir(parents=True)
    cargo.write_text("#!/bin/sh\nexit 0\n")
    cargo.chmod(0o755)
    for name, source in {
        "git": """#!/bin/sh
set -eu
[ "$GIT_TERMINAL_PROMPT" = 0 ]
[ "$1 $2 $3 $4" = 'clone --branch main https://github.com/MirrorNeuronLab/mn-client-support.git' ]
echo clone >> "$MN_TEST_COMMANDS"
mkdir "$5"
printf '[package]\\nname = "mn-client-support"\\n' > "$5/Cargo.toml"
exit "$MN_TEST_CLONE_STATUS"
""",
        "podman": """#!/bin/sh
command -v cargo >> "$MN_TEST_COMMANDS"
echo podman >> "$MN_TEST_COMMANDS"
exit 1
""",
    }.items():
        tool = tools / name
        tool.write_text(source)
        tool.chmod(0o755)

    def run(*args, answer="", clone_status=0):
        return subprocess.run(
            [
                "/bin/bash",
                str(installer),
                "--mode",
                "local",
                "--build-membrane",
                "--no-web-ui",
                "--no-skills",
                *args,
            ],
            env={
                "HOME": str(runtime.parent),
                "MN_HOME": str(runtime),
                "PATH": str(tools),
                "CARGO_HOME": str(cargo_home),
                "TMPDIR": str(tmp_path),
                "MN_TEST_COMMANDS": str(commands),
                "MN_TEST_CLONE_STATUS": str(clone_status),
            },
            input=answer,
            start_new_session=True,
            capture_output=True,
            text=True,
            timeout=10,
        )

    return run, workspace, runtime, commands


def test_bootstraps_missing_checkout_and_reuses_it(local_install):
    run, workspace, _, commands = local_install
    support = workspace / "mn-client-support"
    cancelled = run("--reset", answer="no\n")
    assert cancelled.returncode == 0, cancelled.stdout + cancelled.stderr
    assert not support.exists() and not commands.read_text()

    reset = run("--reset", answer="YES\n")
    assert "Reset stopped before host cleanup" in reset.stdout, (
        reset.stdout + reset.stderr
    )
    events = commands.read_text().splitlines()
    assert events[0] == "clone" and events[2] == "podman"
    assert events[1].endswith("/cargo home/bin/cargo")
    assert (support / "Cargo.toml").is_file()
    assert not list(workspace.glob(".mn-client-support.*"))

    manifest = support / "Cargo.toml"
    manifest.write_text(manifest.read_text() + "# local edit\n")
    commands.write_text("")
    reinstall = run(clone_status=1)
    events = commands.read_text().splitlines()
    assert "podman" in events and "clone" not in events, (
        reinstall.stdout + reinstall.stderr
    )
    assert manifest.read_text().endswith("# local edit\n")


@pytest.mark.parametrize("occupied", [False, True])
def test_unavailable_checkout_stops_before_reset(local_install, occupied):
    run, workspace, runtime, commands = local_install
    sentinel = runtime / "data"
    sentinel.write_text("keep")
    support = workspace / "mn-client-support"
    if occupied:
        support.mkdir()
        (support / "local-work").write_text("keep")

    result = run("--reset", answer="YES\n", clone_status=1)
    assert result.returncode != 0
    assert sentinel.read_text() == "keep"
    assert not list(workspace.glob(".mn-client-support.*"))
    if occupied:
        assert "Missing Rust client support manifest" in result.stdout
        assert (support / "local-work").read_text() == "keep"
        assert not commands.read_text()
    else:
        assert "Clone mn-client-support failed" in result.stdout
        assert not support.exists()
        assert commands.read_text().splitlines() == ["clone"]
