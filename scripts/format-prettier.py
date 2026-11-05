"""Run the repository's Prettier hook with --write on its pending push files.

Invoked through the pinned pre-commit environment by git_commit_push_all.sh.
Reuse its classifier and Node environment so versions, file types and exclusions
stay identical to the normal hook. Do not stage files or change Git history.
"""

from __future__ import annotations

import os
from pathlib import Path
import shlex
import subprocess
import sys

from pre_commit.all_languages import languages
from pre_commit.clientlib import load_config
from pre_commit.commands.run import Classifier
from pre_commit.repository import all_hooks, install_hook_envs
from pre_commit.store import Store


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


def main(remote_ref: str) -> int:
    config_path = Path(".pre-commit-config.yaml")
    if not config_path.is_file():
        return 0
    config = load_config(str(config_path))
    config["repos"] = [
        {**repo, "hooks": [hook for hook in repo["hooks"] if hook["id"] == "prettier"]}
        for repo in config["repos"]
        if any(hook["id"] == "prettier" for hook in repo["hooks"])
    ]
    classifier = Classifier.from_config(
        pending_files(remote_ref), config["files"], config["exclude"]
    )
    store = Store()
    for hook in all_hooks(config, store):
        filenames = tuple(classifier.filenames_for_hook(hook))
        if not filenames:
            continue
        entry = shlex.split(hook.entry)
        if entry[0] != "prettier" or not hook.pass_filenames:
            print(
                "error: --prettier requires a Prettier hook accepting filenames.",
                file=sys.stderr,
            )
            return 1
        args = tuple(
            arg
            for arg in (*entry[1:], *hook.args)
            if arg not in {"--check", "-c", "--list-different", "-l", "--write", "-w"}
        )
        install_hook_envs([hook], store)
        print(f"==> Prettier: formatting {len(filenames)} pending file(s)", flush=True)
        language = languages[hook.language]
        with language.in_env(hook.prefix, hook.language_version):
            code, output = language.run_hook(
                hook.prefix,
                "prettier",
                (*args, "--write", "--"),
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
    raise SystemExit(main(sys.argv[1]))
