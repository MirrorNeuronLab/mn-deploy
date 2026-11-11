"""Offline component repair contracts; all repositories and registry calls are isolated."""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tomllib
import zipfile

import pytest


def module(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name))
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


repair = module("update-changed-components.py")
indexer = module("prepare-python-package-index.py")


def git(repo, *args):
    return subprocess.check_output(["git", "-C", str(repo), *args], text=True).strip()


def commit(repo):
    git(repo, "add", ".")
    git(repo, "commit", "-qm", "fixture")


def add_remote(repo):
    remote = repo.parent / f"{repo.name}.git"
    git(repo, "init", "--bare", "--initial-branch=main", "-q", str(remote))
    git(repo, "remote", "add", "origin", str(remote))
    git(repo, "push", "-q", "origin", "main")
    return remote


@pytest.fixture
def workspace(tmp_path):
    for name in ("mn-api", "mn-web-ui", "MirrorNeuron", "Membrane", "mn-deploy"):
        repo = tmp_path / name
        repo.mkdir()
        git(repo, "init", "--initial-branch=main", "-q")
        git(repo, "config", "user.email", "test@example.invalid")
        git(repo, "config", "user.name", "Test")
        (repo / "source.txt").write_text("original\n")
    api = tmp_path / "mn-api"
    (api / "pyproject.toml").write_text(
        '[project]\nname = "mirrorneuron-api"\nversion = "1.0.0"\n'
    )
    (tmp_path / "mn-web-ui/package.json").write_text(
        '{"name":"mirrorneuron-web-ui","version":"0.0.1"}'
    )
    for name in ("mn-api", "mn-web-ui", "MirrorNeuron", "Membrane"):
        commit(tmp_path / name)
        git(tmp_path / name, "tag", "v1.3.60")
    deploy = tmp_path / "mn-deploy"
    settings = [
        "CORE",
        "WEB_UI",
        "MEMBRANE_CONTEXT_ENGINE",
        "INSTALL",
        "INSTALL_SUPPORT",
        "AGENT_PACKAGE_INDEX",
    ]
    source = "".join(
        f'MN_DEFAULT_{name}_VERSION="${{MN_DEFAULT_{name}_VERSION:-v1.3.60}}"\n'
        for name in settings
    )
    source += "".join(
        f'MN_DEFAULT_{name}_VERSION="${{MN_DEFAULT_{name}_VERSION:-v1.0.0}}"\n'
        for name in ("PYTHON_SDK", "CLI", "API")
    )
    (deploy / "install.sh").write_text(source)
    (deploy / "uninstall.sh").write_text("#!/bin/bash\n# Updated uninstaller\n")
    (deploy / "uninstall.sh").chmod(0o755)
    (deploy / "docker-compose.yml").write_text(
        "MN_WEB_UI_PACKAGE_VERSION: ${MN_WEB_UI_PACKAGE_VERSION:-1.3.60}\n"
    )
    (deploy / "package-index").mkdir()
    fingerprint = indexer.source_fingerprint(tmp_path, "mn-api")
    (deploy / "package-index/python-packages.toml").write_text(
        '[[packages]]\nname = "mirrorneuron-api"\npath = "mn-api"\nversion = "1.0.0"\n'
        f'source_hash = "{fingerprint}"\nbuild_formats = ["wheel"]\n'
    )
    (deploy / "install_support/v1.3.60").mkdir(parents=True)
    (deploy / "install_support/v1.3.60/historical").write_text("immutable")
    commit(deploy)
    git(deploy, "tag", "v1.3.60")
    return tmp_path


def change(root, *repos):
    for name in repos:
        (root / name / "source.txt").write_text("fixed\n")
        commit(root / name)


