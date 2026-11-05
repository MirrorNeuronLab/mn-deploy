import importlib.util
import json
from pathlib import Path
import subprocess
import sys
from types import SimpleNamespace
from urllib.error import HTTPError

import pytest

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
spec = importlib.util.spec_from_file_location(
    "computer_use_publisher",
    SCRIPTS / "publish_computer_use_to_google_artifact_registry.py",
)
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)


def test_plan_has_no_gcloud_or_apple_side_effects(tmp_path):
    result = subprocess.run(
        [
            sys.executable,
            str(SCRIPTS / "publish_computer_use_to_google_artifact_registry.py"),
            "--output-dir",
            str(tmp_path / "missing"),
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    assert "arm64, x86_64" in result.stdout
    assert not (tmp_path / "missing").exists()


def test_notarization_credentials_fail_closed_and_are_not_printed(monkeypatch):
    with pytest.raises(ValueError, match="KEY, KEY_ID and ISSUER"):
        publisher.notarization_auth({"KEY": "secret"})
    assert publisher.notarization_auth({"MN_NOTARY_KEYCHAIN_PROFILE": "release"}) == [
        "--keychain-profile",
        "release",
    ]

    def timeout(command, **kwargs):
        raise subprocess.TimeoutExpired(command, 30)

    monkeypatch.setattr(publisher.subprocess, "run", timeout)
    with pytest.raises(RuntimeError) as raised:
        publisher.run(["notarytool", "--password", "secret"], label="Notarization")
    assert "secret" not in str(raised.value)


@pytest.mark.parametrize("conflict", [False, True])
def test_upload_is_verified_and_manifest_is_published_last(
    monkeypatch, tmp_path, conflict
):
    name = "mn-computer-use-macos-arm64.zip"
    (tmp_path / name).write_bytes(b"verified app")
    remote, uploads = {}, []
    if conflict:
        remote[name] = b"different artifact"

    def download(url, destination, limit):
        if url not in remote:
            raise HTTPError(url, 404, "missing", {}, None)
        destination.write_bytes(remote[url])

    def run(command, **kwargs):
        filename = Path(
            next(
                arg.split("=", 1)[1]
                for arg in command
                if str(arg).startswith("--source=")
            )
        )
        uploads.append(filename.name)
        remote[filename.name] = filename.read_bytes()

    monkeypatch.setattr(publisher, "run", run)
    monkeypatch.setattr(publisher, "verify_zip", lambda *_: {"verified": True})
    distribution = SimpleNamespace(
        asset_name=lambda _: name,
        download=download,
        download_url=lambda name, **_: name,
        PACKAGE="mn-computer-use",
        release_version=lambda: "immutable",
        MAX_ARCHIVE=1024,
    )
    args = SimpleNamespace(
        output_dir=tmp_path,
        project="project",
        location="region",
        repository="generic",
        gcloud="gcloud",
    )
    if conflict:
        with pytest.raises(RuntimeError, match="Immutable"):
            publisher.publish(args, distribution, "arm64")
        assert not uploads
    else:
        publisher.publish(args, distribution, "arm64")
        assert uploads == [name, name + ".json"]
        assert json.loads(remote[name + ".json"]) == {"verified": True}


def test_release_orders_native_artifact_before_skill_wheel():
    source = (SCRIPTS / "release_all.sh").read_text()
    assert source.index('CURRENT_PHASE="computer-use"') < source.index(
        'CURRENT_PHASE="python"'
    )
    changed = (SCRIPTS / "update-changed-components.py").read_text()
    assert changed.index("if native_app:\n        run(") < changed.index(
        "    publish_python(args, planned, directory)"
    )
