"""Exercise the public deployment commands from outside the deploy checkout."""

import os
from pathlib import Path
import subprocess
import sys
import zipfile

import pytest


SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"


def run(cwd, *args, **env):
    return subprocess.run(
        args,
        cwd=cwd,
        env={**os.environ, "MN_PUBLISH_PYTHON": sys.executable, **env},
        capture_output=True,
        text=True,
        timeout=20,
    )


@pytest.mark.parametrize("script", ["release.sh", "publish.sh", "artifacts.sh"])
def test_command_requires_an_explicit_action(script, tmp_path):
    entry = SCRIPTS / script
    help_result = run(tmp_path, entry, "--help")
    assert help_result.returncode == 0 and script in help_result.stdout
    default = run(tmp_path, entry)
    assert default.returncode == 0 and default.stdout == help_result.stdout
    assert run(tmp_path, entry, "../unknown", "--apply").returncode == 2
    assert not list(tmp_path.iterdir())


@pytest.mark.parametrize(
    ("script", "action", "option"),
    [
        ("release.sh", "all", "--resume-from"),
        ("release.sh", "changed", "--publish-scripts"),
        ("release.sh", "check-runtime", "--two-runtimes"),
        ("publish.sh", "clients", "--from-tag"),
        ("publish.sh", "core", "--core-dir"),
        ("publish.sh", "membrane", "--skip-binary"),
        ("publish.sh", "otterdesk", "--otterdesk-dir"),
        ("publish.sh", "python", "--no-prune"),
        ("publish.sh", "web-ui", "--web-ui-dir"),
        ("publish.sh", "dmr", "--from-directory"),
        ("publish.sh", "computer-use", "--skills-dir"),
    ],
)
def test_action_passes_options_to_its_own_handler(script, action, option, tmp_path):
    result = run(tmp_path, SCRIPTS / script, action, "--help")
    assert result.returncode == 0, result.stderr
    assert option in result.stdout


def test_registry_setup_example_reaches_python_publisher(tmp_path):
    old_path = SCRIPTS / "publish_python_packages_to_google_artifact_registry.sh"
    setup = (SCRIPTS.parent / "setup_google_artifact_registry.sh").read_text()
    assert f"./scripts/{old_path.name} --apply" in setup
    example = run(tmp_path, old_path, "--help")
    canonical = run(tmp_path, SCRIPTS / "publish.sh", "python", "--help")
    assert example.returncode == canonical.returncode == 0
    assert example.stdout == canonical.stdout


def test_tag_writes_ci_outputs_after_validation(tmp_path):
    output = tmp_path / "output"
    envfile = tmp_path / "env"
    env = dict(
        GITHUB_OUTPUT=str(output),
        GITHUB_ENV=str(envfile),
        GITHUB_REF_NAME="v1.2.3-rc.1",
    )
    result = run(tmp_path, SCRIPTS / "artifacts.sh", "tag", **env)
    assert result.returncode == 0, result.stderr
    assert output.read_text().splitlines() == [
        "tag_name=v1.2.3-rc.1",
        "version=1.2.3-rc.1",
        "is_prerelease=true",
    ]
    assert envfile.read_text().splitlines() == [
        "TAG_NAME=v1.2.3-rc.1",
        "VERSION=1.2.3-rc.1",
        "IS_PRERELEASE=true",
    ]
    before = (output.read_bytes(), envfile.read_bytes())
    assert run(tmp_path, SCRIPTS / "artifacts.sh", "tag", "v01.2.3", **env).returncode
    assert before == (output.read_bytes(), envfile.read_bytes())


def test_archive_and_check_work_together_in_another_checkout(tmp_path):
    repo = tmp_path / "sample"
    docs = repo / "docs"
    docs.mkdir(parents=True)
    (docs / "read me.txt").write_text("release")
    (repo / "dist").mkdir()
    (repo / "dist" / "old.txt").write_text("previous build")
    subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
    subprocess.run(["git", "add", "-f", "docs", "dist"], cwd=repo, check=True)
    output = tmp_path / "output with spaces"
    command = [SCRIPTS / "artifacts.sh", "zip", "v1.2.3", output]
    result = run(docs, *command)
    assert result.returncode == 0, result.stderr
    archive = Path(result.stdout.strip())
    assert archive == output / "sample-v1.2.3.zip"
    with zipfile.ZipFile(archive) as z:
        assert z.namelist() == ["sample-v1.2.3/docs/read me.txt"]
    assert run(docs, *command).returncode
    check = [SCRIPTS / "artifacts.sh", "check"]
    assert run(docs, *check, archive).returncode == 0
    with zipfile.ZipFile(archive, "a") as z:
        z.writestr("node_modules/unwanted", "")
    assert run(docs, *check, archive).returncode
    archive.write_bytes(b"unreadable ZIP")
    assert run(docs, *check, archive).returncode
    assert run(docs, *check, tmp_path / "missing").returncode
