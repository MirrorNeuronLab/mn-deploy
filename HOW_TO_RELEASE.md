# How to Release MirrorNeuron

MirrorNeuron is a multi-repository release. Source tags identify the released
commits, while Google Artifact Registry (GAR) is the sole package and runtime
artifact authority. GitHub tag workflows may remain enabled, but the release
process does not wait for or consume packages produced by them.

## Standard release

Run the orchestrator from `mn-deploy`:

```bash
./release_all.sh -v 1.3.43
```

The command:

1. verifies every release worktree is clean, on `main`, and synchronized;
2. prepares package metadata and the immutable installer-support snapshot;
3. creates local annotated tags needed by tag-derived builds;
4. builds, publishes, and verifies all artifacts from the local sibling
   worktrees in GAR;
5. pushes the source tags only after GAR verification succeeds; and
6. updates installer and blueprint pins and records the release.

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
otterdesk-blueprints
mn-system-tests
mn-skills
MirrorNeuron
Membrane
```

All must be clean and synchronized with `origin/main`. Commit and push release
preparation before invoking the orchestrator.

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

After GAR verification and tag pushes, the orchestrator updates installer
defaults and blueprint dependency pins, commits those changes, and appends the
confirmed GAR destinations to `released.md`. Record only artifacts that were
actually verified.
