"""Exercise the runtime installer against a pinned, offline release fixture."""

import hashlib
import os
from pathlib import Path
import subprocess
import sys

import pytest

INSTALLER = Path(__file__).resolve().parents[1] / "install.sh"
PAYLOAD = b"fixture wac binary"
PIN = hashlib.sha256(PAYLOAD).hexdigest()
TARGETS = [
    ("Darwin", "arm64", "aarch64-apple-darwin"),
    ("Darwin", "x86_64", "x86_64-apple-darwin"),
    ("Linux", "aarch64", "aarch64-unknown-linux-musl"),
    ("Linux", "x86_64", "x86_64-unknown-linux-musl"),
    ("MINGW64_NT", "x86_64", "x86_64-pc-windows-gnu"),
]


def install(tmp_path, os_name, arch, payload=PAYLOAD):
    source = INSTALLER.read_text()
    start = source.index("function mn_wac_matches()")
    end = source.index("function mn_configure_installed_runtime()", start)
    import re

    functions = re.sub(r"digest=[0-9a-f]{64}", f"digest={PIN}", source[start:end])
    venv = tmp_path / "venv" / "bin"
    venv.mkdir(parents=True, exist_ok=True)
    if not (venv / "python").exists():
        (venv / "python").symlink_to(sys.executable)
    (tmp_path / "download").write_bytes(payload)
    script = (
        functions
        + """
uname() { if [ "$1" = -s ]; then echo "$TEST_SYSTEM"; else echo "$TEST_ARCH"; fi; }
print_error() { echo "$*" >&2; }
curl() {
  echo "${!#}" >> "$TEST_DIR/urls"
  while [ "$1" != -o ]; do shift; done
  cp "$TEST_DIR/download" "$2"
}
mn_install_wac
"""
    )
    return subprocess.run(
        ["bash", "-eu", "-c", script],
        env={
            **os.environ,
            "TEST_SYSTEM": os_name,
            "TEST_ARCH": arch,
            "TEST_DIR": str(tmp_path),
            "VENV_DIR": str(venv.parent),
            "BIN_DIR": str(tmp_path / "runtime home/bin"),
            "MN_WAC_VERSION": "v0.12.0",
        },
        capture_output=True,
        text=True,
    )


@pytest.mark.parametrize("os_name,arch,target", TARGETS)
def test_installs_and_reuses_verified_binary(tmp_path, os_name, arch, target):
    assert install(tmp_path, os_name, arch).returncode == 0
    name = "wac.exe" if os_name.startswith("MINGW") else "wac"
    binary = tmp_path / "runtime home/bin" / name
    assert binary.read_bytes() == PAYLOAD and os.access(binary, os.X_OK)
    binary.chmod(0o600)
    assert install(tmp_path, os_name, arch).returncode == 0
    assert os.access(binary, os.X_OK)
    assert (tmp_path / "urls").read_text().splitlines() == [
        f"https://github.com/bytecodealliance/wac/releases/download/v0.12.0/wac-cli-{target}"
    ]


def test_invalid_download_preserves_previous_install(tmp_path):
    destination = tmp_path / "runtime home/bin/wac"
    destination.parent.mkdir(parents=True)
    destination.write_bytes(b"previous binary")
    failed = install(tmp_path, "Linux", "aarch64", b"corrupt")
    assert failed.returncode != 0 and "checksum" in failed.stderr
    assert destination.read_bytes() == b"previous binary"
    assert list(destination.parent.iterdir()) == [destination]
    assert install(tmp_path, "Linux", "aarch64").returncode == 0
    assert destination.read_bytes() == PAYLOAD
