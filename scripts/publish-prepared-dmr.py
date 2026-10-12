#!/usr/bin/env python3
"""Build pinned managed DMR native archives; --apply publishes them to public GAR."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import gzip
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
from urllib.parse import quote
import zipfile

from mn_sdk import resolve_model_entry
from mn_sdk.dmr_build import patch_managed_server, run_build_command
from mn_sdk.dmr_recipe import preparation_recipe, managed_runner_version, SDK_NATIVE_POLICY


def download_url(project, location, repository, version, name):
    file = quote(f"managed-dmr:{version}:{name}", safe="")
    return (f"https://artifactregistry.googleapis.com/download/v1/projects/{project}/"
            f"locations/{location}/repositories/{repository}/files/{file}:download?alt=media")


def pack_archive(directory, destination):
    files = sorted(directory.iterdir())
    if destination.suffix == ".zip":
        with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for path in files:
                item = zipfile.ZipInfo(path.name, date_time=(1980, 1, 1, 0, 0, 0))
                item.external_attr = (0o100755 if path.name.startswith("model-runner") else 0o100644) << 16
                item.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(item, path.read_bytes())
    else:
        with destination.open("wb") as output, gzip.GzipFile(fileobj=output, mode="wb", filename="", mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w") as archive:
                for path in files:
                    item = archive.gettarinfo(str(path), arcname=path.name)
                    item.uid = item.gid = item.mtime = 0
                    item.uname = item.gname = ""
                    item.mode = 0o755 if path.name.startswith("model-runner") else 0o644
                    with path.open("rb") as source:
                        archive.addfile(item, source)


def build_archives(recipe, output, *, project, location, repository, run=run_build_command):
    output.mkdir(parents=True, exist_ok=True)
    version = managed_runner_version(recipe).removeprefix("mn-managed-")
    runner = recipe.document["runner"]
    platforms = sorted({target.rsplit("-", 1)[0] for target in recipe.document["backend"]["assets"]})
    if any(output.iterdir()):
        raise ValueError("Output directory must be empty; prepared releases are immutable")
    with tempfile.TemporaryDirectory(prefix="mn-dmr-release-") as temporary:
        work = Path(temporary)
        source = work / "source"
        run(["git", "init", str(source)])
        run(["git", "-C", str(source), "fetch", "--depth=1", runner["repository"] + ".git", runner["revision"]])
        run(["git", "-C", str(source), "checkout", "--detach", "FETCH_HEAD"])
        if run(["git", "-C", str(source), "rev-parse", "HEAD"]).stdout.strip() != runner["revision"]:
            raise ValueError("DMR source does not match the pinned revision")
        patch_managed_server(source)
        go_version = run(["go", "version"]).stdout.strip()
        def build(platform):
            system, arch = platform.split("-")
            directory = work / platform
            directory.mkdir()
            binary = directory / ("model-runner.exe" if system == "windows" else "model-runner")
            print(f"==> Building prepared DMR for {platform}", flush=True)
            run(["go", "build", "-trimpath", "-buildvcs=false", "-ldflags",
                 "-s -w -X main.Version=" + managed_runner_version(recipe), "-o", str(binary), "."],
                cwd=source, env={**os.environ, "CGO_ENABLED": "0", "GOTOOLCHAIN": "local", "GOFLAGS": "",
                                 "GOOS": system, "GOARCH": "amd64" if arch == "x64" else "arm64"})
            (directory / "LICENSE").write_bytes((source / "LICENSE").read_bytes())
            (directory / "runner-build.json").write_text(json.dumps({
                "source": runner["repository"], "revision": runner["revision"],
                "policy": SDK_NATIVE_POLICY, "platform": platform, "go_version": go_version,
                "version": managed_runner_version(recipe),
            }, sort_keys=True) + "\n")
            name = f"managed-dmr-{platform}." + ("zip" if system == "windows" else "tar.gz")
            archive = output / name
            pack_archive(directory, archive)
            with archive.open("rb") as payload:
                digest = hashlib.file_digest(payload, "sha256").hexdigest()
            return platform, {"name": name, "sha256": digest,
                              "url": download_url(project, location, repository, version, name)}
        with ThreadPoolExecutor(max_workers=2) as workers:
            assets = dict(workers.map(build, platforms))
    document = {**runner, "policy": SDK_NATIVE_POLICY, "assets": assets}
    (output / "runner-assets.json").write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
    return version, document


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--project", default="mirrorneuron-public-packages")
    parser.add_argument("--location", default="us-central1")
    parser.add_argument("--repository", default="mirrorneuron-binaries")
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    try:
        version, _ = build_archives(preparation_recipe(resolve_model_entry("small")), args.output,
                                    project=args.project, location=args.location, repository=args.repository)
        if args.apply:
            subprocess.run(["gcloud", "artifacts", "generic", "upload", "--quiet",
                            "--project=" + args.project, "--location=" + args.location,
                            "--repository=" + args.repository, "--package=managed-dmr", "--version=" + version,
                            "--source-directory=" + str(args.output.resolve())], check=True)
    except (ValueError, RuntimeError, OSError, subprocess.SubprocessError) as exc:
        parser.exit(1, f"error: {exc}\n")
    print(f"Prepared runner archives: {args.output.resolve()}")
    print(f"Catalog runner definition: {args.output.resolve() / 'runner-assets.json'}")


if __name__ == "__main__":
    main()
