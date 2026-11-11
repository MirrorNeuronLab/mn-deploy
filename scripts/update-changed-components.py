#!/usr/bin/env python3
"""Publish changed packages and repair images while keeping Core/installer versions."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import tomllib
from urllib.parse import unquote

SCRIPTS = Path(__file__).resolve().parent
WEBSITE = Path("/Users/homer/Projects/mn-website")
INSTALL_SCRIPTS = ("install.sh", "uninstall.sh")
DOCKER_PACKAGES = {
    "core": "mirror-neuron-core",
    "membrane": "membrane-context-engine",
}
VERSION = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")
DIGEST = re.compile(r"sha256:[0-9a-f]{64}")


def module(filename):
    spec = importlib.util.spec_from_file_location(filename, SCRIPTS / filename)
    loaded = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = loaded
    spec.loader.exec_module(loaded)
    return loaded


def run(*args, capture=False, env=None):
    result = subprocess.run(
        [str(arg) for arg in args],
        env=env,
        check=False,
        stdout=subprocess.PIPE if capture else None,
        text=True,
    )
    if result.returncode:
        raise RuntimeError(
            f"{' '.join(str(arg) for arg in args[:3])} failed (exit {result.returncode})."
        )
    return result.stdout.strip() if capture else None


def git(repo, *args):
    return run("git", "-C", repo, *args, capture=True)


def default(source, setting):
    match = re.search(
        r"^" + setting + r'="\$\{' + setting + r':-(v[0-9.]+)\}"$', source, re.M
    )
    if not match or not VERSION.fullmatch(match[1][1:]):
        raise RuntimeError(f"Cannot read {setting} from install.sh.")
    return match[1]


def pin(source, setting, tag):
    pattern = r"(^" + setting + r'="\$\{' + setting + r':-)[^}]+(\}")'
    updated, count = re.subn(pattern, lambda m: m[1] + tag + m[2], source, flags=re.M)
    if count != 1:
        raise RuntimeError(f"Cannot update {setting} in install.sh.")
    return updated


def component_changed(repo, tag, recorded):
    tree = git(repo, "rev-parse", "HEAD^{tree}")
    if recorded:
        return tree != recorded["tree"], tree
    baseline = git(repo, "rev-parse", "--verify", f"refs/tags/{tag}^{{tree}}")
    return tree != baseline, tree


def plan(workspace, only):
    deploy = workspace / "mn-deploy"
    source = (deploy / "install.sh").read_text()
    index = deploy / "package-index/python-packages.toml"
    index_source = index.read_text()
    previous = tomllib.loads(index_source)["packages"]
    inventory = module("prepare-python-package-index.py")
    # Compute the next package set in a disposable index. Source metadata stays
    # untouched until all selected GAR uploads have succeeded.
    with tempfile.TemporaryDirectory(prefix="mn-component-plan-") as directory:
        prepared = Path(directory) / "index.toml"
        prepared.write_text(index_source)
        if "python" in only:
            inventory.synchronize(
                prepared,
                workspace,
                "unused",
                independent=True,
                baseline=default(source, "MN_DEFAULT_INSTALL_VERSION"),
                write_projects=False,
            )
            avoid_cached_python_versions(prepared, previous, workspace, inventory)
        prepared_source = prepared.read_text()
    packages = tomllib.loads(prepared_source)["packages"]
    selected = [
        new
        for old, new in zip(previous, packages, strict=True)
        if new["version"] != old["version"]
    ]
    manifest_path = deploy / "package-index/component-sources.json"
    manifest_source = manifest_path.read_text() if manifest_path.exists() else None
    manifest = json.loads(manifest_source) if manifest_source is not None else {}
    components = []
    definitions = [
        ("web-ui", "mn-web-ui", "MN_DEFAULT_WEB_UI_VERSION"),
        ("core", "MirrorNeuron", "MN_DEFAULT_CORE_VERSION"),
        ("membrane", "Membrane", "MN_DEFAULT_MEMBRANE_CONTEXT_ENGINE_VERSION"),
    ]
    for kind, name, setting in definitions:
        if kind not in only:
            continue
        tag = default(source, setting)
        changed, tree = component_changed(
            workspace / name, tag, manifest.get(f"{kind}:{tag}")
        )
        if changed:
            target = "v" + inventory.patch_version(tag[1:]) if kind == "web-ui" else tag
            components.append(
                dict(kind=kind, repo=name, version=target, previous=tag, tree=tree)
            )
            manifest[f"{kind}:{target}"] = {"tree": tree}
    repos = sorted(
        ({Path(p["path"]).parts[0] for p in packages} if "python" in only else set())
        | {name for kind, name, _ in definitions if kind in only}
    )
    heads = {name: git(workspace / name, "rev-parse", "HEAD") for name in repos}
    dirty = [name for name in repos if git(workspace / name, "status", "--porcelain")]
    metadata = {}
    for package in selected:
        relative = Path(package["path"])
        if relative.is_absolute() or ".." in relative.parts:
            raise RuntimeError(f"Invalid indexed package path: {relative}")
        project_path = workspace / relative / "pyproject.toml"
        project_source = project_path.read_text()
        project = tomllib.loads(project_source)["project"]
        if project.get("version") and project["version"] != package["version"]:
            updated, count = re.subn(
                r'(?m)^version\s*=\s*"[^"\n]+"',
                f'version = "{package["version"]}"',
                project_source,
                count=1,
            )
            if count != 1:
                raise RuntimeError(f"Cannot pin static Python version: {project_path}")
            metadata[str(relative / "pyproject.toml")] = updated
    settings = {
        "mirrorneuron-python-sdk": "MN_DEFAULT_PYTHON_SDK_VERSION",
        "mirrorneuron-cli": "MN_DEFAULT_CLI_VERSION",
        "mirrorneuron-api": "MN_DEFAULT_API_VERSION",
    }
    installer = source
    for package in selected:
        if package["name"] in settings:
            installer = pin(
                installer, settings[package["name"]], "v" + package["version"]
            )
    compose_source = (deploy / "docker-compose.yml").read_text()
    compose = compose_source
    for component in components:
        if component["kind"] == "web-ui":
            installer = pin(
                installer, "MN_DEFAULT_WEB_UI_VERSION", component["version"]
            )
            compose, count = re.subn(
                r"(MN_WEB_UI_PACKAGE_VERSION:\s*\$\{MN_WEB_UI_PACKAGE_VERSION:-)[^}]+(\})",
                lambda m: m[1] + component["version"][1:] + m[2],
                compose,
            )
            if count != 1:
                raise RuntimeError(
                    "Cannot pin the Web UI version in docker-compose.yml."
                )
    support_versions = [
        default(source, "MN_DEFAULT_INSTALL_SUPPORT_VERSION")[1:],
        default(source, "MN_DEFAULT_AGENT_PACKAGE_INDEX_VERSION")[1:],
    ]
    support_versions += [
        p.name[1:]
        for p in (deploy / "install_support").glob("v*")
        if VERSION.fullmatch(p.name[1:])
    ]
    support_tag = "v" + inventory.patch_version(
        max(support_versions, key=inventory.numeric_version_key)
    )
    if selected or components:
        installer = pin(installer, "MN_DEFAULT_INSTALL_SUPPORT_VERSION", support_tag)
        installer = pin(
            installer, "MN_DEFAULT_AGENT_PACKAGE_INDEX_VERSION", support_tag
        )
    return dict(
        packages=selected,
        components=components,
        heads=heads,
        metadata=metadata,
        index=prepared_source,
        installer=installer,
        compose=compose,
        original_index=index_source,
        original_installer=source,
        original_compose=compose_source,
        manifest=manifest,
        original_manifest=manifest_source,
        support=support_tag,
        dirty=dirty,
        core=default(source, "MN_DEFAULT_CORE_VERSION"),
        runtime=default(source, "MN_DEFAULT_INSTALL_VERSION"),
    )


def ensure_sources(workspace, planned):
    for repo, head in planned["heads"].items():
        path = workspace / repo
        if git(path, "status", "--porcelain"):
            raise RuntimeError(
                f"Uncommitted changes in {repo}. Commit or stash them, then rerun."
            )
        if git(path, "rev-parse", "HEAD") != head:
            raise RuntimeError(f"{repo} changed during preparation. Rerun the preview.")


def stage_repository(repo, target):
    rows = target.parent / (target.name + ".tar")
    run("git", "-C", repo, "archive", "HEAD", "-o", rows)
    import tarfile

    target.mkdir()
    with tarfile.open(rows) as archive:
        archive.extractall(target, filter="data")
    rows.unlink()


def python_artifact_identity(path):
    from packaging.utils import (
        canonicalize_name,
        parse_sdist_filename,
        parse_wheel_filename,
    )

    name, version, *_ = (
        parse_wheel_filename(path.name)
        if path.suffix == ".whl"
        else parse_sdist_filename(path.name)
    )
    return canonicalize_name(name), str(version)


def python_build_inputs(package):
    return (
        package["name"],
        package["path"],
        package["version"],
        package.get("source_hash"),
        tuple(sorted(package.get("build_formats") or ["sdist", "wheel"])),
    )


def avoid_cached_python_versions(index, previous, workspace, inventory):
    """Keep different build inputs off versions used by interrupted attempts."""
    from packaging.utils import canonicalize_name

    reservations = {}
    root = workspace / "mn-deploy/dist/component-updates"
    for ready in root.glob("*/python-ready.json"):
        try:
            expected = json.loads(ready.read_text())
            if not isinstance(expected, dict):
                continue
            built = {python_artifact_identity(Path(p)) for p in expected}
            packages = tomllib.loads((ready.parent / "index.toml").read_text())[
                "packages"
            ]
            for package in packages:
                identity = canonicalize_name(package["name"]), package["version"]
                if identity in built and package.get("source_hash", "").startswith(
                    "v2:"
                ):
                    reservations.setdefault(identity, set()).add(
                        python_build_inputs(package)
                    )
        except (OSError, ValueError, KeyError):
            continue
    if not reservations:
        return
    source = index.read_text()
    packages = tomllib.loads(source)["packages"]
    versions = {canonicalize_name(p["name"]): p["version"] for p in packages}
    original = {canonicalize_name(p["name"]): p["version"] for p in previous}
    projects = inventory.load_projects(packages, workspace)
    while True:
        minimums = dict(versions)
        for package in packages:
            name = canonicalize_name(package["name"])
            version = versions[name]
            if version == original[name]:
                continue
            inputs = python_build_inputs({**package, "version": version})
            if reservations.get((name, version), set()) - {inputs}:
                minimums[name] = inventory.patch_version(version)
        if minimums == versions:
            break
        versions = inventory.compatible_versions(
            packages, projects, minimums, independent=True
        )
    rows = iter(packages)

    def replace_version(match):
        version = versions[canonicalize_name(next(rows)["name"])]
        return inventory.VERSION_LINE.sub(f'version = "{version}"', match[0])

    index.write_text(inventory.PACKAGE_BLOCK.sub(replace_version, source))


def python_artifacts(package, directory):
    from packaging.utils import canonicalize_name
    from packaging.version import Version

    identity = canonicalize_name(package["name"]), str(Version(package["version"]))
    return [
        path
        for path in sorted((directory / "python").iterdir())
        if python_artifact_identity(path) == identity
    ]


def cached_python_builds(package, directory):
    """Find complete, checksum-validated builds of the same package inputs."""
    if not package.get("source_hash", "").startswith("v2:"):
        return
    # Prefer the first build: it may already have been partially published.
    for ready in sorted(
        directory.parent.glob("*/python-ready.json"), key=lambda p: p.stat().st_mtime
    ):
        candidate = ready.parent
        if candidate == directory:
            continue
        try:
            packages = tomllib.loads((candidate / "index.toml").read_text())["packages"]
            if not any(
                python_build_inputs(p) == python_build_inputs(package) for p in packages
            ):
                continue
            expected = json.loads(ready.read_text())
            files = python_artifacts(package, candidate)
            formats = {"wheel" if p.suffix == ".whl" else "sdist" for p in files}
            if formats != set(package.get("build_formats") or ["sdist", "wheel"]):
                continue
            if isinstance(expected, dict) and all(
                not p.is_symlink()
                and p.is_file()
                and expected.get(str(p.relative_to(candidate)))
                == hashlib.sha256(p.read_bytes()).hexdigest()
                for p in files
            ):
                yield files
        except (OSError, ValueError, KeyError):
            continue  # An incomplete or damaged sibling cache is not reusable.


def reuse_python_build(files, directory):
    for source in files:
        shutil.copyfile(source, directory / "python" / source.name)
    # Existing retry caches must record the restored bytes as well.
    ready = directory / "python-ready.json"
    if ready.exists():
        expected = json.loads(ready.read_text())
        for source in files:
            target = directory / "python" / source.name
            expected[str(target.relative_to(directory))] = hashlib.sha256(
                target.read_bytes()
            ).hexdigest()
        pending = ready.with_suffix(".tmp")
        pending.write_text(json.dumps(expected, indent=2) + "\n")
        pending.replace(ready)


def build_python(workspace, planned, directory):
    if not planned["packages"]:
        return
    inventory = module("prepare-python-package-index.py")
    index = directory / "index.toml"
    index.write_text(planned["index"])
    inventory.verify_dependencies(index, workspace)
    ready = directory / "python-ready.json"
    if ready.exists():
        expected = json.loads(ready.read_text())
        if all(
            (directory / path).is_file()
            and hashlib.sha256((directory / path).read_bytes()).hexdigest() == digest
            for path, digest in expected.items()
        ):
            return  # Keep identical artifacts across interrupted-upload retries.
        raise RuntimeError(
            f"Cached build artifacts changed: {directory}. Move this directory aside and retry."
        )
    artifacts = directory / "python"
    artifacts.mkdir(exist_ok=True)
    pending = []
    for package in planned["packages"]:
        cached = next(cached_python_builds(package, directory), None)
        if cached:
            reuse_python_build(cached, directory)
            print(
                f"==> Reusing Python build {package['name']}=={package['version']}",
                flush=True,
            )
        else:
            pending.append(package)
    with tempfile.TemporaryDirectory(prefix="mn-component-build-") as staging:
        rows = Path(staging) / "packages.tsv"
        rows.write_text(
            "".join(
                f"{p['name']}\t{workspace / p['path']}\t{','.join(p.get('build_formats') or ['sdist', 'wheel'])}\t{p['version']}\n"
                for p in pending
            )
        )
        if pending:
            module("stage-python-release-sources.py").stage_sources(
                rows, Path(staging) / "sources"
            )
        for line in rows.read_text().splitlines():
            name, path, formats, version = line.split("\t")
            staged = Path(path)
            relative = next(p["path"] for p in planned["packages"] if p["name"] == name)
            metadata = planned["metadata"].get(str(Path(relative) / "pyproject.toml"))
            if metadata:
                (staged / "pyproject.toml").write_text(metadata)
            env = {
                **os.environ,
                "SETUPTOOLS_SCM_PRETEND_VERSION": version,
                "MEMBRANE_PYTHON_SDK_VERSION": version,
            }
            run(
                sys.executable,
                "-m",
                "build",
                staged,
                "--outdir",
                artifacts,
                *["--" + fmt for fmt in formats.split(",")],
                env=env,
            )
    files = sorted(artifacts.iterdir())
    run(sys.executable, "-m", "twine", "check", *files)
    module("validate-python-release.py").validate(
        index, artifacts, required_names={p["name"] for p in planned["packages"]}
    )
    from packaging.utils import (
        canonicalize_name,
        parse_sdist_filename,
        parse_wheel_filename,
    )
    from packaging.version import Version

    versions = {
        canonicalize_name(p["name"]): Version(p["version"]) for p in planned["packages"]
    }
    for artifact in files:
        name, version, *_ = (
            parse_wheel_filename(artifact.name)
            if artifact.suffix == ".whl"
            else parse_sdist_filename(artifact.name)
        )
        if (
            canonicalize_name(name) not in versions
            or versions[canonicalize_name(name)] != version
        ):
            raise RuntimeError(f"Unexpected build artifact/version: {artifact.name}")
    ready.write_text(
        json.dumps(
            {
                str(p.relative_to(directory)): hashlib.sha256(
                    p.read_bytes()
                ).hexdigest()
                for p in files
            },
            indent=2,
        )
        + "\n"
    )


def verify_python_artifact(package, artifact, remote):
    item = remote.get(artifact.name)
    if item is None:
        raise RuntimeError(
            f"GAR content verification failed: {package}/{artifact.name} (file missing)."
        )
    # gcloud's artifacts files surface formats hash bytes as hexadecimal,
    # unlike the base64 encoding in the raw Artifact Registry REST response.
    expected = hashlib.sha256(artifact.read_bytes()).hexdigest()
    actual = [
        h.get("value") for h in item.get("hashes", []) if h.get("type") == "SHA256"
    ]
    if expected not in actual:
        reported = (
            ", ".join(str(value) for value in actual) if actual else "unavailable"
        )
        raise RuntimeError(
            f"GAR content verification failed: {package}/{artifact.name} "
            f"(SHA-256 expected {expected}, reported {reported})."
        )


def publish_python(args, planned, directory):
    from packaging.utils import canonicalize_name

    scope = [
        f"--project={args.project}",
        f"--location={args.location}",
        f"--repository={args.python_repository}",
    ]
    url = f"https://{args.location}-python.pkg.dev/{args.project}/{args.python_repository}/"
    for package in planned["packages"]:
        name = canonicalize_name(package["name"])
        artifacts = python_artifacts(package, directory)

        def remote_files():
            data = json.loads(
                run(
                    args.gcloud,
                    "artifacts",
                    "files",
                    "list",
                    *scope,
                    f"--package={name}",
                    f"--version={package['version']}",
                    "--format=json",
                    capture=True,
                )
            )
            return {
                unquote(row["name"].rsplit("/", 1)[-1]).rsplit("/", 1)[-1]: row
                for row in data
            }

        remote = remote_files()
        try:
            for path in artifacts:
                if path.name in remote:
                    verify_python_artifact(name, path, remote)
        except RuntimeError:
            # A changed release plan used to rebuild every package, including
            # already-uploaded versions whose archive timestamps then differed.
            # Restore only a complete build with matching source provenance AND
            # exact GAR hashes; never accept a different published payload.
            for cached in cached_python_builds(package, directory):
                if {p.name for p in cached} != {p.name for p in artifacts}:
                    continue
                try:
                    for path in cached:
                        if path.name in remote:
                            verify_python_artifact(name, path, remote)
                except RuntimeError:
                    continue
                reuse_python_build(cached, directory)
                print(
                    f"==> Reusing published Python build {name}=={package['version']}",
                    flush=True,
                )
                break
            else:
                raise
        missing = [path for path in artifacts if path.name not in remote]
        if missing:
            run(
                sys.executable,
                "-m",
                "twine",
                "upload",
                "--non-interactive",
                "--repository-url",
                url,
                *missing,
                env={**os.environ, "GOOGLE_CLOUD_PROJECT": args.project},
            )
        remote = remote_files()
        for path in artifacts:
            verify_python_artifact(name, path, remote)
        print(f"✓ Published {name}=={package['version']}", flush=True)


def docker_image(args, kind):
    return (
        f"{args.location}-docker.pkg.dev/{args.project}/{args.docker_repository}/"
        + DOCKER_PACKAGES[kind]
    )


def docker_tags(args, component):
    tags = [component["version"], component["version"][1:]]
    if args.update_latest:
        tags.append("latest")
    return tags


def publish_component(args, workspace, component, directory):
    kind = component["kind"]
    with tempfile.TemporaryDirectory(prefix=f"mn-{kind}-repair-") as staging:
        target = Path(staging) / "source"
        stage_repository(workspace / component["repo"], target)
        if kind == "web-ui":
            run(
                "bash",
                SCRIPTS / "publish_web_ui_to_google_artifact_registry.sh",
                "--apply",
                "--version",
                component["version"],
                "--web-ui-dir",
                target,
                "--dist-dir",
                directory / "web-ui",
                "--project",
                args.project,
                "--location",
                args.location,
                "--repository",
                args.npm_repository,
                env={**os.environ, "MN_GCLOUD_BIN": args.gcloud},
            )
            return
        image = docker_image(args, kind)
        tags = docker_tags(args, component)
        run(
            args.gcloud,
            "auth",
            "configure-docker",
            f"{args.location}-docker.pkg.dev",
            "--quiet",
        )
        if args.qemu == "always" or (
            args.qemu == "auto"
            and os.uname().machine in ("arm64", "aarch64")
            and "linux/amd64" in args.platforms.split(",")
        ):
            run(
                args.docker,
                "run",
                "--privileged",
                "--rm",
                "tonistiigi/binfmt@sha256:400a4873b838d1b89194d982c45e5fb3cda4593fbfd7e08a02e76b03b21166f0",
                "--install",
                "amd64",
            )
        metadata = directory / f"{kind}-image.json"
        command = [
            args.docker,
            "buildx",
            "build",
            "--push",
            "--platform",
            args.platforms,
            "--file",
            str(target / "Dockerfile"),
            "--metadata-file",
            str(metadata),
            "--label",
            f"org.opencontainers.image.version={component['version']}",
            "--label",
            f"org.opencontainers.image.revision={git(workspace / component['repo'], 'rev-parse', 'HEAD')}",
        ]
        for tag in tags:
            command += ["--tag", f"{image}:{tag}"]
        if kind == "membrane":
            command += ["--target", "runtime"]
        else:
            command += [
                "--build-arg",
                "CORE_RELEASE_TAG=" + component["version"],
                "--build-arg",
                "CORE_REVISION="
                + git(workspace / component["repo"], "rev-parse", "HEAD"),
                "--build-arg",
                "ERL_AFLAGS=+JMsingle true",
            ]
        command += [str(target)]
        run(*command)
        digest = json.loads(metadata.read_text())["containerimage.digest"]
        for tag in tags:
            manifest = json.loads(
                run(
                    args.docker,
                    "buildx",
                    "imagetools",
                    "inspect",
                    image + ":" + tag,
                    "--format",
                    "{{json .Manifest}}",
                    capture=True,
                )
            )
            if manifest["digest"] != digest:
                raise RuntimeError(f"GAR image verification failed: {image}:{tag}")


def deploy_changes(planned):
    support = f"install_support/{planned['support']}"
    return {
        f"{support}/package-index/python-packages.toml": (None, planned["index"]),
        f"{support}/docker-compose.yml": (None, planned["compose"]),
        "package-index/python-packages.toml": (
            planned["original_index"],
            planned["index"],
        ),
        "package-index/component-sources.json": (
            planned["original_manifest"],
            json.dumps(planned["manifest"], indent=2) + "\n",
        ),
        "docker-compose.yml": (planned["original_compose"], planned["compose"]),
        "install.sh": (planned["original_installer"], planned["installer"]),
    }


def write_file(path, content, *, mode=None):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".mn-release-", dir=path.parent) as staging:
        staged = Path(staging) / path.name
        staged.write_bytes(content)
        if mode is not None:
            staged.chmod(mode)
        elif path.exists():
            shutil.copymode(path, staged)
        staged.replace(path)


def write_json(path, value):
    write_file(path, (json.dumps(value, indent=2) + "\n").encode())


def finish(workspace, planned, previous_projects=None):
    deploy = workspace / "mn-deploy"
    support = deploy / "install_support" / planned["support"]
    if previous_projects is None and support.exists():
        raise RuntimeError(f"Immutable support snapshot already exists: {support}")
    changes = {
        deploy / path: content for path, content in deploy_changes(planned).items()
    }
    for relative, content in planned["metadata"].items():
        path = workspace / relative
        previous = (
            path.read_text()
            if previous_projects is None
            else previous_projects[relative]
        )
        changes[path] = (previous, content)
    # A retry can encounter a mix of original and already finalized files.
    # Check every input before replacing any file.
    pending = {}
    for path, (previous, content) in changes.items():
        current = path.read_text() if path.exists() else None
        if current != previous and (previous_projects is None or current != content):
            raise RuntimeError(
                f"{path.name} changed during publishing. Reconcile {path} and rerun."
            )
        if current != content:
            pending[path] = content
    for path, content in pending.items():
        write_file(path, content.encode())


def check_release_repo(repo, *clean_paths):
    if not repo.is_dir() or git(repo, "rev-parse", "--show-toplevel") != str(
        repo.resolve()
    ):
        raise RuntimeError(f"Expected a Git checkout at {repo}.")
    if (
        git(repo, "branch", "--show-current") != "main"
        or "origin" not in git(repo, "remote").splitlines()
    ):
        raise RuntimeError(
            f"Use the main branch with an origin remote in {repo} before applying."
        )
    if clean_paths and git(repo, "status", "--porcelain", "--", *clean_paths):
        raise RuntimeError(
            f"Commit or stash local changes to the release files in {repo} before applying."
        )


def commit_and_push(repo, paths, message):
    # A path-limited commit keeps unrelated staged changes in the index.
    if git(repo, "status", "--porcelain", "--", *paths):
        staged = git(repo, "diff", "--cached", "--name-only", "--", *paths).splitlines()
        if staged and git(repo, "diff", "--name-only", "--", *staged):
            raise RuntimeError(
                f"Reconcile staged and unstaged release changes in {repo}, then rerun."
            )
        git(repo, "add", "--", *paths)
        run("git", "-C", repo, "commit", "-m", message, "--only", "--", *paths)
    commit = git(repo, "rev-parse", "refs/heads/main")
    if git(repo, "diff", "--name-only", commit, "--", *paths):
        raise RuntimeError(
            f"Release files in {repo} differ from main. Reconcile them and rerun."
        )
    print(f"==> Pushing {repo.name} to origin/main", flush=True)
    run(
        "git",
        "-C",
        repo,
        "push",
        "--no-follow-tags",
        "origin",
        f"{commit}:refs/heads/main",
        env={**os.environ, "GIT_TERMINAL_PROMPT": "0"},
    )
    return commit


def file_hash(path):
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None


def website_scripts():
    public = WEBSITE / "public"
    if not public.is_dir() or public.is_symlink():
        raise RuntimeError(f"Expected a public directory at {public}.")
    paths = [f"public/{name}" for name in INSTALL_SCRIPTS]
    if any((WEBSITE / path).is_symlink() for path in paths):
        raise RuntimeError(f"Expected regular installer scripts in {public}.")
    return paths


def publish_scripts(deploy, commit, previous, support):
    paths = website_scripts()
    copies = []
    for name, relative in zip(INSTALL_SCRIPTS, paths, strict=True):
        target = WEBSITE / relative
        current = file_hash(target)
        entry = git(deploy, "ls-tree", commit, "--", name).partition(" ")[0]
        if entry not in {"100644", "100755"}:
            raise RuntimeError(
                f"Expected a regular {name} in the pushed mn-deploy commit."
            )
        try:
            data = subprocess.check_output(
                ["git", "-C", str(deploy), "cat-file", "blob", f"{commit}:{name}"]
            )
        except subprocess.CalledProcessError as exc:
            raise RuntimeError(
                f"Cannot read {name} from the pushed mn-deploy commit."
            ) from exc
        digest = hashlib.sha256(data).hexdigest()
        if current not in (previous[relative], digest):
            raise RuntimeError(
                f"{target} changed during publishing. Reconcile it and rerun."
            )
        mode = 0o755 if entry == "100755" else 0o644
        if current != digest or stat.S_IMODE(target.stat().st_mode) != mode:
            copies.append((target, data, mode))
    for target, data, mode in copies:
        write_file(target, data, mode=mode)
    commit_and_push(WEBSITE, paths, f"Publish installer scripts for {support}")


def registry_images(args, kind, gar):
    image = docker_image(args, kind)
    rows = gar.run_gcloud(
        args.gcloud, "docker", "images", "list", image, "--include-tags"
    )
    return {
        unquote(row["version"]): row["tags"] for row in rows if row["package"] == image
    }


def record_old_images(args, planned, directory):
    # Record the old tag targets before any repair can move them. Keep this
    # snapshot across retries, including failures after a buildx push.
    snapshot = directory / "old-images.json"
    if snapshot.exists():
        return json.loads(snapshot.read_text())
    gar = module("clean-gar.py")
    images = {}
    for component in planned["components"]:
        kind = component["kind"]
        if kind not in DOCKER_PACKAGES:
            continue
        if (directory / f"{kind}-image.json").exists():
            print(
                f"warning: No pre-repair digest recorded for {kind}; retaining its older images.",
                flush=True,
            )
            continue
        tags = set(docker_tags(args, component))
        images[kind] = [
            digest
            for digest, aliases in registry_images(args, kind, gar).items()
            if DIGEST.fullmatch(digest) and tags.intersection(aliases)
        ]
    write_json(snapshot, images)
    return images


def remove_old_versions(args, planned, old_images, directory):
    from packaging.utils import canonicalize_name
    from packaging.version import Version

    gar = module("clean-gar.py")
    root = f"projects/{args.project}/locations/{args.location}/repositories"
    old = {
        p["name"]: p["version"]
        for p in tomllib.loads(planned["original_index"])["packages"]
    }
    packages = [
        (
            args.python_repository,
            canonicalize_name(p["name"]),
            str(Version(old[p["name"]])),
            str(Version(p["version"])),
        )
        for p in planned["packages"]
    ]
    packages.extend(
        (
            args.npm_repository,
            "mirrorneuron-web-ui",
            c["previous"][1:],
            c["version"][1:],
        )
        for c in planned["components"]
        if c["kind"] == "web-ui"
    )
    deletions = []
    for repo, name, previous, replacement in packages:
        versions = f"{root}/{repo}/packages/{name}/versions/"
        rows = gar.run_gcloud(
            args.gcloud,
            "versions",
            "list",
            f"--project={args.project}",
            f"--location={args.location}",
            f"--repository={repo}",
            f"--package={name}",
        )
        available = {
            unquote(gar.resource_name(row, versions)[len(versions) :]) for row in rows
        }
        if replacement not in available:
            raise RuntimeError(
                f"Replacement GAR version is missing: {name}@{replacement}."
            )
        if previous != replacement and previous in available:
            deletions.append((versions + previous, True))
    for component in planned["components"]:
        kind = component["kind"]
        if not old_images.get(kind):
            continue
        live = registry_images(args, kind, gar)
        metadata = json.loads((directory / f"{kind}-image.json").read_text())
        replacement = metadata["containerimage.digest"]
        if not set(docker_tags(args, component)).issubset(live.get(replacement, [])):
            raise RuntimeError(f"Replacement GAR tags changed for {kind}.")
        versions = f"{root}/{args.docker_repository}/packages/{DOCKER_PACKAGES[kind]}/versions/"
        for digest in old_images[kind]:
            if DIGEST.fullmatch(digest) and digest != replacement and digest in live:
                if live[digest]:
                    print(
                        f"==> Retaining {kind}@{digest} with tags {', '.join(live[digest])}",
                        flush=True,
                    )
                else:
                    deletions.append((versions + digest, False))
    for version, delete_tags in deletions:
        print(f"==> Deleting {version}", flush=True)
        gar.delete_version(
            args.gcloud,
            gar.Deletion(version, ()),
            args.project,
            delete_tags=delete_tags,
        )
    print(f"✓ Removed {len(deletions)} superseded GAR version(s).", flush=True)


def release_options(args):
    return {
        option: getattr(args, option)
        for option in (
            "project",
            "location",
            "python_repository",
            "npm_repository",
            "docker_repository",
            "update_latest",
            "publish_scripts",
            "remove_old_versions",
        )
    }


def complete_release(args, workspace, pending, state):
    planned = state["plan"]
    support = planned["support"]
    deploy = workspace / "mn-deploy"
    check_release_repo(deploy)
    if args.publish_scripts:
        check_release_repo(WEBSITE)
        if (
            git(deploy, "status", "--porcelain", "--", "uninstall.sh")
            or file_hash(deploy / "uninstall.sh") != state["uninstaller"]
        ):
            raise RuntimeError(
                "uninstall.sh changed during publishing. Reconcile it and rerun."
            )
    finish(workspace, planned, state["previous_projects"])
    commit = commit_and_push(
        deploy, list(deploy_changes(planned)), f"Update component support to {support}"
    )
    if args.publish_scripts:
        publish_scripts(deploy, commit, state["website"], support)
    if args.remove_old_versions:
        remove_old_versions(
            args, planned, state["old_images"], pending.parent / state["identity"]
        )
    pending.unlink()
    print(f"✓ Published component updates and pushed support {support}.")
    if planned["metadata"]:
        print(
            "Next: commit the updated pyproject.toml versions in the affected source repositories."
        )


def main():
    parser = argparse.ArgumentParser(
        prog="update-changed-components.sh",
        description=__doc__,
        epilog=(
            "Default is a local preview; no builds, Git fetches, version edits or uploads. "
            "Requires Python 3.12+ with packaging (plus build/twine for --apply), clean committed "
            "component repositories, gcloud, npm/Node for Web UI, and Docker Buildx for images. "
            "Apply commits generated mn-deploy support files and pushes origin/main."
        ),
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Build and verify GAR releases, then commit and push updated pins and support.",
    )
    parser.add_argument(
        "--plan", "--dry-run", action="store_true", help="Preview only (the default)."
    )
    parser.add_argument(
        "--publish-scripts",
        action="store_true",
        help=f"With --apply, copy install.sh and uninstall.sh to {WEBSITE}/public, then commit and push them.",
    )
    parser.add_argument(
        "--remove-old-versions",
        action="store_true",
        help="With --apply --publish-scripts, delete superseded GAR versions after both pushes.",
    )
    parser.add_argument(
        "--only",
        nargs="+",
        choices=["python", "web-ui", "core", "membrane"],
        default=["python", "web-ui", "core", "membrane"],
        help="Limit changed component types.",
    )
    parser.add_argument("--workspace-root", type=Path, default=SCRIPTS.parent.parent)
    parser.add_argument(
        "--project",
        default=os.environ.get("MN_GAR_PROJECT", "mirrorneuron-public-packages"),
    )
    parser.add_argument(
        "--location", default=os.environ.get("MN_GAR_LOCATION", "us-central1")
    )
    parser.add_argument(
        "--python-repository",
        default=os.environ.get("MN_GAR_REPOSITORY", "agent-skills"),
    )
    parser.add_argument(
        "--npm-repository",
        default=os.environ.get("MN_GAR_NPM_REPOSITORY", "mirrorneuron-npm"),
    )
    parser.add_argument("--docker-repository", default="mirrorneuron-runtime")
    parser.add_argument("--platforms", default="linux/amd64,linux/arm64")
    parser.add_argument("--qemu", choices=["auto", "always", "never"], default="auto")
    parser.add_argument(
        "--update-latest",
        action="store_true",
        help="Also move Docker latest tags to repaired images.",
    )
    parser.add_argument("--gcloud", default=os.environ.get("MN_GCLOUD_BIN", "gcloud"))
    parser.add_argument("--docker", default=os.environ.get("MN_DOCKER_BIN", "docker"))
    args = parser.parse_args()
    if args.apply and args.plan:
        parser.error("--apply and --plan/--dry-run are mutually exclusive")
    if (args.publish_scripts or args.remove_old_versions) and not args.apply:
        parser.error(
            "--publish-scripts and --remove-old-versions are apply-only options"
        )
    if args.remove_old_versions and not args.publish_scripts:
        parser.error("--remove-old-versions requires --publish-scripts")
    workspace = args.workspace_root.resolve()
    cache = workspace / "mn-deploy/dist/component-updates"
    if not args.apply:
        update(args, workspace, cache)
        return
    if not (workspace / "mn-deploy").is_dir():
        raise RuntimeError(f"Cannot find mn-deploy in {workspace}.")
    cache.mkdir(parents=True, exist_ok=True)
    with (cache / ".apply.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise RuntimeError(
                "Another component apply is running in this checkout."
            ) from exc
        update(args, workspace, cache)


def update(args, workspace, cache):
    pending = cache / "pending-release.json"
    if pending.exists():
        state = json.loads(pending.read_text())
        print(
            f"==> Pending release finalization for {state['plan']['support']}",
            flush=True,
        )
        if not args.apply:
            print("Next: rerun the original --apply command to finish publishing.")
            return
        if state["options"] != release_options(args):
            raise RuntimeError(
                "Rerun with the original registry and publication options to finish the pending release."
            )
        complete_release(args, workspace, pending, state)
        return
    planned = plan(workspace, set(args.only))
    print(
        f"Core stays {planned['core']}; installer stays {planned['runtime']}.",
        flush=True,
    )
    old = {
        p["name"]: p["version"]
        for p in tomllib.loads(planned["original_index"])["packages"]
    }
    for package in planned["packages"]:
        print(
            f"==> Python {package['name']}: {old[package['name']]} -> {package['version']}",
            flush=True,
        )
    native_app = any(
        p["name"] == "mirrorneuron-computer-use-skill" for p in planned["packages"]
    )
    if native_app:
        print(
            "==> Native mn computer use: verify/publish notarized GAR artifacts before the skill wheel.",
            flush=True,
        )
    for component in planned["components"]:
        action = (
            f"{component['previous']} -> {component['version']}"
            if component["kind"] == "web-ui"
            else f"repair {component['version']} from HEAD"
        )
        print(f"==> {component['kind']}: {action}", flush=True)
    for repo in planned["dirty"]:
        print(
            f"warning: {repo} has uncommitted work; preview uses committed source. Commit or stash before --apply.",
            flush=True,
        )
    if args.apply:
        ensure_sources(workspace, planned)
    if not planned["packages"] and not planned["components"]:
        print("✓ No changed components to publish.")
        return
    print(f"==> New support/package index: {planned['support']}", flush=True)
    if not args.apply:
        print("Next: rerun with --apply to publish this component set.")
        return
    deploy = workspace / "mn-deploy"
    deploy_paths = list(deploy_changes(planned))
    if args.publish_scripts:
        deploy_paths.append("uninstall.sh")
    check_release_repo(deploy, *deploy_paths)
    deploy_head = git(deploy, "rev-parse", "HEAD")
    website = None
    uninstaller = None
    if args.publish_scripts:
        paths = website_scripts()
        check_release_repo(WEBSITE, *paths)
        website = {path: file_hash(WEBSITE / path) for path in paths}
        source = deploy / "uninstall.sh"
        if not source.is_file() or source.is_symlink():
            raise RuntimeError(f"Expected a regular uninstaller at {source}.")
        uninstaller = file_hash(source)
    required = ["PYTHON"] if planned["packages"] else []
    if any(c["kind"] == "web-ui" for c in planned["components"]):
        required.append("NPM")
    if any(c["kind"] != "web-ui" for c in planned["components"]):
        required.append("DOCKER")
        run(args.docker, "info", capture=True)
        run(args.docker, "buildx", "version", capture=True)
    for kind in required:
        repo = {
            "PYTHON": args.python_repository,
            "NPM": args.npm_repository,
            "DOCKER": args.docker_repository,
        }[kind]
        data = json.loads(
            run(
                args.gcloud,
                "artifacts",
                "repositories",
                "describe",
                repo,
                f"--project={args.project}",
                f"--location={args.location}",
                "--format=json",
                capture=True,
            )
        )
        if (
            data["format"] != kind
            or data.get("mode", "STANDARD_REPOSITORY") != "STANDARD_REPOSITORY"
        ):
            raise RuntimeError(f"{repo} must be a standard {kind} repository.")
        if kind == "DOCKER" and data.get("dockerConfig", {}).get("immutableTags"):
            raise RuntimeError(
                "Docker repository has immutable tags; same-tag repair is unavailable."
            )
    run(args.gcloud, "auth", "print-access-token", capture=True)
    identity = hashlib.sha256(
        json.dumps(
            [
                planned,
                args.project,
                args.location,
                args.python_repository,
                args.npm_repository,
                args.docker_repository,
                args.platforms,
                args.update_latest,
            ],
            sort_keys=True,
        ).encode()
    ).hexdigest()[:20]
    directory = cache / identity
    directory.mkdir(parents=True, exist_ok=True)
    old_images = (
        record_old_images(args, planned, directory) if args.remove_old_versions else {}
    )
    build_python(workspace, planned, directory)
    ensure_sources(workspace, planned)
    if native_app:
        run(
            sys.executable,
            SCRIPTS / "publish_computer_use_to_google_artifact_registry.py",
            "--skills-dir",
            workspace / "mn-skills",
            "--project",
            args.project,
            "--location",
            args.location,
            "--gcloud",
            args.gcloud,
            "--apply",
        )
    publish_python(args, planned, directory)
    for component in planned["components"]:
        marker = directory / (component["kind"] + "-published.json")
        if not marker.exists():
            publish_component(args, workspace, component, directory)
            write_json(marker, component)
    ensure_sources(workspace, planned)
    check_release_repo(deploy, *deploy_paths)
    if git(deploy, "diff", "--name-only", deploy_head, "--", *deploy_paths):
        raise RuntimeError(
            "mn-deploy release files changed during publishing. Rerun the preview."
        )
    state = dict(
        plan=planned,
        identity=identity,
        options=release_options(args),
        previous_projects={
            path: (workspace / path).read_text() for path in planned["metadata"]
        },
        website=website,
        uninstaller=uninstaller,
        old_images=old_images,
    )
    write_json(pending, state)
    complete_release(args, workspace, pending, state)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, KeyError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        print(
            "Next: resolve the failure and rerun the same command; completed builds/uploads are reused.",
            file=sys.stderr,
        )
        sys.exit(1)
