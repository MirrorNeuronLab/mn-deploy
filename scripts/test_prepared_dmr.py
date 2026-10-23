import importlib.util
import copy
import hashlib
import io
import os
import sys
import json
from pathlib import Path
import subprocess

import pytest

from mn_sdk import resolve_model_entry
from mn_sdk.dmr_archive import extract_archive
from mn_sdk.dmr_recipe import preparation_recipe, managed_runner_version


def publisher():
    spec = importlib.util.spec_from_file_location("prepared_dmr", Path(__file__).with_name("publish-prepared-dmr.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_publisher_builds_pinned_cross_platform_archives(monkeypatch, tmp_path):
    module = publisher()
    recipe = preparation_recipe(resolve_model_entry("small"))
    commands, patches = [], []
    monkeypatch.setattr(module, "patch_managed_server", patches.append)
    def run(command, **kwargs):
        commands.append((command, kwargs))
        output = ""
        if command[:2] == ["git", "init"]:
            source = Path(command[2])
            source.mkdir()
            (source / "LICENSE").write_text("upstream license")
        if command[-2:] == ["rev-parse", "HEAD"]:
            output = recipe.document["runner"]["revision"]
        if command == ["go", "version"]:
            output = "go version go1.27.2 test"
        if command[:2] == ["go", "build"]:
            Path(command[command.index("-o") + 1]).write_bytes(b"native runner")
            assert kwargs["env"]["CGO_ENABLED"] == "0"
            assert managed_runner_version(recipe) in command[command.index("-ldflags") + 1]
        return subprocess.CompletedProcess(command, 0, output, "")
    output = tmp_path / "release"
    version, definition = module.build_archives(recipe, output, project="project", location="us-central1",
                                              repository="binaries", run=run)
    assert len(patches) == 1
    assert len([command for command, _ in commands if command[:2] == ["go", "build"]]) == len(definition["assets"]) == 4
    assert definition == json.loads((output / "runner-assets.json").read_text())
    for platform, asset in definition["assets"].items():
        destination = tmp_path / platform
        extract_archive(output / asset["name"], destination)
        binary = destination / ("model-runner.exe" if platform.startswith("windows") else "model-runner")
        assert binary.read_bytes() == b"native runner"
        assert json.loads((destination / "runner-build.json").read_text())["revision"] == recipe.document["runner"]["revision"]
        assert (destination / "LICENSE").read_text() == "upstream license"
        assert f"managed-dmr%3A{version}%3A" in asset["url"]
    with pytest.raises(ValueError, match="immutable"):
        module.build_archives(recipe, output, project="project", location="us-central1", repository="binaries", run=run)


def test_publisher_does_not_upload_without_apply(monkeypatch, tmp_path):
    module = publisher()
    recipe, directory, document = saved_release(module, tmp_path)
    monkeypatch.setattr(module, "build_archives", lambda *args, **kwargs: ("revision-policy2", document))
    monkeypatch.setattr(module.subprocess, "run", lambda *args, **kwargs: pytest.fail("uploaded"))
    monkeypatch.setattr("sys.argv", ["publish-prepared-dmr.py", "--output", str(tmp_path)])
    module.main()


DESTINATION = {"project": "mirrorneuron-public-packages", "location": "us-central1", "repository": "mirrorneuron-binaries"}


def saved_release(module, directory):
    recipe = preparation_recipe(resolve_model_entry("small"))
    document = copy.deepcopy(recipe.document["runner"])
    directory.mkdir(parents=True, exist_ok=True)
    for platform, asset in document["assets"].items():
        content = ("synthetic native archive " + platform).encode()
        (directory / asset["name"]).write_bytes(content)
        asset["sha256"] = hashlib.sha256(content).hexdigest()
    (directory / "runner-assets.json").write_text(json.dumps(document))
    return recipe, directory, document


@pytest.mark.parametrize("damage", ["bytes", "name", "revision", "symlink"])
def test_saved_release_is_validated_before_publication(tmp_path, damage):
    module = publisher()
    recipe, directory, document = saved_release(module, tmp_path)
    asset = next(iter(document["assets"].values()))
    path = directory / asset["name"]
    if damage == "bytes":
        path.write_bytes(b"modified")
    elif damage == "name":
        asset["name"] = "../private-file.tar.gz"
    elif damage == "revision":
        document["revision"] = "0" * 40
    else:
        content = path.read_bytes()
        path.unlink()
        target = directory / "private"
        target.write_bytes(content)
        path.symlink_to(target)
    with pytest.raises(ValueError):
        module.validate_release(recipe, directory, document, **DESTINATION)


def test_restore_requires_current_catalog_checksums(tmp_path):
    module = publisher()
    recipe, directory, document = saved_release(module, tmp_path)
    module.validate_release(recipe, directory, document, **DESTINATION)
    with pytest.raises(ValueError, match="pinned assets"):
        module.validate_release(recipe, directory, document, match_catalog=True, **DESTINATION)


def test_upload_is_repeatable_and_contains_only_verified_release_files(monkeypatch, tmp_path):
    module = publisher()
    recipe, directory, document = saved_release(module, tmp_path / "saved")
    (directory / "private-notes.txt").write_text("must not be uploaded")
    version = module.validate_release(recipe, directory, document, **DESTINATION)
    uploads, checks = [], []
    def run(command, **options):
        assert "--skip-existing" in command and options == {"check": True}
        path = Path(next(value.split("=", 1)[1] for value in command if value.startswith("--source-directory=")))
        assert {p.name for p in path.iterdir()} == {"runner-assets.json", *[a["name"] for a in document["assets"].values()]}
        assert json.loads((path / "runner-assets.json").read_text()) == document
        uploads.append(path)
    monkeypatch.setattr(module, "verify_public_release", lambda *args: checks.append(args))
    for _ in range(2):
        module.publish_release(directory, document, version, run=run, **DESTINATION)
    assert len(uploads) == len(checks) == 2
    assert all(not path.exists() for path in uploads)


def test_archive_changed_after_validation_is_not_uploaded(monkeypatch, tmp_path):
    module = publisher()
    recipe, directory, document = saved_release(module, tmp_path)
    version = module.validate_release(recipe, directory, document, **DESTINATION)
    (directory / next(iter(document["assets"].values()))["name"]).write_bytes(b"changed")
    with pytest.raises(ValueError, match="changed before publication"):
        module.publish_release(directory, document, version,
            run=lambda *a, **k: pytest.fail("uploaded changed bytes"), **DESTINATION)


@pytest.mark.parametrize("damage", [None, "bytes", "oversized", "short", "status"])
def test_public_verification_reads_anonymous_complete_archives(tmp_path, damage):
    module = publisher()
    _, directory, document = saved_release(module, tmp_path)
    calls = []
    class Response(io.BytesIO):
        status = 503 if damage == "status" else 200
    def open_url(url, **options):
        assert options == {"timeout": 60}  # No credentials are supplied.
        calls.append(url)
        asset = next(a for a in document["assets"].values() if a["url"] == url)
        content = (directory / asset["name"]).read_bytes()
        if damage == "bytes": content = b"x" * len(content)
        if damage == "oversized": content += b"extra"
        if damage == "short": content = content[:-1]
        return Response(content)
    if damage:
        with pytest.raises(ValueError):
            module.verify_public_release(directory, document, open_url=open_url)
    else:
        module.verify_public_release(directory, document, open_url=open_url)
        assert len(calls) == 4


def test_cli_reuses_saved_archives_without_rebuilding(monkeypatch, tmp_path):
    module = publisher()
    recipe, directory, document = saved_release(module, tmp_path)
    models, published = [], []
    monkeypatch.setattr(module, "resolve_model_entry", lambda model: models.append(model) or {})
    monkeypatch.setattr(module, "preparation_recipe", lambda _: recipe)
    monkeypatch.setattr(module, "build_archives", lambda *a, **k: pytest.fail("rebuilt saved archives"))
    monkeypatch.setattr(module, "publish_release", lambda *a, **k: published.append((a, k)))
    monkeypatch.setattr(sys, "argv", ["publish-prepared-dmr.py", "--model", "bonsai2:ptq1_0", "--from-directory", str(directory)])
    module.main()
    assert not published
    monkeypatch.setattr(sys, "argv", [*sys.argv, "--apply"])
    module.main()
    assert models == ["bonsai2:ptq1_0"] * 2
    assert len(published) == 1


def test_restore_wrapper_uses_selected_python_and_preserves_arguments(tmp_path):
    python = tmp_path / "selected python"
    output = tmp_path / "arguments.json"
    python.write_text(f"#!{sys.executable}\nimport json,os,sys\nfrom pathlib import Path\nPath({str(output)!r}).write_text(json.dumps([sys.argv[1:],os.environ['CLOUDSDK_PYTHON']]))\n")
    python.chmod(0o755)
    wrapper = Path(__file__).with_name("publish-dmr.sh")
    env = {**os.environ, "MN_PUBLISH_PYTHON": str(python)}
    env.pop("CLOUDSDK_PYTHON", None)
    result = subprocess.run(["bash", str(wrapper), "--from-directory", "archive path with spaces", "--apply"],
        env=env, capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stderr
    arguments, cloud_python = json.loads(output.read_text())
    assert arguments == [str(wrapper.with_name("publish-prepared-dmr.py")), "--match-catalog",
                         "--from-directory", "archive path with spaces", "--apply"]
    assert cloud_python == str(python)