def test_preview_plans_only_changed_versions_without_source_writes(workspace):
    change(workspace, "mn-api", "mn-web-ui", "MirrorNeuron", "Membrane")
    before = {
        str(p): p.read_bytes()
        for p in workspace.rglob("*")
        if p.is_file() and ".git" not in p.parts
    }
    planned = repair.plan(workspace, {"python", "web-ui", "core", "membrane"})
    assert planned["core"] == planned["runtime"] == "v1.3.60"
    assert [(p["name"], p["version"]) for p in planned["packages"]] == [
        ("mirrorneuron-api", "1.0.1")
    ]
    assert [(c["kind"], c["version"]) for c in planned["components"]] == [
        ("web-ui", "v1.3.61"),
        ("core", "v1.3.60"),
        ("membrane", "v1.3.60"),
    ]
    assert (
        repair.default(planned["installer"], "MN_DEFAULT_INSTALL_SUPPORT_VERSION")
        == "v1.3.61"
    )
    assert (
        repair.default(planned["installer"], "MN_DEFAULT_AGENT_PACKAGE_INDEX_VERSION")
        == "v1.3.61"
    )
    assert repair.default(planned["installer"], "MN_DEFAULT_API_VERSION") == "v1.0.1"
    assert before == {
        str(p): p.read_bytes()
        for p in workspace.rglob("*")
        if p.is_file() and ".git" not in p.parts
    }


def test_no_changes_and_dirty_source_guard(workspace):
    planned = repair.plan(workspace, {"python", "web-ui", "core", "membrane"})
    assert not planned["packages"] and not planned["components"]
    (workspace / "mn-api/source.txt").write_text("pending")
    planned = repair.plan(workspace, {"python"})
    assert planned["dirty"] == ["mn-api"]
    with pytest.raises(RuntimeError, match="Uncommitted changes"):
        repair.ensure_sources(workspace, planned)


def test_completed_update_keeps_tags_snapshots_and_does_not_bump_again(workspace):
    change(workspace, "mn-api", "mn-web-ui", "MirrorNeuron", "Membrane")
    repos = ("mn-api", "mn-web-ui", "MirrorNeuron", "Membrane")
    tags = {r: git(workspace / r, "rev-parse", "v1.3.60") for r in repos}
    planned = repair.plan(workspace, {"python", "web-ui", "core", "membrane"})
    repair.finish(workspace, planned)
    deploy = workspace / "mn-deploy"
    assert (deploy / "install_support/v1.3.60/historical").read_text() == "immutable"
    assert (
        deploy / "install_support/v1.3.61/package-index/python-packages.toml"
    ).read_text() == planned["index"]
    assert (
        deploy / "install_support/v1.3.61/docker-compose.yml"
    ).read_text() == planned["compose"]
    assert tags == {r: git(workspace / r, "rev-parse", "v1.3.60") for r in repos}
    assert (
        tomllib.loads((workspace / "mn-api/pyproject.toml").read_text())["project"][
            "version"
        ]
        == "1.0.1"
    )
    commit(workspace / "mn-api")
    again = repair.plan(workspace, {"python", "web-ui", "core", "membrane"})
    assert not again["packages"] and not again["components"]
    commit(deploy)
    contract = module("release-contract.py")
    assert contract.next_release(workspace, ["mn-deploy"]) == "1.3.62"


def test_concurrent_source_or_installer_edits_abort(workspace):
    change(workspace, "mn-api")
    planned = repair.plan(workspace, {"python"})
    (workspace / "mn-api/source.txt").write_text("another fix\n")
    commit(workspace / "mn-api")
    with pytest.raises(RuntimeError, match="changed during preparation"):
        repair.ensure_sources(workspace, planned)


def test_concurrent_metadata_edits_prevent_finalization(workspace):
    change(workspace, "mn-api")
    planned = repair.plan(workspace, {"python"})
    installer = workspace / "mn-deploy/install.sh"
    installer.write_text(installer.read_text() + "# concurrent change\n")
    with pytest.raises(RuntimeError, match="install.sh changed"):
        repair.finish(workspace, planned)
    assert not (workspace / "mn-deploy/install_support/v1.3.61").exists()
    assert (
        tomllib.loads((workspace / "mn-api/pyproject.toml").read_text())["project"][
            "version"
        ]
        == "1.0.0"
    )


