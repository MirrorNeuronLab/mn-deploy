"""Runtime reinstall cleanup must preserve job-owned workers and argument boundaries."""

import os
from pathlib import Path
import re
import subprocess

import pytest


@pytest.mark.parametrize("inventory", ["", "worker", "core\nworker\napi"])
def test_reinstall_removes_only_runtime_containers(tmp_path, inventory):
    source = Path(__file__).resolve().parents[1].joinpath("install.sh").read_text()
    function = re.search(
        r"^function mn_stop_runtime_containers_for_reinstall\(\) \{\n.*?^\}",
        source,
        re.M | re.S,
    ).group()
    harness = r"""
set -euo pipefail
print_detail() { :; }
print_step() { :; }
print_error() { printf '%s\n' "$1" >&2; }
docker() {
    case "$1" in
        ps) printf '%s\n' "$INVENTORY" ;;
        inspect)
            if [ "$4" = worker ]; then printf '%s\n' docker_worker; fi
            ;;
        rm)
            shift 2
            printf '%s\n' "$@" > "$REMOVED"
            ;;
        *) return 99 ;;
    esac
}
"""
    result = subprocess.run(
        [
            "/bin/bash",
            "-c",
            harness + function + "\nmn_stop_runtime_containers_for_reinstall\n",
        ],
        env={
            **os.environ,
            "INVENTORY": inventory,
            "REMOVED": str(tmp_path / "removed"),
        },
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    removed = tmp_path / "removed"
    if inventory == "core\nworker\napi":
        assert removed.read_text().splitlines() == ["core", "api"]
    else:
        assert not removed.exists()
