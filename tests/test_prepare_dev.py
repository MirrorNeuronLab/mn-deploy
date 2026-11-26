"""Exercise SDK selection, verification and reuse without a network connection."""

import hashlib
from pathlib import Path
import re
import subprocess
import tarfile

import pytest

PREPARE = Path(__file__).resolve().parents[1] / "scripts/preapare_dev.sh"


@pytest.mark.parametrize(
    "system,machine,platform",
    [
        ("Linux", "aarch64", "arm64-linux"),
        ("Linux", "x86_64", "x86_64-linux"),
        ("Darwin", "arm64", "arm64-macos"),
        ("Darwin", "x86_64", "x86_64-macos"),
    ],
)
def test_prepare_verifies_then_reuses_the_host_sdk(tmp_path, system, machine, platform):
    name = f"wasi-sdk-34.0-{platform}"
    sdk_bin = tmp_path / name / "bin"
    tools = tmp_path / "tools"
    sdk_bin.mkdir(parents=True)
    tools.mkdir()
    programs = {
        sdk_bin / "clang": 'test "$1" = --target=wasm32-wasip2',
        sdk_bin / "llvm-ar": "exit 0",
        tools
        / "uname": 'if [ "$1" = -s ]; then echo "$SYSTEM"; else echo "$MACHINE"; fi',
        tools / "rustc": 'echo "$HOME/wasip2"',
        tools
        / "rustup": 'test "$*" = "target add wasm32-wasip2" && mkdir -p "$HOME/wasip2"',
        tools / "curl": '''while [ "$1" != -o ]; do shift; done
printf '%s\n' "$3" >> "$HOME/urls"
cp "$HOME/payload" "$2"''',
        tools / "wasm32-wasip2-clang": "exit 1",
    }
    for path, body in programs.items():
        path.write_text("#!/bin/sh\n" + body + "\n")
        path.chmod(0o755)

    payload = tmp_path / "payload"
    with tarfile.open(payload, "w:gz") as archive:
        archive.add(sdk_bin.parent, arcname=name)
    valid = payload.read_bytes()
    script = tmp_path / "prepare.sh"
    source = PREPARE.read_text().replace(
        "/opt/wasi-sdk", str(tmp_path / "opt/wasi-sdk")
    )
    script.write_text(
        re.sub(
            r"digest=[0-9a-f]{64}",
            "digest=" + hashlib.sha256(valid).hexdigest(),
            source,
        )
    )
    data = tmp_path / "user data"
    env = {
        "PATH": f"{tools}:/usr/bin:/bin",
        "HOME": str(tmp_path),
        "XDG_DATA_HOME": str(data),
        "SYSTEM": system,
        "MACHINE": machine,
    }

    def prepare(**overrides):
        return subprocess.run(
            ["bash", script],
            env={**env, **overrides},
            capture_output=True,
            text=True,
            timeout=10,
        )

    payload.write_bytes(b"incomplete archive")
    failed = prepare()
    assert failed.returncode and "checksum failed" in failed.stderr
    cache = data / "mirrorneuron/dev"
    assert list(cache.iterdir()) == []
    payload.write_bytes(valid)
    installed = prepare()
    assert installed.returncode == 0, installed.stderr
    assert Path(installed.stdout.strip()) == cache / name
    payload.unlink()
    cached = prepare()
    assert cached.returncode == 0, cached.stderr
    assert cached.stdout == installed.stdout
    explicit = prepare(WASI_SDK_PATH=str(sdk_bin.parent))
    assert explicit.returncode == 0, explicit.stderr
    assert Path(explicit.stdout.strip()) == sdk_bin.parent
    url = f"https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-34/{name}.tar.gz"
    assert (tmp_path / "urls").read_text().splitlines() == [url, url]