def test_python_build_stages_static_version_and_preserves_original(
    workspace, tmp_path, monkeypatch
):
    change(workspace, "mn-api")
    planned = repair.plan(workspace, {"python"})
    directory = tmp_path / "artifacts"
    directory.mkdir()
    builds = []

    def fake_run(*args, **kwargs):
        if args[1:3] == ("-m", "build"):
            project = Path(args[3])
            assert project != workspace / "mn-api"
            version = tomllib.loads((project / "pyproject.toml").read_text())[
                "project"
            ]["version"]
            assert version == "1.0.1"
            builds.append(version)
            artifacts = Path(args[args.index("--outdir") + 1])
            wheel = artifacts / "mirrorneuron_api-1.0.1-py3-none-any.whl"
            with zipfile.ZipFile(wheel, "w") as archive:
                archive.writestr(
                    "mirrorneuron_api-1.0.1.dist-info/METADATA",
                    "Metadata-Version: 2.1\nName: mirrorneuron-api\nVersion: 1.0.1\n",
                )

    monkeypatch.setattr(repair, "run", fake_run)
    repair.build_python(workspace, planned, directory)
    repair.build_python(workspace, planned, directory)
    next_directory = tmp_path / "another-release-plan"
    next_directory.mkdir()
    repair.build_python(workspace, planned, next_directory)
    assert builds == ["1.0.1"]  # Retry uses the same artifact bytes.
    assert (next_directory / "python-ready.json").read_bytes() == (
        directory / "python-ready.json"
    ).read_bytes()
    assert git(workspace / "mn-api", "status", "--porcelain") == ""
    assert (
        tomllib.loads((workspace / "mn-api/pyproject.toml").read_text())["project"][
            "version"
        ]
        == "1.0.0"
    )


def cached_build(directory, package, payload):
    artifacts = directory / "python"
    artifacts.mkdir(parents=True)
    (directory / "index.toml").write_text(
        "[[packages]]\n"
        + "".join(f"{key} = {json.dumps(value)}\n" for key, value in package.items())
    )
    prefix = package["name"].replace("-", "_") + "-" + package["version"]
    files = [
        artifacts / (prefix + suffix)
        for fmt, suffix in (("sdist", ".tar.gz"), ("wheel", "-py3-none-any.whl"))
        if fmt in (package.get("build_formats") or ["sdist", "wheel"])
    ]
    for path in files:
        path.write_bytes(payload + path.suffix.encode())
    (directory / "python-ready.json").write_text(
        json.dumps(
            {
                str(p.relative_to(directory)): hashlib.sha256(
                    p.read_bytes()
                ).hexdigest()
                for p in files
            }
        )
    )
    return files


@pytest.mark.parametrize("constrained", [False, True])
def test_retry_plan_advances_changed_cached_source_and_checks_dependencies(
    workspace, constrained
):
    project = workspace / "mn-api/pyproject.toml"
    if constrained:
        project.write_text(
            project.read_text() + 'dependencies = ["mirrorneuron-api<1.0.2"]\n'
        )
    change(workspace, "mn-api")
    initial = repair.plan(workspace, {"python"})
    cache = workspace / "mn-deploy/dist/component-updates"
    cached_build(cache / "initial", initial["packages"][0], b"first build")
    # An unrelated release-plan change keeps the same package version/build.
    assert repair.plan(workspace, {"python"})["packages"] == initial["packages"]
    (workspace / "mn-api/source.txt").write_text("another source change\n")
    commit(workspace / "mn-api")
    before = project.read_bytes()
    if constrained:
        with pytest.raises(SystemExit, match="No compatible stable version"):
            repair.plan(workspace, {"python"})
    else:
        updated = repair.plan(workspace, {"python"})
        assert updated["packages"][0]["version"] == "1.0.2"
        assert 'version = "1.0.2"' in updated["metadata"]["mn-api/pyproject.toml"]
        cached_build(cache / "updated", updated["packages"][0], b"second build")
        assert repair.plan(workspace, {"python"})["packages"] == updated["packages"]
    assert project.read_bytes() == before


def test_retry_plan_ignores_unbuilt_inventory_entries(workspace):
    change(workspace, "mn-api")
    initial = repair.plan(workspace, {"python"})
    cache = workspace / "mn-deploy/dist/component-updates/initial"
    cached_build(cache, initial["packages"][0], b"first build")
    (cache / "python-ready.json").write_text("{}")
    (workspace / "mn-api/source.txt").write_text("another source change\n")
    commit(workspace / "mn-api")
    assert repair.plan(workspace, {"python"})["packages"][0]["version"] == "1.0.1"


