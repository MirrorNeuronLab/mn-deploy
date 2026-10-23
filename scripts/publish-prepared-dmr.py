#!/usr/bin/env python3
"""Build pinned managed DMR native archives; --apply publishes them to public GAR."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from urllib.parse import quote
from urllib.request import urlopen
import zipfile

if sys.version_info < (3, 12):
    raise SystemExit("error: Python 3.12+ with the matching MirrorNeuron SDK is required")

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


def validate_release(recipe, directory, document, *, project, location, repository, match_catalog=False):
    """Check the exact upload inventory, including untrusted saved metadata."""
    runner = recipe.document["runner"]
    version = managed_runner_version(recipe).removeprefix("mn-managed-")
    platforms = {target.rsplit("-", 1)[0] for target in recipe.document["backend"]["assets"]}
    if (not isinstance(document, dict) or set(document) != {"repository", "revision", "policy", "assets"}
        or any(document.get(key) != runner.get(key) for key in ("repository", "revision", "policy"))
        or not isinstance(document["assets"], dict) or set(document["assets"]) != platforms):
        raise ValueError("Runner release does not match the selected catalog recipe")
    if match_catalog and document != runner:
        raise ValueError("Runner release differs from the catalog's pinned assets; use matching saved archives and build tools")
    directory = directory.resolve()
    for platform, asset in document["assets"].items():
        name = f"managed-dmr-{platform}." + ("zip" if platform.startswith("windows-") else "tar.gz")
        if (not isinstance(asset, dict) or set(asset) != {"name", "url", "sha256"}
            or asset["name"] != name
            or asset["url"] != download_url(project, location, repository, version, name)
            or not re.fullmatch(r"[0-9a-f]{64}", str(asset["sha256"]))):
            raise ValueError("Runner release contains an invalid archive name, URL or checksum")
        path = directory / name
        if path.is_symlink() or not path.is_file() or path.stat().st_size == 0:
            raise ValueError(f"Runner archive is missing, empty or a symlink: {name}")
        with path.open("rb") as source:
            if hashlib.file_digest(source, "sha256").hexdigest() != asset["sha256"]:
                raise ValueError(f"Runner archive checksum does not match its release: {name}")
    return version


def verify_public_release(directory, document, *, open_url=None):
    """Read without credentials and require every complete public file to match."""
    open_url = open_url or urlopen
    for platform, asset in sorted(document["assets"].items()):
        expected_size = (directory / asset["name"]).stat().st_size
        size, digest = 0, hashlib.sha256()
        with open_url(asset["url"], timeout=60) as response:
            if response.status != 200:
                raise ValueError(f"Public runner download failed: {asset['name']}")
            while chunk := response.read(min(1024 * 1024, expected_size - size + 1)):
                size += len(chunk)
                if size > expected_size:
                    raise ValueError(f"Public runner archive size differs: {asset['name']}")
                digest.update(chunk)
        if size != expected_size or digest.hexdigest() != asset["sha256"]:
            raise ValueError(f"Public runner archive checksum differs: {asset['name']}")
        print(f"Verified public runner: {platform}", flush=True)


def publish_release(directory, document, version, *, project, location, repository, run=None):
    run = run or subprocess.run
    # Never upload extra files from an operator's saved build directory.
    with tempfile.TemporaryDirectory(prefix="mn-dmr-upload-") as temporary:
        upload = Path(temporary)
        for asset in document["assets"].values():
            shutil.copyfile(directory / asset["name"], upload / asset["name"])
            with (upload / asset["name"]).open("rb") as source:
                if hashlib.file_digest(source, "sha256").hexdigest() != asset["sha256"]:
                    raise ValueError("Runner archive changed before publication")
        (upload / "runner-assets.json").write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
        run(["gcloud", "artifacts", "generic", "upload", "--quiet", "--skip-existing",
             "--project=" + project, "--location=" + location, "--repository=" + repository,
             "--package=managed-dmr", "--version=" + version, "--source-directory=" + str(upload)], check=True)
    verify_public_release(directory, document)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--output", type=Path, help="Build archives in a new or empty directory.")
    source.add_argument("--from-directory", type=Path, help="Reuse saved archives and runner-assets.json without rebuilding.")
    parser.add_argument("--model", default="small", help="SDK catalog model whose shared runner to publish (default: small).")
    parser.add_argument("--project", default="mirrorneuron-public-packages")
    parser.add_argument("--location", default="us-central1")
    parser.add_argument("--repository", default="mirrorneuron-binaries")
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--match-catalog", action="store_true", help="Require the exact URLs and checksums already pinned in the SDK catalog.")
    args = parser.parse_args()
    try:
        recipe = preparation_recipe(resolve_model_entry(args.model))
        if recipe is None:
            raise ValueError("Selected model does not declare a prepared native DMR runner")
        directory = args.from_directory or args.output
        if args.from_directory:
            document = json.loads((directory / "runner-assets.json").read_text())
        else:
            _, document = build_archives(recipe, directory, project=args.project,
                                        location=args.location, repository=args.repository)
        version = validate_release(recipe, directory, document, project=args.project,
            location=args.location, repository=args.repository, match_catalog=args.match_catalog)
        if args.apply:
            publish_release(directory, document, version, project=args.project,
                            location=args.location, repository=args.repository)
        else:
            print("Release validated. Add --apply to publish and verify public downloads.")
    except (KeyError, ValueError, RuntimeError, OSError, subprocess.SubprocessError) as exc:
        parser.exit(1, f"error: {exc}\n")
    print(f"Prepared runner archives: {directory.resolve()}")
    print(f"Catalog runner definition: {directory.resolve() / 'runner-assets.json'}")


if __name__ == "__main__":
    main()
