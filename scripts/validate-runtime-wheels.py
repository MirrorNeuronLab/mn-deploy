#!/usr/bin/env python3
"""Build clean surface/runtime wheels and validate their coordinated package pins."""

import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import tomllib
import zipfile


def validate(workspace: Path) -> None:
    deploy = workspace / "mn-deploy"
    index = deploy / "package-index/python-packages.toml"
    projects = {p["path"]: p for p in tomllib.loads(index.read_text())["packages"]}
    selected = ("mn-python-sdk", "mn-python-sdk/packages/runtime", "mn-cli", "mn-api")
    with tempfile.TemporaryDirectory(prefix="mn-wheel-contract-") as directory:
        root = Path(directory)
        wheels = root / "wheels"
        wheels.mkdir()
        # Never consume a stale build/lib tree or modify the source checkout.
        for repository in ("mn-python-sdk", "mn-cli", "mn-api"):
            source = workspace / repository
            names = (
                subprocess.check_output(
                    [
                        "git",
                        "ls-files",
                        "-z",
                        "--cached",
                        "--others",
                        "--exclude-standard",
                    ],
                    cwd=source,
                )
                .decode()
                .split("\0")
            )
            for name in set(names) - {""}:
                original = source / name
                if original.is_file():
                    target = root / repository / name
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(original, target)
        for relative in selected:
            result = subprocess.run(
                [
                    sys.executable,
                    "-m",
                    "build",
                    "--wheel",
                    "--no-isolation",
                    "--outdir",
                    str(wheels),
                ],
                cwd=root / relative,
                env={
                    **os.environ,
                    "SETUPTOOLS_SCM_PRETEND_VERSION": projects[relative]["version"],
                },
                capture_output=True,
                text=True,
            )
            if result.returncode:
                raise SystemExit(result.stdout[-5000:] + result.stderr[-5000:])
        spec = importlib.util.spec_from_file_location(
            "wheel_contract", deploy / "scripts/validate-python-release.py"
        )
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        module.validate(
            index, wheels, required_names={projects[p]["name"] for p in selected}
        )
        for wheel in wheels.glob("*.whl"):
            with zipfile.ZipFile(wheel) as archive:
                names = archive.namelist()
            runtime = wheel.name.startswith("mirrorneuron_runtime-")
            assert any(name.startswith("mn_runtime/") for name in names) is runtime, (
                wheel.name
            )
            assert not any(
                "native_runtime_service.py" in name or "mn_cli/runtime/" in name
                for name in names
            ), wheel.name
            print(f"Validated {wheel.name}")


if __name__ == "__main__":
    validate(Path(__file__).resolve().parents[2])