def test_reserved_component_version_advances_the_entire_sdk_group(tmp_path):
    packages = []
    for name, relative in [
        ("mirrorneuron-python-sdk", "mn-python-sdk"),
        ("mn-python-sdk-common", "mn-python-sdk/packages/common"),
    ]:
        project = tmp_path / relative
        project.mkdir(parents=True)
        (project / "pyproject.toml").write_text(
            f'[project]\nname = "{name}"\ndynamic = ["version"]\n'
        )
        packages.append(
            dict(name=name, path=relative, version="1.0.1", source_hash="v2:new")
        )
    cache = tmp_path / "mn-deploy/dist/component-updates/previous"
    cached_build(cache, {**packages[1], "source_hash": "v2:old"}, b"old component")
    index = tmp_path / "index.toml"
    index.write_text(
        "".join(
            "[[packages]]\n"
            + "".join(f"{key} = {json.dumps(value)}\n" for key, value in p.items())
            for p in packages
        )
    )
    previous = [{**p, "version": "1.0.0"} for p in packages]
    repair.avoid_cached_python_versions(index, previous, tmp_path, indexer)
    assert [p["version"] for p in tomllib.loads(index.read_text())["packages"]] == [
        "1.0.2",
        "1.0.2",
    ]


@pytest.mark.parametrize("partial", [False, True])
def test_rebuilt_retry_restores_exact_published_build(tmp_path, monkeypatch, partial):
    package = dict(
        name="mirrorneuron-api", path="mn-api", version="1.0.1", source_hash="v2:source"
    )
    original = cached_build(tmp_path / "original", package, b"published build")
    directory = tmp_path / "retry"
    rebuilt = cached_build(directory, package, b"rebuilt with different timestamps")
    remote = {
        p.name: {
            "hashes": [
                {"type": "SHA256", "value": hashlib.sha256(p.read_bytes()).hexdigest()}
            ]
        }
        for p in (original[:1] if partial else original)
    }
    args = argparse.Namespace(
        gcloud="fake-gcloud",
        project="project",
        location="us-central1",
        python_repository="python",
    )
    uploads = []

    def fake_run(*command, **kwargs):
        if command[1:4] == ("artifacts", "files", "list"):
            return json.dumps(
                [{"name": "pkg%2F" + name, **row} for name, row in remote.items()]
            )
        assert command[1:4] == ("-m", "twine", "upload")
        missing = [p for p in rebuilt if p.name not in remote]
        assert missing and all(p in command for p in missing)
        assert all(p not in command for p in rebuilt if p.name in remote)
        for path in missing:
            assert path.read_bytes() == (original[0].parent / path.name).read_bytes()
            remote[path.name] = {
                "hashes": [
                    {
                        "type": "SHA256",
                        "value": hashlib.sha256(path.read_bytes()).hexdigest(),
                    }
                ]
            }
        uploads.append(missing)

    monkeypatch.setattr(repair, "run", fake_run)
    for _ in range(2):
        repair.publish_python(args, {"packages": [package]}, directory)
    assert len(uploads) == int(partial)
    expected = json.loads((directory / "python-ready.json").read_text())
    for old, new in zip(original, rebuilt, strict=True):
        assert old.read_bytes() == new.read_bytes()
        assert (
            expected[str(new.relative_to(directory))]
            == hashlib.sha256(new.read_bytes()).hexdigest()
        )


@pytest.mark.parametrize(
    "problem",
    [
        "source",
        "version",
        "formats",
        "checksum",
        "missing",
        "manifest",
        "no-fingerprint",
    ],
)
def test_python_build_cache_rejects_unverified_or_different_inputs(tmp_path, problem):
    package = dict(
        name="mirrorneuron-api", path="mn-api", version="1.0.1", source_hash="v2:source"
    )
    cached_package = {**package}
    if problem == "source":
        cached_package["source_hash"] = "v2:different"
    elif problem == "version":
        cached_package["version"] = "1.0.2"
    elif problem == "formats":
        cached_package["build_formats"] = ["wheel"]
    elif problem == "no-fingerprint":
        del package["source_hash"]
        del cached_package["source_hash"]
    directory = tmp_path / "previous"
    files = cached_build(directory, cached_package, b"original")
    if problem == "checksum":
        files[0].write_bytes(b"tampered")
    elif problem == "missing":
        files[0].unlink()
    elif problem == "manifest":
        (directory / "python-ready.json").write_text("{}")
    assert list(repair.cached_python_builds(package, tmp_path / "next")) == []


