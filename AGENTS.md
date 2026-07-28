# AGENTS.md

Instructions for coding agents working in this repository. These instructions
apply only to `mn-deploy`.

## Start Here

Read `SPEC.md`, `README.md`, the complete target script, related support files,
and installer regression tests before editing. Check `git status`; installer
work is high impact, so preserve unrelated changes and avoid unrequested live
installation or cleanup.

## Repository Map

- `install.sh`: unified installer for binary, GitHub, and local-source modes.
- `uninstall.sh`: runtime and installed-component removal.
- `server.sh`: installed local service lifecycle.
- `setup.sh`, `prepare_cluster.sh`: local/cluster preparation.
- `docker-compose.yml`: current runtime service template.
- `install_support/<version>/`: immutable release snapshots consumed by
  versioned/URL installs.
- `package-index/python-packages.toml`: published Python package inventory.
- `save_install_support.sh`: creates versioned support snapshots.
- `publish_*.sh`, `setup_google_artifact_registry.sh`: release publishing.
- `scripts/`: validation, release packaging, and explicit state cleanup helpers.

## Installer Rules

- Preserve the three install modes and their boundaries: release/package
  (`binary`), repository (`github`), and sibling checkout (`local`).
- Keep non-interactive defaults deterministic. `--interactive` is the explicit
  prompt-driven path; automation must not unexpectedly block for input.
- Treat component versions, package index entries, Compose templates, and
  `install_support/<version>` as one release contract.
- Do not silently edit an existing historical support snapshot. Create a new
  versioned snapshot for new release behavior.
- Keep state under `MN_HOME`/the documented installed roots. Normalize and
  validate paths before writes or deletion; never broaden cleanup globs.
- Installer and uninstaller operations must be idempotent enough to retry after
  partial failure and must print an actionable next step.
- Never echo credentials or repository/package tokens. Quote shell variables
  and use strict mode in new Bash entrypoints.
- Keep macOS/Linux differences explicit. Do not assume GNU-only flags when a
  script is intended to run on macOS.
- Do not run install, uninstall, publish, registry setup, Redis cleanup, or
  cluster mutation as a routine verification step.

## Cross-Host Repository Sync

- Do not `rsync`, `scp`, or otherwise copy tracked source files into a second
  checkout when the same changes will later arrive there through Git. Commit
  and push from one checkout, then use `git pull --ff-only` on the other host.
- If temporary cross-host source copying is required for testing, reconcile it
  before the next bulk pull. Fetch first and treat local edits as duplicates
  only when the complete tracked working tree matches the fetched remote tip
  and there are no untracked files.
- Preserve a recovery stash before reconciling proven duplicates, fast-forward,
  verify the stash tree equals the new `HEAD`, and only then remove the stash.
  Never use `git reset --hard`, `git checkout --`, or an equivalent destructive
  shortcut for unmatched work.
- A dirty checkout that differs from the fetched remote must stop with an
  actionable instruction to commit, stash, or resolve the work. Automation
  must not guess which side is newer.

## CLI Output Standards

- Default output is concise and action oriented; verbose diagnostics stay
  behind `-v`/`--verbose` where supported.
- Use the established vocabulary: `==>` progress, `✓` success, `warning:` for
  recoverable conditions, `error:` for failures, and `Next:` for follow-up.
- Honor `NO_COLOR`; output must remain meaningful without color.
- Avoid ASCII art, boxes, emojis, inconsistent tokens, and spinners in piped
  output.
- UI-only edits must not change installer behavior or contracts.

## Verification

At minimum, syntax-check every touched shell script:

```bash
bash -n install.sh
bash -n uninstall.sh
find . -path './.git' -prune -o -name '*.sh' -print0 | xargs -0 -n1 bash -n
```

Run the installer contract tests from `mn-system-tests` for behavioral changes.
Use an isolated temporary `MN_HOME` only when a real smoke test is explicitly
authorized, and report any platform/mode not exercised.

## Issue-Fixing Policy

- Fix the root cause in the installer/release contract unless the user asks for
  a temporary workaround.
- Avoid fallback paths or compatibility shims that hide a broken primary mode.
- Keep intentional legacy behavior narrow, documented, and regression-tested.
