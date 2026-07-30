# How to Release MirrorNeuron

MirrorNeuron is a multi-repository release. The release tag is the public
source of truth for each repository, while `mn-deploy/package-index/` is the
canonical list of Python distributions that the installer can resolve.

## Release checklist

1. Choose one stable version, for example `1.2.29`, and its tag,
   `v1.2.29`.
2. Confirm every repository is on `main`, clean, and synchronized with its
   remote.
3. Update the canonical package index and any component metadata whose
   version is static.
4. Create the versioned installer-support snapshot before tagging
   `mn-deploy`.
5. Create and push the tag in every repository.
6. Wait for the GitHub Actions release-asset workflows, then publish the
   Core and Membrane runtime images from the authenticated local machine.
7. Verify the public registries by exact version.
8. Only after verification, update installer defaults and blueprint
   dependency pins, then commit and push those changes.
9. Append the confirmed destinations to `released.md`.

For the standard release path, use the single-command orchestrator from this
directory:

```bash
./release_all.sh -v 1.2.30
```

It performs the checklist in order and stops before post-release pin updates
if any required public registry verification fails.

## Repositories

The stable release tag is created in all of these repositories:

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

Before tagging, check all worktrees:

```bash
for repo in mn-api mn-cli mn-web-ui mn-deploy mn-python-sdk mn-docs \
  mn-agents otterdesk-blueprints mn-system-tests mn-skills MirrorNeuron \
  Membrane; do
  git -C "$repo" status --short --branch
done
```

## Prepare the release

Update every `version =` entry in
`mn-deploy/package-index/python-packages.toml` to the new package version.
Update any static package versions in component `pyproject.toml` files; tag
derived packages do not need a source-version edit.

For `mn-deploy`, create the support snapshot before creating the tag:

```bash
cd mn-deploy
./save_install_support.sh --version v1.2.29
```

The release workflow validates that both
`install_support/v1.2.29/docker-compose.yml` and
`install_support/v1.2.29/package-index/python-packages.toml` exist. A missing
snapshot fails the deploy release even when the main templates are correct.
Snapshot creation also rejects a Compose template whose default
`MN_WEB_UI_PACKAGE_VERSION` does not match the requested release version.

## Tag all repositories

Run this from the workspace root after all release-preparation commits have
been pushed to `main`:

```bash
release_tag=v1.2.29
repos=(mn-api mn-cli mn-web-ui mn-deploy mn-python-sdk mn-docs mn-agents \
  otterdesk-blueprints mn-system-tests mn-skills MirrorNeuron Membrane)

for repo in "${repos[@]}"; do
  git -C "$repo" tag "$release_tag"
  git -C "$repo" push origin "$release_tag"
done
```

Do not move an already-published tag casually. If a tag must be corrected,
stop and record the reason, update the tag deliberately, and rerun every
tag-driven release that consumed it.

## GitHub Actions releases

Pushing the tags starts the release workflows. Monitor them with:

```bash
for repo in mn-api mn-cli mn-web-ui mn-deploy mn-python-sdk mn-docs \
  mn-system-tests MirrorNeuron Membrane; do
  gh run list --repo "MirrorNeuronLab/$repo" --workflow Release --limit 1
done
```

The relevant publication destinations are:

- `MirrorNeuron`: GitHub Releases for Core OTP archives. The GitHub workflow
  does not publish the Core GAR image.
- `mn-web-ui`: npm.
- `mn-api`, `mn-cli`, and `mn-python-sdk`: PyPI when Trusted Publishing is
  configured, and GAR Python through the package publication flow.
- `Membrane`: PyPI for the Python SDK, GitHub Releases for Rust archives, and
  GAR Docker for the context-engine runtime image.
- `mn-deploy`: GitHub Release installer assets; PyPI is optional when the
  repository's PyPI environment is configured.

## Publish Python distributions to GAR

Use the package index as the source of truth and dry-run first:

```bash
cd mn-deploy
./publish_python_packages_to_google_artifact_registry.sh \
  --python ../.release-venv/bin/python \
  --project mirrorneuron-public-packages \
  --no-prune
```