def test_python_upload_scope_hash_verification_and_retry(tmp_path, monkeypatch):
    directory = tmp_path / "artifacts"
    artifacts = directory / "python"
    artifacts.mkdir(parents=True)
    wheel = artifacts / "mirrorneuron_api-1.0.1-py3-none-any.whl"
    wheel.write_bytes(b"validated fixture artifact")
    sdist = artifacts / "mirrorneuron_api-1.0.1.tar.gz"
    sdist.write_bytes(b"validated fixture source distribution")
    calls = []
    remote = []
    args = argparse.Namespace(
        gcloud="fake-gcloud",
        project="project",
        location="us-central1",
        python_repository="python",
    )
    planned = {"packages": [{"name": "mirrorneuron-api", "version": "1.0.1"}]}

    def fake_run(*command, **kwargs):
        calls.append(command)
        if command[1:4] == ("artifacts", "files", "list"):
            assert (
                "--version=1.0.1" in command and "--package=mirrorneuron-api" in command
            )
            return json.dumps(remote)
        assert command[1:4] == ("-m", "twine", "upload")
        assert wheel in command and sdist in command
        for artifact in (wheel, sdist):
            remote.append(
                {
                    "name": "projects/project/locations/us-central1/repositories/python/files/pkg%2F"
                    + artifact.name,
                    "hashes": [
                        {
                            "type": "SHA256",
                            "value": hashlib.sha256(artifact.read_bytes()).hexdigest(),
                        }
                    ],
                }
            )

    monkeypatch.setattr(repair, "run", fake_run)
    repair.publish_python(args, planned, directory)
    repair.publish_python(args, planned, directory)
    assert sum(c[1:4] == ("-m", "twine", "upload") for c in calls) == 1
    assert all("delete" not in c for c in calls)
    remote[0]["hashes"][0]["value"] = "different-content"
    with pytest.raises(
        RuntimeError, match="SHA-256 expected .*reported different-content"
    ):
        repair.publish_python(args, planned, directory)


@pytest.mark.parametrize("missing", ["file", "hash"])
def test_python_verification_reports_missing_file_or_checksum(tmp_path, missing):
    artifact = tmp_path / "fixture.tar.gz"
    artifact.write_bytes(b"fixture")
    remote = (
        {}
        if missing == "file"
        else {artifact.name: {"hashes": [{"type": "MD5", "value": "unused"}]}}
    )
    with pytest.raises(
        RuntimeError,
        match="file missing" if missing == "file" else "reported unavailable",
    ):
        repair.verify_python_artifact("fixture", artifact, remote)


def test_conflicting_existing_artifact_stops_before_uploading_missing_file(
    tmp_path, monkeypatch
):
    artifacts = tmp_path / "python"
    artifacts.mkdir()
    wheel = artifacts / "mirrorneuron_api-1.0.1-py3-none-any.whl"
    wheel.write_bytes(b"local build")
    (artifacts / "mirrorneuron_api-1.0.1.tar.gz").write_bytes(b"missing distribution")
    args = argparse.Namespace(
        gcloud="fake-gcloud",
        project="project",
        location="us-central1",
        python_repository="python",
    )
    planned = {"packages": [{"name": "mirrorneuron-api", "version": "1.0.1"}]}
    calls = []

    def fake_run(*command, **kwargs):
        calls.append(command)
        assert command[1:4] == ("artifacts", "files", "list")
        return json.dumps(
            [
                {
                    "name": "pkg%2F" + wheel.name,
                    "hashes": [{"type": "SHA256", "value": "0" * 64}],
                }
            ]
        )

    monkeypatch.setattr(repair, "run", fake_run)
    with pytest.raises(RuntimeError, match="SHA-256 expected"):
        repair.publish_python(args, planned, tmp_path)
    assert len(calls) == 1


