"""Apply selected repository formatters to files in the pending push."""

from __future__ import annotations

import os
from pathlib import Path
import shlex
import subprocess
import sys

from pre_commit.all_languages import languages
from pre_commit.clientlib import load_config
from pre_commit.commands.run import Classifier
from pre_commit.hook import Hook
from pre_commit.repository import all_hooks, install_hook_envs
from pre_commit.store import Store


FORMAT_TYPES = {"prettier": ("markdown",), "ruff-format": ("python", "pyi")}


def pending_files(remote_ref: str) -> list[str]:
    commands = (
        ["git", "diff", "--name-only", "--diff-filter=ACMRT", "-z", remote_ref, "--"],
        ["git", "ls-files", "--others", "--exclude-standard", "-z"],
    )
    return sorted(
        {
            os.fsdecode(name)
            for command in commands
            for name in subprocess.check_output(command).split(b"\0")
            if name
        }
    )


def write_command(hook: Hook) -> tuple[str, ...]:
    command = (*shlex.split(hook.entry), *hook.args)
    if not hook.pass_filenames:
        raise ValueError(f"{hook.id} must accept filenames to format pending files")
    if hook.id == "prettier" and command[:1] == ("prettier",):
        mode_flags = {"--check", "-c", "--list-different", "-l", "--write", "-w"}
        write_flags = ("--write",)
    elif hook.id == "ruff-format" and command[:2] == ("ruff", "format"):
        mode_flags = {"--check", "--diff"}
        write_flags = ()
    else:
        raise ValueError(f"unsupported {hook.id} formatter entry: {hook.entry}")
    args = [arg for arg in command if arg not in mode_flags and arg != "--"]
    return (*args, *write_flags, "--")


def main(remote_ref: str, formatters: set[str]) -> int:
    config_path = Path(".pre-commit-config.yaml")
    if not config_path.is_file():
        return 0
    config = load_config(str(config_path))
    config["repos"] = [
        {**repo, "hooks": [hook for hook in repo["hooks"] if hook["id"] in formatters]}
        for repo in config["repos"]
        if any(hook["id"] in formatters for hook in repo["hooks"])
    ]
    if not config["repos"]:
        return 0
    classifier = Classifier.from_config(
        pending_files(remote_ref), config["files"], config["exclude"]
    )
    store = Store()
    for hook in all_hooks(config, store):
        filenames = tuple(
            classifier.by_types(
                classifier.filenames_for_hook(hook), (), FORMAT_TYPES[hook.id], ()
            )
        )
        if not filenames:
            continue
        try:
            entry, *args = write_command(hook)
        except ValueError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 1
        install_hook_envs([hook], store)
        print(f"==> Running {hook.id} on pending files ({len(filenames)})", flush=True)
        language = languages[hook.language]
        with language.in_env(hook.prefix, hook.language_version):
            code, output = language.run_hook(
                hook.prefix,
                entry,
                args,
                filenames,
                is_local=hook.src == "local",
                require_serial=hook.require_serial,
                color=False,
            )
        sys.stdout.buffer.write(output)
        sys.stdout.buffer.flush()
        if code:
            return code
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1], set(sys.argv[2:])))
