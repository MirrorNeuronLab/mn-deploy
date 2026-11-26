"""Run the local installer up to the first Podman call with offline fixtures."""

from pathlib import Path
import shutil
import subprocess

import pytest

INSTALLER = Path(__file__).resolve().parents[1] / "install_dev.sh"


def test_development_setup_uses_local_wasm_without_replacing_the_runtime_profile(
    tmp_path,
):
    root = tmp_path / "source workspace"
    deploy = root / "mn-deploy"
    deploy.mkdir(parents=True)
    (root / "MirrorNeuron").mkdir()
    shutil.copy2(INSTALLER.with_name("setup.sh"), deploy / "setup.sh")
    home = tmp_path / "account"
    profile = home / ".mn/client.json"
    profile.parent.mkdir(parents=True)
    profile.write_text("existing connection")
    tools = tmp_path / "tools"
    tools.mkdir()
    pip = home / ".local/share/mn_venv/bin/pip"
    pip.parent.mkdir(parents=True)
    programs = {
        tools / "mix": 'test "$PWD" = "$EXPECTED_ROOT/MirrorNeuron"',
        pip: "exit 0",
        tools
        / "cargo": '''case " $* " in *" --bin mn-web-ui-server "*) ;; *) exit 20 ;; esac
while [ "$1" != --target-dir ]; do shift; done
mkdir -p "$2/release"
printf '#!/bin/sh\\nexit 0\\n' > "$2/release/mn-web-ui-server"
chmod +x "$2/release/mn-web-ui-server"''',
        deploy / "install_dev.sh": """test "$MN_ENV" = dev
test "$*" = "--no-runtime --yes"
test "$MN_CLIENT_SOURCE_ROOT" = "$EXPECTED_ROOT"
test "$HOME" != "$REAL_HOME"
test "$CARGO_HOME" = "$REAL_HOME/.cargo"
if [ -n "${NEW_PROFILE:-}" ]; then test "$MN_HOME" = "$NEW_PROFILE"
else test "$MN_HOME" != "$REAL_HOME/.mn"; fi
bin="$MN_HOME/client-current/bin"
mkdir -p "$bin"
printf '{"install_role":"client"}\n' > "$MN_HOME/install_metadata.json"
for name in mn mn-api mn-client-support; do
  printf 'local %s' "$name" > "$bin/$name.wasm"
  printf '#!/bin/sh\\nprintf "%%s" "$MN_HOME"\\n' > "$bin/$name"
  chmod +x "$bin/$name"
done""",
    }
    for path, script in programs.items():
        path.write_text("#!/bin/sh\nset -eu\n" + script + "\n")
        path.chmod(0o755)
    env = {
        "HOME": str(home),
        "SHELL": "/bin/bash",
        "PATH": f"{tools}:/usr/bin:/bin",
        "EXPECTED_ROOT": str(root),
        "REAL_HOME": str(home),
        "MN_HOME": str(profile.parent),
    }
    for _ in range(2):
        proc = subprocess.run(
            ["bash", deploy / "setup.sh"], env=env, capture_output=True, text=True
        )
        assert proc.returncode == 0, proc.stdout + proc.stderr
        for name in ("mn", "mn-api", "mn-client-support"):
            command = home / ".local/bin" / name
            assert command.resolve().with_suffix(".wasm").read_text() == "local " + name
            assert subprocess.check_output([command], env=env, text=True) == str(
                profile.parent
            )
    assert profile.read_text() == "existing connection"
    shell_rc = next(home.glob(".bash*"))
    selected = subprocess.check_output(
        ["bash", "-c", '. "$1"; command -v mn', "bash", str(shell_rc)],
        env=env,
        text=True,
    ).strip()
    assert Path(selected).resolve() == (home / ".local/bin/mn").resolve()
    fresh = tmp_path / "new client home"
    subprocess.run(
        ["bash", deploy / "setup.sh"],
        env={**env, "MN_HOME": str(fresh), "NEW_PROFILE": str(fresh)},
        check=True,
        capture_output=True,
    )
    assert (fresh / "install_metadata.json").is_file()
    assert (fresh / "client-current/bin/mn.wasm").is_file()
    assert profile.read_text() == "existing connection"