@pytest.mark.parametrize(
    "kind, repo", [("core", "MirrorNeuron"), ("membrane", "Membrane")]
)
def test_image_repair_builds_head_and_keeps_existing_version_tags(
    workspace, tmp_path, monkeypatch, kind, repo
):
    change(workspace, repo)
    component = repair.plan(workspace, {kind})["components"][0]
    args = argparse.Namespace(
        gcloud="fake-gcloud",
        docker="fake-docker",
        project="project",
        location="us-central1",
        docker_repository="runtime",
        qemu="never",
        platforms="linux/amd64,linux/arm64",
        update_latest=False,
    )
    calls = []
    original_run = repair.run

    def fake_run(*command, **kwargs):
        if command[0] == "git":
            return original_run(*command, **kwargs)
        calls.append(command)
        if command[1:3] == ("buildx", "build"):
            staged = Path(command[-1])
            assert staged != workspace / repo
            assert (staged / "source.txt").read_text() == "fixed\n"
            assert ":latest" not in " ".join(command)
            assert (
                "--target" in command
                if kind == "membrane"
                else "--build-arg" in command
            )
            tags = [
                command[i + 1] for i, value in enumerate(command) if value == "--tag"
            ]
            assert {tag.rsplit(":", 1)[-1] for tag in tags} == {"v1.3.60", "1.3.60"}
            Path(command[command.index("--metadata-file") + 1]).write_text(
                '{"containerimage.digest":"sha256:fixture"}'
            )
        elif command[1:4] == ("buildx", "imagetools", "inspect"):
            return '{"digest":"sha256:fixture"}'

    monkeypatch.setattr(repair, "run", fake_run)
    directory = tmp_path / "images"
    directory.mkdir()
    repair.publish_component(args, workspace, component, directory)
    assert all(
        "delete" not in call and "add-iam-policy-binding" not in call for call in calls
    )
    assert git(workspace / repo, "status", "--porcelain") == ""


def test_failed_upload_keeps_installer_and_source_versions_unmodified(
    workspace, monkeypatch
):
    change(workspace, "mn-api")
    add_remote(workspace / "mn-deploy")
    installer = workspace / "mn-deploy/install.sh"
    before = installer.read_bytes()
    original_run = repair.run

    def fake_run(*command, **kwargs):
        if command[0] == "git":
            return original_run(*command, **kwargs)
        if command[1:4] == ("artifacts", "repositories", "describe"):
            return '{"format":"PYTHON","mode":"STANDARD_REPOSITORY"}'
        return "private-token"

    def failed_upload(*args):
        raise RuntimeError("upload failed")

    monkeypatch.setattr(repair, "run", fake_run)
    monkeypatch.setattr(repair, "build_python", lambda *args: None)
    monkeypatch.setattr(repair, "publish_python", failed_upload)
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "update-changed-components.py",
            "--apply",
            "--only",
            "python",
            "--workspace-root",
            str(workspace),
        ],
    )
    with pytest.raises(RuntimeError, match="upload failed"):
        repair.main()
    assert installer.read_bytes() == before
    assert (
        tomllib.loads((workspace / "mn-api/pyproject.toml").read_text())["project"][
            "version"
        ]
        == "1.0.0"
    )
    assert not (workspace / "mn-deploy/install_support/v1.3.61").exists()


