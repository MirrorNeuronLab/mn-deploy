"""Offline Podman registry and connection contracts."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys

import pytest

SOURCE = (Path(__file__).resolve().parents[1] / "install.sh").read_text()
PUBLIC = "us-central1-docker.pkg.dev/mirrorneuron-public-packages/mirrorneuron-runtime/"


def function(name):
    pattern = (
        r"^(?P<indent>[ \t]*)function "
        + re.escape(name)
        + r"\(\) [({]\n.*?^(?P=indent)[})](?=\n)"
    )
    return [match.group() for match in re.finditer(pattern, SOURCE, re.M | re.S)]


def run_pull(tmp_path, *, target="core", host="", connection="", status=0, image=None):
    authfile = tmp_path / "caller auth.json"
    original = '{"credHelpers":{"us-central1-docker.pkg.dev":"gcloud"}}'
    authfile.write_text(original)
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    podman = bin_dir / "podman"
    podman.write_text(f"""#!{sys.executable}
import json, os, pathlib, sys
args = sys.argv[1:]
if args[0] == 'pull':
    authfile = args[args.index('--authfile')+1] if '--authfile' in args else os.environ['REGISTRY_AUTH_FILE']
    record = dict(image=args[-1], authfile=authfile, auth=json.loads(pathlib.Path(authfile).read_text()),
                  host=os.environ.get('CONTAINER_HOST'), connection=os.environ.get('CONTAINER_CONNECTION'))
    with open(os.environ['TEST_LOG'], 'a') as log:
        print(json.dumps(record), file=log)
    sys.exit(int(os.environ['TEST_STATUS']))
elif args[:2] == ['image', 'inspect']:
    fmt = args[3]
    if 'image.version' in fmt: print('v1.3.57')
    elif 'image.revision' in fmt: print('revision')
    elif 'RepoDigests' in fmt: print(args[-1] + '@sha256:' + 'a' * 64)
""")
    podman.chmod(0o755)
    selected_image = (
        image
        or PUBLIC
        + ("mirror-neuron-core" if target == "core" else "membrane-context-engine")
        + ":v1.3.57"
    )
    script = "exec 3>&2\n"
    for name in ("mn_run_logged", "mn_pull_public_gar_image"):
        script += "\n".join(function(name)) + "\n"
    if target == "core":
        script += "\n".join(function("install_core_from_gar")) + "\n"
        script += 'core_gar_image_for_tag() { printf "%s" "$TEST_IMAGE"; }\n'
        call = "install_core_from_gar"
    else:
        script += function("pull_context_engine_image")[int(target)] + "\n"
        script += 'read_env_value() { printf "%s" "$TEST_IMAGE"; }\n'
        call = "pull_context_engine_image"
    script += """
print_detail() { :; }
print_error() { echo "$*" >&2; }
print_success() { :; }
print_warning() { :; }
runtime_compose() { echo "compose:$*"; }
"""
    script += call + "\n"
    result = subprocess.run(
        ["bash", "-euc", script],
        capture_output=True,
        text=True,
        timeout=10,
        env={
            **os.environ,
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "MN_INSTALL_VERBOSE": "N",
            "MN_INSTALL_ROLE": "full",
            "MN_PYTHON_BIN": sys.executable,
            "REGISTRY_AUTH_FILE": str(authfile),
            "CONTAINER_HOST": host,
            "CONTAINER_CONNECTION": connection,
            "TEST_STATUS": str(status),
            "TEST_LOG": str(tmp_path / "log"),
            "TEST_IMAGE": selected_image,
            "CORE_RELEASE_TAG": "v1.3.57",
            "INSTALL_DIR": str(tmp_path / "installed"),
            "INSTALL_METADATA_FILE": str(tmp_path / "installed/metadata.json"),
            "RUNTIME_COMPOSE_ENV": "unused",
            "TMPDIR": str(tmp_path),
        },
    )
    assert authfile.read_text() == original
    assert (tmp_path / "log").exists(), result.stderr
    records = [json.loads(line) for line in (tmp_path / "log").read_text().splitlines()]
    return result, records, authfile


@pytest.mark.parametrize("target", ["core", "0", "1", "2"])
@pytest.mark.parametrize(
    "host,connection", [("", ""), ("ssh://compute", ""), ("", "podman-machine-default")]
)
def test_public_pulls_bypass_helpers_and_preserve_connection(
    tmp_path, target, host, connection
):
    result, records, authfile = run_pull(
        tmp_path, target=target, host=host, connection=connection
    )
    assert result.returncode == 0, result.stderr
    assert len(records) == 1
    record = records[0]
    assert record["host"] == host
    assert record["connection"] == connection
    assert record["auth"] == {"auths": {}}
    assert record["authfile"] != str(authfile)
    assert not Path(record["authfile"]).exists()
    if target == "core":
        metadata = json.loads((tmp_path / "installed/metadata.json").read_text())
        assert metadata["core_image_digest"] == "sha256:" + "a" * 64


@pytest.mark.parametrize("target", ["core", "0", "1", "2"])
def test_public_pull_failure_cleans_config_and_stops(tmp_path, target):
    result, records, _ = run_pull(tmp_path, target=target, status=7)
    assert result.returncode != 0
    assert "Could not pull" in result.stderr
    assert len(records) == 1
    assert not Path(records[0]["authfile"]).exists()
    assert not (tmp_path / "installed/metadata.json").exists()


def test_private_core_override_keeps_credentials(tmp_path):
    result, records, authfile = run_pull(
        tmp_path, image="private.example/core:v1.3.57", host="ssh://private"
    )
    assert result.returncode == 0, result.stderr
    assert records[0]["authfile"] == str(authfile)
    assert records[0]["host"] == "ssh://private"
