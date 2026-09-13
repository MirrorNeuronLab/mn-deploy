# How to Release MirrorNeuron

MirrorNeuron is a multi-repository release. Source tags identify the released
commits, while Google Artifact Registry (GAR) is the sole package and runtime
artifact authority. GitHub tag workflows may remain enabled, but the release
process does not wait for or consume packages produced by them.

## Standard release

Run the orchestrator from `mn-deploy`:

```bash
./release_all.sh --plan  # Preview using local tags; no writes or publishing.
./release_all.sh         # Refresh tags and release changed committed sources.
```

The command:

1. verifies every release worktree is clean, on `main`, and synchronized;
2. selects per-package versions, updates installer defaults, and creates the
   immutable installer-support snapshot before tagging;
3. creates local annotated tags needed by tag-derived builds;
4. builds, publishes, and verifies all artifacts from the local sibling
   worktrees in GAR;
5. pushes the source tags only after GAR verification succeeds; and
6. updates named blueprint dependency pins and records the release.

If publishing fails, the tags remain local and can be reused by a retry as long
as they still point at `HEAD`. A remote release tag is treated as immutable and
causes a new aggregate release attempt to stop.

## GAR layout

All release artifacts live in the `mirrorneuron-public-packages` project in
`us-central1`. GAR requires a repository per artifact format:

- `agent-skills`: standard Python repository for the indexed CLI, API, SDK, agents, skills, and supporting distributions. Public dependencies come directly from PyPI.
- `mirrorneuron-npm`: standard npm repository for the self-contained Web UI build. Public build dependencies come directly from npmjs.
- `mirrorneuron-runtime`: Docker repository for Core and Membrane images.
- `mirrorneuron-binaries`: generic archives managed by their dedicated
  publishers.

Prepare missing repositories and the local Python publishing environment once:

```bash
./setup_google_artifact_registry.sh \
  --project mirrorneuron-public-packages \
  --location us-central1 \
  --repository agent-skills \
  --npm-repository mirrorneuron-npm
```

This changes GAR/IAM state and installs the local publishing virtualenv, so it
is intentionally separate from routine validation.

## Release repositories

The aggregate tag is created in:

```text
mn-api
mn-cli
mn-web-ui
mn-deploy
mn-python-sdk
mn-docs
mn-agents
mn-skills
MirrorNeuron
Membrane
```

All must be clean and synchronized with `origin/main`. Commit and push source
changes before invoking the orchestrator. If an `otterdesk-blueprints` checkout
is present, finalization also requires it to be clean and synchronized.

## Component publishers

The aggregate command invokes these local publishers with `--apply`:

```text
publish_python_packages_to_google_artifact_registry.sh
publish_web_ui_to_google_artifact_registry.sh
publish_public_core_to_google_artifact_registry.sh
publish_public_membrane_to_google_artifact_registry.sh
```

Each publisher also supports a dry run or focused backfill. For example:

```bash
./publish_python_packages_to_google_artifact_registry.sh \
  --python ./.venv-gar-publish/bin/python \
  --project mirrorneuron-public-packages \
  --no-prune

./publish_web_ui_to_google_artifact_registry.sh --version v1.3.43

./publish_public_core_to_google_artifact_registry.sh \
  --apply --version v1.3.43

./publish_public_membrane_to_google_artifact_registry.sh \
  --apply --version v1.3.43 --skip-binary
```

The Python publisher verifies every locally built distribution filename after
upload. The Web UI publisher compares the local tarball integrity with GAR.
The runtime publishers verify the immutable version and `latest` image tags.

## Tags and GitHub workflows

Pushing the source tags can still trigger existing GitHub workflows. Those
workflows are independent side effects: `release_all.sh` does not require
`gh`, inspect workflow status, download workflow artifacts, or verify packages
on PyPI or the public npm registry.

Do not move an already-pushed release tag. Fix the source, choose a new patch
version, and run the release again.

## Post-release pins

Installer defaults are committed before release tags are created, so tagged
installers and support snapshots describe the same package set. After GAR
verification and tag pushes, finalization updates exact requirements by package
name and GAR dependency records in the optional blueprint checkout. Blueprint
identity versions, external package pins, and compatibility ranges are preserved.
The confirmed destinations are appended to `released.md`.

## Automatic and independent versions

Omitting `--version` chooses one patch above the largest numeric release tag
across the release repositories, after fetching remote tags. If committed source
trees have not changed, the command exits without publishing. `released.md`
finalization changes do not trigger another release. `--plan` uses local tags
and committed source only; commit changes before relying on that preview.
An explicit `-v MAJOR.MINOR.PATCH` selects the aggregate release-set tag, not a
forced version for every Python distribution.

Each package index entry records a source fingerprint. Changes to tracked
package inputs or shared repository build files increment that package's patch;
unchanged packages reuse their previous version. Static versions advance
automatically unless already manually increased. SDK and SDK component wheels
remain one version group: the runtime catalog currently derives component
defaults from the SDK version. Other Python packages advance independently.
Core, Membrane images, and Web UI currently retain the aggregate release tag.

The Python publisher rejects dirty or changed sources when a prepared source
fingerprint is present, verifies wheel metadata against the index, and rejects
internal dependency conflicts, including optional blueprint capabilities, before
any upload. Binary installation preserves snapshot package pins, applies explicit
component overrides to the constraints, constrains dependency resolution to the
release inventory, and runs `pip check` before startup. Constraints pin internal
packages; they are not a cross-platform lock of every third-party dependency.

After a failure, use the printed explicit version and `--resume-from` phase.
Do not use automatic version selection to retry a partially published release.
Resumes reject changed deployment tooling or metadata; Python resumes also
require package sources to remain at the prepared tags.

Offline verification:

```bash
../mn-python-sdk/.venv/bin/python -m pytest scripts/test_release_contract.py -q
../mn-python-sdk/.venv/bin/python -m pytest ../mn-system-tests/tests/integration/installer -q
```