@pytest.mark.parametrize(
    "publish,cleanup,failure",
    [
        (False, False, None),
        (True, False, None),
        (True, True, "mn-deploy"),
        (True, True, "mn-website"),
        (True, True, "delete"),
    ],
)
def test_apply_pushes_only_release_files_and_resumes_before_cleanup(
    workspace, monkeypatch, publish, cleanup, failure
):
    change(workspace, "mn-api", "mn-web-ui", "MirrorNeuron")
    deploy = workspace / "mn-deploy"
    website = workspace / "mn-website"
    (website / "public").mkdir(parents=True)
    git(website, "init", "--initial-branch=main", "-q")
    git(website, "config", "user.email", "test@example.invalid")
    git(website, "config", "user.name", "Test")
    for name in repair.INSTALL_SCRIPTS:
        (website / "public" / name).write_text("previous\n")
    commit(website)
    deploy_remote = add_remote(deploy)
    website_remote = add_remote(website)
    for repo in (deploy, website):
        (repo / "unrelated.txt").write_text("staged\n")
        git(repo, "add", "unrelated.txt")
    monkeypatch.setattr(repair, "WEBSITE", website)

    events = []
    root = "projects/project/locations/region/repositories"
    old_digest, shared_digest, new_digest = ["sha256:" + char * 64 for char in "abc"]
    images = {
        old_digest: ["v1.3.60"],
        shared_digest: ["1.3.60", "latest"],
    }
    package_versions = {
        "mirrorneuron-api": {"0.9.0", "1.0.0", "1.0.1"},
        "mirrorneuron-web-ui": {"1.3.59", "1.3.60", "1.3.61"},
    }
    subprocess_run = subprocess.run
    fail_once = failure

    def fake_run(command, **kwargs):
        nonlocal fail_once
        if command[0] == "git" and command[3] == "push":
            repo = Path(command[2]).name
            if fail_once == repo:
                fail_once = None
                return subprocess.CompletedProcess(command, 1, "", "")
            result = subprocess_run(command, **kwargs)
            if result.returncode == 0:
                events.append(repo)
            return result
        if command[0] not in {"fake-gcloud", "fake-docker"}:
            return subprocess_run(command, **kwargs)
        output = ""
        action = tuple(command[1:4])
        if action == ("artifacts", "repositories", "describe"):
            output = json.dumps({"format": command[4].upper()})
        elif action == ("artifacts", "docker", "images"):
            assert (
                command[5] == "region-docker.pkg.dev/project/docker/mirror-neuron-core"
            )
            output = json.dumps(
                [
                    {"package": command[5], "version": digest, "tags": tags}
                    for digest, tags in images.items()
                ]
            )
        elif action == ("artifacts", "versions", "list"):
            flags = dict(arg.split("=", 1) for arg in command[4:])
            name = flags["--package"]
            prefix = f"{root}/{flags['--repository']}/packages/{name}/versions/"
            output = json.dumps(
                [
                    {"name": prefix + version}
                    for version in sorted(package_versions[name])
                ]
            )
        elif action == ("artifacts", "versions", "delete"):
            assert events[-2:] == ["mn-deploy", "mn-website"] or events[-1] == "delete"
            name, version = command[4].split("/packages/")[1].split("/versions/")
            assert "--quiet" in command
            assert ("--delete-tags" in command) == (name != "mirror-neuron-core")
            if fail_once == "delete" and name == "mirrorneuron-web-ui":
                fail_once = None
                return subprocess.CompletedProcess(command, 1, "", "error")
            if name == "mirror-neuron-core":
                assert not images.pop(version)
            else:
                package_versions[name].remove(version)
            events.append("delete")
        return subprocess.CompletedProcess(command, 0, output, "")

    def fake_component(args, workspace, component, directory):
        kind = component["kind"]
        events.append(kind)
        if kind == "core":
            images.update(
                {
                    old_digest: [],
                    shared_digest: ["latest"],
                    new_digest: ["v1.3.60", "1.3.60"],
                }
            )
            (directory / "core-image.json").write_text(
                json.dumps({"containerimage.digest": new_digest})
            )

    monkeypatch.setattr(subprocess, "run", fake_run)
    monkeypatch.setattr(repair, "build_python", lambda *args: None)
    monkeypatch.setattr(repair, "publish_python", lambda *args: events.append("python"))
    monkeypatch.setattr(repair, "publish_component", fake_component)
    argv = [
        "update-changed-components.py",
        "--apply",
        "--workspace-root",
        str(workspace),
        "--project",
        "project",
        "--location",
        "region",
        "--python-repository",
        "python",
        "--npm-repository",
        "npm",
        "--docker-repository",
        "docker",
        "--gcloud",
        "fake-gcloud",
        "--docker",
        "fake-docker",
    ]
    if publish:
        argv.append("--publish-scripts")
    if cleanup:
        argv.append("--remove-old-versions")
    monkeypatch.setattr(sys, "argv", argv)

    pending = deploy / "dist/component-updates/pending-release.json"
    if failure:
        with pytest.raises(RuntimeError, match="failed"):
            repair.main()
        assert pending.exists()
        assert events.count("delete") == int(failure == "delete")
    repair.main()

    assert events[:3] == ["python", "web-ui", "core"]
    assert events.count("python") == events.count("core") == 1
    assert events.count("delete") == (3 if cleanup else 0)
    assert not pending.exists()
    assert git(deploy, "rev-parse", "HEAD") == git(deploy_remote, "rev-parse", "main")
    assert (
        "install_support/v1.3.61/package-index/python-packages.toml"
        in git(deploy_remote, "ls-tree", "-r", "--name-only", "main").splitlines()
    )
    for repo in (deploy, website):
        assert git(repo, "diff", "--cached", "--name-only") == "unrelated.txt"
    for name in repair.INSTALL_SCRIPTS:
        script = website / "public" / name
        assert script.read_bytes() == (
            (deploy / name).read_bytes() if publish else b"previous\n"
        )
        if publish:
            assert (
                git(website_remote, "show", f"main:public/{name}")
                == (deploy / name).read_text().strip()
            )
    assert bool(events.count("mn-website")) == publish
    assert (old_digest not in images) == cleanup
    assert set(images) >= {shared_digest, new_digest}
    assert package_versions["mirrorneuron-api"] >= {"0.9.0", "1.0.1"}
    assert package_versions["mirrorneuron-web-ui"] >= {"1.3.59", "1.3.61"}
    assert ("1.0.0" not in package_versions["mirrorneuron-api"]) == cleanup
    assert ("1.3.60" not in package_versions["mirrorneuron-web-ui"]) == cleanup