The helper builds the indexed packages but does not supply Twine credentials
itself. When the dry run is correct, upload the built distributions with GAR
credentials:

```bash
export TWINE_USERNAME=oauth2accesstoken
export TWINE_PASSWORD="$(gcloud auth print-access-token)"
../.release-venv/bin/python -m twine upload \
  --repository-url \
  https://us-central1-python.pkg.dev/mirrorneuron-public-packages/agent-skills/ \
  dist/python-packages/*
```

Verify the count and version metadata:

```bash
gcloud artifacts files list \
  --project=mirrorneuron-public-packages \
  --repository=agent-skills \
  --location=us-central1 \
  --format='value(name)' \
  | awk '/1\.2\.29/ {count++} END {print count+0}'
```

The count should equal the number of generated wheel and source-distribution
files. For the 1.2.29 release, the index contained 52 packages and produced
103 distributions.

## Publish the Membrane GAR runtime image

Membrane runtime images are published from an authenticated local checkout by
the unified release pipeline; its GitHub release workflow does not build or
push Docker images. To publish or backfill an image directly:

```bash
./mn-deploy/publish_public_membrane_to_google_artifact_registry.sh \
  --apply \
  --version v1.2.29 \
  --skip-binary
```

Verify the immutable tag and the `latest` tag in
`us-central1-docker.pkg.dev/mirrorneuron-public-packages/mirrorneuron-runtime/`.

## Publish the Core GAR runtime image

The unified release publishes `mirror-neuron-core` for `linux/amd64` and
`linux/arm64` from the authenticated local machine after the Core tag workflow
passes. It applies `vX.Y.Z`, `X.Y.Z`, and `latest`; binary installs always use
`vX.Y.Z`. The Core GitHub Actions release only publishes the platform-specific
OTP archives.

`release_all.sh` invokes the local helper automatically. To publish or backfill
an exact Core tag directly, run:

```bash
./mn-deploy/publish_public_core_to_google_artifact_registry.sh \
  --apply \
  --version v1.2.30
```

On Apple Silicon, the helper automatically registers pinned QEMU amd64
emulation and supplies Erlang's QEMU-compatible single-mapped JIT setting to
the build. Docker Desktop must be running and allow the privileged, short-lived
`tonistiigi/binfmt` registration container. Use `--qemu always` if the shell is
running under Rosetta and reports an x64 host, or `--qemu never` on a builder
whose amd64 emulation is already managed separately.

The helper uses the current checkout's maintained release Dockerfile with the
requested tag's source tree. This lets compatible build-image fixes apply to
older application tags without changing their application source.

Verify all three tags point to the published multi-platform manifest. The
binary installer retags the immutable image locally as `mirror-neuron-core:latest`
for Docker Compose; `--mode local` still builds that local image from source.

## Update installers and blueprints after publication

Once the public artifacts are confirmed, replace old component pins in:

- `mn-deploy/install.sh` (release defaults, examples, and fallback tags).
- Every blueprint `manifest.json` skill and agent dependency version.
- Blueprint payload `requirements.txt` files.
- Explicit context-engine SDK requirements, such as
  `mirrorneuron-membrane-python-sdk==1.2.29`.
- Blueprint release-test fixtures that assert dependency versions.

Validate the edits:

```bash
bash -n mn-deploy/install.sh
rg -n 'v1\.2\.(27|28)|1\.2\.(27|28)' \
  mn-deploy/install.sh otterdesk-blueprints
git -C mn-deploy diff --check
git -C otterdesk-blueprints diff --check
```

## Record and hand off the release

Append a new dated section to `mn-deploy/released.md`. Record only artifacts
that were actually published, including their exact destination and version.
Do not rewrite an earlier release entry.

Finally, commit and push the installer, blueprint, and release-record changes:

```bash
git -C mn-deploy add install.sh HOW_TO_RELEASE.md released.md
git -C mn-deploy commit -m "Document v1.2.29 release"
git -C mn-deploy push origin main

git -C otterdesk-blueprints add .
git -C otterdesk-blueprints commit -m "Pin blueprint dependencies to 1.2.29"
git -C otterdesk-blueprints push origin main
```
