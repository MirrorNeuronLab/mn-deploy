#!/usr/bin/env python3
"""Build, sign, notarize and publish mn computer use. Default is a read-only plan."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from urllib.error import HTTPError


def run(command, *, timeout=120, label=None):
    # Notary credentials must never appear in an exception's command or output.
    try:
        result = subprocess.run(
            list(map(str, command)),
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        raise RuntimeError(
            f"{label or command[0]} timed out; rerun to resume"
        ) from None
    if result.returncode:
        raise RuntimeError(f"{label or command[0]} failed (exit {result.returncode})")
    return result.stdout


def notarization_auth(env):
    if env.get("MN_NOTARY_KEYCHAIN_PROFILE"):
        return ["--keychain-profile", env["MN_NOTARY_KEYCHAIN_PROFILE"]]
    if any(env.get(key) for key in ("KEY", "KEY_ID", "ISSUER")):
        if not all(env.get(key) for key in ("KEY", "KEY_ID", "ISSUER")):
            raise ValueError("Notarization requires KEY, KEY_ID and ISSUER")
        return [
            "--key",
            str(Path(env["KEY"]).expanduser().resolve()),
            "--key-id",
            env["KEY_ID"],
            "--issuer",
            env["ISSUER"],
        ]
    if not all(
        env.get(key)
        for key in ("APPLE_ID", "APPLE_APP_SPECIFIC_PASSWORD", "APPLE_TEAM_ID")
    ):
        raise ValueError(
            "Set MN_NOTARY_KEYCHAIN_PROFILE, API key credentials, or Apple ID notarization credentials"
        )
    return [
        "--apple-id",
        env["APPLE_ID"],
        "--password",
        env["APPLE_APP_SPECIFIC_PASSWORD"],
        "--team-id",
        env["APPLE_TEAM_ID"],
    ]


def signing_identity(env, team):
    if env.get("MN_COMPUTER_USE_SIGNING_IDENTITY"):
        return env["MN_COMPUTER_USE_SIGNING_IDENTITY"]
    import re

    identities = run(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"])
    matches = re.findall(
        r'([A-F0-9]{40})\s+"Developer ID Application:[^"]+\('
        + re.escape(team)
        + r'\)"',
        identities,
    )
    if not matches:
        raise RuntimeError(
            "No Developer ID Application identity for the native app's signing team"
        )
    return matches[0]


def verify_zip(distribution, archive, architecture):
    with archive.open("rb") as source:
        digest = hashlib.file_digest(source, "sha256").hexdigest()
    document = {
        "schema_version": 1,
        "source_sha256": distribution._digest(),
        "app_version": distribution.app_version(),
        "architecture": architecture,
        "filename": archive.name,
        "sha256": digest,
        "size": archive.stat().st_size,
        "team_id": distribution.TEAM_ID,
        "bundle_id": distribution.BUNDLE_ID,
    }
    distribution.validate_manifest(document, architecture)
    distribution.validate_archive(archive, document)
    with tempfile.TemporaryDirectory(prefix="mn-computer-use-verify-") as temporary:
        run(["/usr/bin/ditto", "-x", "-k", archive, temporary])
        app = Path(temporary) / distribution.APP_NAME
        distribution.verify_release(app, architecture)
        run(
            ["/usr/bin/xcrun", "stapler", "validate", app],
            label="Stapled notarization ticket verification",
        )
    return document


def build(distribution, archive, architecture):
    from mn_computer_use_skill.runtime import build_app

    auth = notarization_auth(os.environ)
    identity = signing_identity(os.environ, distribution.TEAM_ID)
    print(f"==> Building and notarizing macOS {architecture}", flush=True)
    # Retain the in-flight app/submission for retry after an Apple timeout.
    work = archive.parent / (architecture + "-notarization")
    work.mkdir(parents=True, exist_ok=True)
    app = work / distribution.APP_NAME
    submission_file = work / "submission.json"
    if not submission_file.exists():
        build_app(app, signing_identity=identity, architecture=architecture)
        run(
            [
                "/usr/bin/ditto",
                "-c",
                "-k",
                "--sequesterRsrc",
                "--keepParent",
                app,
                work / "submission.zip",
            ]
        )
        submission = json.loads(
            run(
                [
                    "/usr/bin/xcrun",
                    "notarytool",
                    "submit",
                    work / "submission.zip",
                    *auth,
                    "--output-format",
                    "json",
                ],
                timeout=180,
                label="Apple notarization submission",
            )
        )
        submission_file.write_text(json.dumps(submission) + "\n")
    submission = json.loads(submission_file.read_text())
    print(f"==> Waiting for Apple notarization {submission['id']}", flush=True)
    result = json.loads(
        run(
            [
                "/usr/bin/xcrun",
                "notarytool",
                "wait",
                submission["id"],
                *auth,
                "--timeout",
                "20m",
                "--output-format",
                "json",
            ],
            timeout=1230,
            label="Apple notarization",
        )
    )
    if result.get("status") != "Accepted":
        raise RuntimeError(
            f"Apple did not accept submission {submission['id']}; inspect it with notarytool log"
        )
    (work / "result.json").write_text(json.dumps(result) + "\n")
    run(
        ["/usr/bin/xcrun", "stapler", "staple", app],
        label="Stapling notarization ticket",
    )
    run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, archive])
    verify_zip(distribution, archive, architecture)
    # Avoid leaving duplicate app identities for LaunchServices to discover.
    import shutil

    shutil.rmtree(app)


def publish(args, distribution, architecture):
    name = distribution.asset_name(architecture)
    archive = args.output_dir / name
    metadata = args.output_dir / (name + ".json")
    scope = dict(
        project=args.project, location=args.location, repository=args.repository
    )
    with tempfile.TemporaryDirectory(prefix="mn-computer-use-gar-") as temporary:
        remote_metadata = Path(temporary) / metadata.name
        try:
            distribution.download(
                distribution.download_url(metadata.name, **scope),
                remote_metadata,
                16384,
            )
        except HTTPError as exc:
            if exc.code != 404:
                raise
        else:
            document = distribution.validate_manifest(
                json.loads(remote_metadata.read_bytes()), architecture
            )
            remote_zip = Path(temporary) / name
            distribution.download(
                distribution.download_url(name, **scope),
                remote_zip,
                distribution.MAX_ARCHIVE,
            )
            distribution.validate_archive(remote_zip, document)
            verify_zip(distribution, remote_zip, architecture)
            print(f"✓ Verified existing GAR release: {name}", flush=True)
            return
    if not archive.exists():
        build(distribution, archive, architecture)
    document = verify_zip(distribution, archive, architecture)
    metadata.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
    flags = [
        f"--project={args.project}",
        f"--location={args.location}",
        f"--repository={args.repository}",
        f"--package={distribution.PACKAGE}",
        f"--version={distribution.release_version()}",
    ]
    # Upload the archive first and the readiness manifest last. Existing immutable
    # files must match byte-for-byte; never replace or silently skip conflicts.
    for path in (archive, metadata):
        with tempfile.TemporaryDirectory(
            prefix="mn-computer-use-published-"
        ) as temporary:
            remote = Path(temporary) / path.name
            url = distribution.download_url(path.name, **scope)
            try:
                distribution.download(url, remote, distribution.MAX_ARCHIVE)
            except HTTPError as exc:
                if exc.code != 404:
                    raise
                run(
                    [
                        args.gcloud,
                        "artifacts",
                        "generic",
                        "upload",
                        *flags,
                        f"--source={path}",
                    ],
                    timeout=300,
                    label="GAR upload",
                )
                distribution.download(url, remote, distribution.MAX_ARCHIVE)
            if remote.read_bytes() != path.read_bytes():
                raise RuntimeError(f"Immutable GAR artifact differs: {path.name}")
    print(f"✓ Published and verified {name}", flush=True)


def main():
    if sys.version_info < (3, 12):
        raise RuntimeError("Python 3.12 or newer is required")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument(
        "--skills-dir",
        type=Path,
        default=Path(__file__).resolve().parents[2] / "mn-skills",
    )
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument(
        "--architectures",
        nargs="+",
        choices=["arm64", "x86_64"],
        default=["arm64", "x86_64"],
    )
    parser.add_argument("--project", default="mirrorneuron-public-packages")
    parser.add_argument("--location", default="us-central1")
    parser.add_argument("--repository", default="mirrorneuron-binaries")
    parser.add_argument("--gcloud", default=os.environ.get("MN_GCLOUD_BIN", "gcloud"))
    args = parser.parse_args()
    sys.path.insert(0, str(args.skills_dir / "computer_use_skill/src"))
    from mn_computer_use_skill import distribution

    print(
        f"==> mn computer use {distribution.release_version()} ({', '.join(args.architectures)})",
        flush=True,
    )
    if not args.apply:
        print(
            "Next: add --apply on a Mac with Developer ID/notarization credentials to publish to public GAR."
        )
        return
    from mn_computer_use_skill.runtime import require_mac

    require_mac()
    # IAM/repository provisioning stays with registry setup, not release retries.
    info = json.loads(
        run(
            [
                args.gcloud,
                "artifacts",
                "repositories",
                "describe",
                args.repository,
                f"--project={args.project}",
                f"--location={args.location}",
                "--format=json",
            ]
        )
    )
    if info.get("format") != "GENERIC":
        raise RuntimeError("The native app requires a public GENERIC GAR repository")
    args.output_dir = (
        args.output_dir
        or Path(__file__).resolve().parents[1]
        / "dist/computer-use"
        / distribution.release_version()
    )
    args.output_dir.mkdir(parents=True, exist_ok=True)
    for architecture in args.architectures:
        publish(args, distribution, architecture)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
        # Do not render subprocess arguments, Apple credentials or HTTP headers.
        print(
            f"error: mn computer use release failed ({type(exc).__name__}): "
            + (
                str(exc)
                if isinstance(exc, (ValueError, RuntimeError))
                else "check signing, notarization and GAR access"
            ),
            file=sys.stderr,
        )
        sys.exit(1)