@pytest.fixture
def local_install(tmp_path):
    workspace = tmp_path / "source workspace"
    installer = workspace / "mn-deploy/install_dev.sh"
    installer.parent.mkdir(parents=True)
    shutil.copyfile(INSTALLER, installer)
    shutil.copyfile(
        INSTALLER.with_name("install.sh"), installer.with_name("install.sh")
    )
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
    for name in (
        "awk basename cat chmod cmp cp dirname ln mkdir mktemp mv ps rm rmdir uname"
    ).split():
        (tools / name).symlink_to(shutil.which(name))
    cargo_home = tmp_path / "cargo home"
    cargo = cargo_home / "bin/cargo"
    cargo.parent.mkdir(parents=True)
    cargo.write_text("""#!/bin/sh
set -eu
echo build >> "$MN_TEST_COMMANDS"
while [ "$1" != --target-dir ]; do shift; done
mkdir -p "$2/release" "$2/wasm32-wasip2/release"
for command in mn mn-api mn-client-support mn-web-ui-server; do
    printf '#!/bin/sh\nexit 0\n' > "$2/release/$command"
    cp "$2/release/$command" "$2/wasm32-wasip2/release/$command.wasm"
done
""")
    cargo.chmod(0o755)
    for name, source in {
        "wasmtime": """#!/bin/sh
case "$*" in *--print-launcher) printf '#!/bin/sh\\nexit 0\\n';; *) echo 'wasmtime 51.0.0';; esac
""",
        "git": """#!/bin/sh
set -eu
[ "$GIT_TERMINAL_PROMPT" = 0 ]
[ "$1 $2 $3 $4" = 'clone --branch main https://github.com/MirrorNeuronLab/mn-client-support.git' ]
echo clone >> "$MN_TEST_COMMANDS"
mkdir -p "$5/scripts"
printf '#!/bin/sh\\ncargo build --target-dir "$3"\\n' >"$5/scripts/build-wasm.sh"
chmod 755 "$5/scripts/build-wasm.sh"
printf '[package]\\nname = "mn-client-support"\\n' > "$5/Cargo.toml"
exit "$MN_TEST_CLONE_STATUS"
""",
        "podman": """#!/bin/sh
command -v cargo >> "$MN_TEST_COMMANDS" || :
echo podman >> "$MN_TEST_COMMANDS"
exit 1
""",
    }.items():
        tool = tools / name
        tool.write_text(source)
        tool.chmod(0o755)

    def run(*args, answer="", clone_status=0, cwd=None):
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
                "CC_wasm32_wasip2": str(cargo),
                "SHELL": "/bin/sh",
                "TMPDIR": str(tmp_path),
                "MN_TEST_COMMANDS": str(commands),
                "MN_TEST_CLONE_STATUS": str(clone_status),
            },
            input=answer,
            cwd=cwd,
            start_new_session=True,
            capture_output=True,
            text=True,
            timeout=10,
        )

    return run, workspace, runtime, commands


def test_bootstraps_missing_checkout_and_reuses_it(local_install):
    run, workspace, runtime, commands = local_install
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
    # Invoking an installer from a different checkout must build its own siblings.
    other = workspace.parent / "another workspace"
    for name in ("mn-cli", "mn-client-support"):
        (other / name).mkdir(parents=True)
        (other / name / "Cargo.toml").touch()
    reinstall = run(clone_status=1, cwd=other)
    events = commands.read_text().splitlines()
    assert events[:4] == ["build", "build", "build", "podman"], (
        reinstall.stdout + reinstall.stderr
    )
    assert "Podman setup failed" in reinstall.stdout
    assert (runtime / "bin/mn").is_file()
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
