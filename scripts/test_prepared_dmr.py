import importlib.util
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
    monkeypatch.setattr(module, "build_archives", lambda *args, **kwargs: ("revision-policy2", {}))
    monkeypatch.setattr(module.subprocess, "run", lambda *args, **kwargs: pytest.fail("uploaded"))
    monkeypatch.setattr("sys.argv", ["publish-prepared-dmr.py", "--output", str(tmp_path)])
    module.main()