def function(name):
    source = (Path(__file__).resolve().parents[1] / "install.sh").read_text()
    return re.search(
        r"^(?P<indent>[ \t]*)function " + name + r"\(\) \{\n.*?^(?P=indent)\}",
        source,
        re.M | re.S,
    ).group()


@pytest.mark.parametrize(
    "asset, expected",
    [
        ("docker-compose.yml", "install_support/v1.3.61/docker-compose.yml"),
        (
            "package-index/python-packages.toml",
            "install_support/v1.3.62/package-index/python-packages.toml",
        ),
    ],
)
def test_url_download_uses_independent_support_and_index_pins(asset, expected):
    result = subprocess.check_output(
        [
            "bash",
            "-eu",
            "-c",
            function("mn_install_support_asset_path")
            + '\nmn_install_support_asset_path "$ASSET"',
        ],
        text=True,
        env={
            **os.environ,
            "MN_INSTALL_VERSION": "v1.3.60",
            "MN_INSTALL_SUPPORT_VERSION": "v1.3.61",
            "PACKAGE_INDEX_VERSION": "v1.3.62",
            "ASSET": asset,
        },
    )
    assert result == expected


@pytest.mark.parametrize("historical", [False, True])
def test_binary_version_selection_keeps_core_and_runtime_independent(historical):
    script = (
        function("finalize_binary_install_version")
        + """
mn_validate_version_tag_or_exit() { :; }
mn_package_version_from_tag() { printf '%s' "${1#v}"; }
mn_web_ui_package_version_from_tag() { printf '%s' "${1#v}"; }
PYTHON_SDK_INSTALL_VERSION="" CLI_INSTALL_VERSION="" API_INSTALL_VERSION="" WEB_UI_INSTALL_VERSION=""
CORE_INSTALL_VERSION="" PACKAGE_INDEX_VERSION=""
INSTALL_VERSION_EXPLICIT=Y
finalize_binary_install_version
printf '%s\\n' "$INSTALL_VERSION" "$CORE_INSTALL_VERSION" "$RUNTIME_COMPOSE_TEMPLATE" "$PACKAGE_INDEX_FILE"
"""
    )
    version = "v1.2.99" if historical else "v1.3.60"
    env = {
        **os.environ,
        "SCRIPT_DIR": "/fixture",
        "INSTALL_VERSION": version,
        "MN_DEFAULT_INSTALL_VERSION": "v1.3.60",
        "MN_DEFAULT_INSTALL_SUPPORT_VERSION": "v1.3.61",
        "MN_DEFAULT_CORE_VERSION": "v1.3.60",
        "MN_DEFAULT_AGENT_PACKAGE_INDEX_VERSION": "v1.3.62",
    }
    for name in ("PYTHON_SDK", "CLI", "API", "WEB_UI"):
        env["DEFAULT_" + name + "_INSTALL_VERSION"] = "v1.4.0"
    result = subprocess.check_output(
        ["bash", "-eu", "-c", script], text=True, env=env
    ).splitlines()
    assert result == [
        version,
        version,
        f"/fixture/install_support/{version if historical else 'v1.3.61'}/docker-compose.yml",
        f"/fixture/install_support/{version if historical else 'v1.3.62'}/package-index/python-packages.toml",
    ]
