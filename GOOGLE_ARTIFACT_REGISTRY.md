# Google Artifact Registry Publishing

This runbook publishes every package listed in
`package-index/python-packages.toml` to Google Artifact Registry (GAR). The
index is the source of truth for publishable Python packages, including
`mn-skills/*`, Membrane packages, and Synapse packages.

Python distributions, Docker images, and generic release archives use
different GAR repository formats. A single GAR repository cannot serve more
than one of those formats.

## Current Registry

- Project: `mirrorneuron-public-packages`
- Location: `us-central1`
- `agent-skills` (Python): the current public simple index for all indexed
  Python distributions:
  `https://us-central1-python.pkg.dev/mirrorneuron-public-packages/agent-skills/simple/`
- `mirrorneuron-runtime` (Docker): the public runtime-image repository. Core
  and Membrane publish here as
  `us-central1-docker.pkg.dev/mirrorneuron-public-packages/mirrorneuron-runtime/mirror-neuron-core:<tag>`
  and
  `us-central1-docker.pkg.dev/mirrorneuron-public-packages/mirrorneuron-runtime/membrane-context-engine:<tag>`.
- `mirrorneuron-binaries` (Generic): public binary release archives.

The binary installer downloads the Python SDK, CLI, API, Membrane Python SDK,
agents, and skills from `agent-skills`; it pulls the immutable Core and Membrane
engine images from `mirrorneuron-runtime`. The Web UI is published to npm.

## Runtime Image Release Contract

For release tag `v1.2.27`, the local runtime publishers publish immutable and
convenience tags to the **Docker** `mirrorneuron-runtime` repository:

```text
us-central1-docker.pkg.dev/mirrorneuron-public-packages/mirrorneuron-runtime/mirror-neuron-core:v1.2.27
us-central1-docker.pkg.dev/mirrorneuron-public-packages/mirrorneuron-runtime/mirror-neuron-core:1.2.27
us-central1-docker.pkg.dev/mirrorneuron-public-packages/mirrorneuron-runtime/mirror-neuron-core:latest
us-central1-docker.pkg.dev/mirrorneuron-public-packages/mirrorneuron-runtime/membrane-context-engine:v1.2.27
us-central1-docker.pkg.dev/mirrorneuron-public-packages/mirrorneuron-runtime/membrane-context-engine:1.2.27
us-central1-docker.pkg.dev/mirrorneuron-public-packages/mirrorneuron-runtime/membrane-context-engine:latest
```

Binary installs select the release tag form (`:v1.2.27`). Do not point a
runtime image at the Python `agent-skills` repository.

Verify a published release with:

```bash
for image in mirror-neuron-core membrane-context-engine; do
  $HOME/google-cloud-sdk/bin/gcloud artifacts docker tags list \
    "us-central1-docker.pkg.dev/mirrorneuron-public-packages/mirrorneuron-runtime/${image}" \
    --format='table(tag,version,updateTime)' \
    --sort-by='~updateTime'
done
```

The standard `release_all.sh` flow publishes the Core image from the local
release machine after the Core GitHub Release workflow finishes. GitHub Actions
builds the Core OTP archives but does not publish the Core GAR image.

## Requested Python Namespace Split

`mirrorneuron-runtime` already exists as a Docker repository, so GAR cannot
also use that exact name for Python distributions. The proposed separate
Python repositories are therefore:

| Package family | Python GAR repository | Notes |
| --- | --- | --- |
| Core-adjacent runtime packages: `mirrorneuron-python-sdk`, `mirrorneuron-cli`, `mirrorneuron-api`, and the Membrane Python SDK | `mirrorneuron-runtime-python` | Core and Membrane runtime images remain Docker images in `mirrorneuron-runtime`. |
| `mn-skills/*` packages | `mirrorneuron-skills` | Python repository. |
| `mn-agents/*` packages | `mirrorneuron-agents` | Python repository. |

This is a planned migration, not the current production layout. The installer
and package index currently address the single `agent-skills` Python repository.
Before creating or switching to the three repositories, update the publisher
and installer to resolve an index entry's repository by package family, publish
each group, and validate installs against all three public simple indexes.

The repository is intended to be public read-only. The project has a
project-level domain-restriction exception, and the repository IAM policy grants
`roles/artifactregistry.reader` to `allUsers`.

## Auth

Publishing requires both normal `gcloud` auth and Application Default
Credentials because Twine uses Google's Artifact Registry keyring backend.

```bash
$HOME/google-cloud-sdk/bin/gcloud auth login
$HOME/google-cloud-sdk/bin/gcloud auth application-default login
$HOME/google-cloud-sdk/bin/gcloud auth application-default set-quota-project mirrorneuron-public-packages
```

Use the full `gcloud` path above if the SDK is not on `PATH`.

## One-Time Setup

Run this from `mn-deploy`:

```bash
cd $HOME/Projects/mirror-neuron-set/mn-deploy

PATH="$HOME/google-cloud-sdk/bin:$PATH" \
./setup_google_artifact_registry.sh \
  --project mirrorneuron-public-packages \
  --location us-central1 \
  --repository agent-skills
```

The setup script verifies the repo, checks auth, creates
`.venv-gar-publish/`, and installs:

- `build`
- `twine`
- `keyring`
- `keyrings.google-artifactregistry-auth`

## Dry Run

Always run the dry run first. It builds all indexed packages, runs
`twine check`, generates `local-python-index/`, lists remote GAR packages, and
prints stale package names that would be deleted. It does not upload or delete.

```bash
PATH="$HOME/google-cloud-sdk/bin:$PATH" \
./publish_python_packages_to_google_artifact_registry.sh \
  --project mirrorneuron-public-packages \
  --location us-central1 \
  --repository agent-skills
```

Expected shape:

- `Indexed packages: 33`
- `Stale remote packages: 0` unless intentionally pruning
- `dist/python-packages/` contains built wheels/sdists
- `local-python-index/simple/` contains a local PEP 503-style index

Warnings from `twine check` about missing long descriptions are currently
non-fatal for some skill packages. Fix them package by package when polishing
package metadata.

## Publish

Only run `--apply` after the dry run passes and the package list is expected.
This uploads built distributions that are missing from GAR and deletes GAR
package names that are not present in the local package index.

```bash
PATH="$HOME/google-cloud-sdk/bin:$PATH" \
./publish_python_packages_to_google_artifact_registry.sh \
  --apply \
  --project mirrorneuron-public-packages \
  --location us-central1 \
  --repository agent-skills
```

Pruning is package-level: the script removes remote package names missing from
`package-index/python-packages.toml`, but it does not delete old versions of a
package that remains indexed. Package names are compared by their canonical
Python package name, so GAR and local spelling differences in `-`, `_`, or `.`
do not affect pruning.

GAR's Python repository endpoint does not support Twine's `--skip-existing`.
The publish script intentionally omits that flag and compares GAR file listings
before upload so reruns can complete a partially published version without
resending files that already exist.

## Public Membrane Binaries And Docker Images

Membrane runtime publishing uses the same public GAR project:
`mirrorneuron-public-packages`.

The dedicated publisher is:

```bash
./publish_public_membrane_to_google_artifact_registry.sh --version v1.2.8
```

Dry run is the default. To publish:

```bash
./publish_public_membrane_to_google_artifact_registry.sh \
  --apply \
  --version v1.2.8
```

Defaults:

- Rust binary archives: `us-central1-generic.pkg.dev/mirrorneuron-public-packages/mirrorneuron-binaries/membrane:v1.2.8`
- Docker runtime image: `us-central1-docker.pkg.dev/mirrorneuron-public-packages/mirrorneuron-runtime/membrane-context-engine:v1.2.8`
- Docker platforms: `linux/amd64,linux/arm64`

The script creates the generic and Docker repositories if needed, grants
`roles/artifactregistry.reader` to `allUsers` with `--condition=None`, uploads
generic Rust release archives with `gcloud artifacts generic upload
--skip-existing`, and pushes Docker images with `docker buildx build --push`.

If GitHub release assets were already built, upload those instead of building a
local host-only Rust archive:

```bash
./publish_public_membrane_to_google_artifact_registry.sh \
  --apply \
  --version v1.2.8 \
  --binary-artifacts-dir /path/to/membrane-release-assets
```

This publisher uses normal `gcloud auth login` credentials. The Python
publisher also needs Application Default Credentials because Twine uses the
Google Artifact Registry keyring backend.

## Public Core Docker Image

The Core runtime image is published locally from the exact requested Core Git
tag:

```bash
./publish_public_core_to_google_artifact_registry.sh \
  --apply \
  --version v1.2.30
```

The publisher pushes a multi-platform `linux/amd64,linux/arm64` manifest with
the `vX.Y.Z`, `X.Y.Z`, and `latest` tags. On an ARM64 release machine it
automatically registers pinned QEMU amd64 emulation. Erlang build commands use
single-mapped JIT memory during emulation because QEMU user mode cannot execute
the normal dual-mapped JIT memory layout.

Docker Desktop and Docker Buildx are required. The QEMU registration uses a
short-lived privileged `tonistiigi/binfmt` container. Pass `--qemu always` when
an Apple Silicon shell reports x64 through Rosetta, or `--qemu never` when the
builder's emulation is managed separately.

## Public Otterdesk Desktop Packages

Otterdesk desktop app packages can be published manually to the same public GAR
project without GitHub Actions:

```bash
./publish_public_otterdesk_to_google_artifact_registry.sh \
  --apply \
  --version v1.2.8
```

By default the script uploads existing package files from
`../otterdesk-desktop-app/dist/` into:

`us-central1-generic.pkg.dev/mirrorneuron-public-packages/otterdesk-desktop/otterdesk:v1.2.8`

Build locally first when needed:

```bash
cd ../otterdesk-desktop-app
npm run build
npm run dist:mac:all
cd ../mn-deploy
./publish_public_otterdesk_to_google_artifact_registry.sh --apply --version v1.2.8
```

Download a file through GAR:

```bash
gcloud artifacts generic download \
  --project=mirrorneuron-public-packages \
  --location=us-central1 \
  --repository=otterdesk-desktop \
  --package=otterdesk \
  --version=v1.2.8 \
  --name=otterdesk-v1.2.8-SHA256SUMS.txt \
  --destination=/tmp/otterdesk-download
```

## Install From Public GAR

Example direct install:

```bash
python -m pip install \
  --index-url https://us-central1-python.pkg.dev/mirrorneuron-public-packages/agent-skills/simple/ \
  --extra-index-url https://pypi.org/simple \
  mirrorneuron-cli
```

Binary installer example:

```bash
./install.sh --mode binary
```

Skip the indexed skill catalog:

```bash
./install.sh --mode binary --no-all-skills
```

## Package Index Fields

Each entry in `package-index/python-packages.toml` has:

- `name`: package name uploaded to GAR
- `path`: package directory relative to the `mirror-neuron-set` workspace root
- `publish_group`: coarse release grouping, such as `runtime`, `skill`,
  `membrane`, or `synapse`
- `installer_groups`: groups consumed by `install.sh --mode binary`
- `default_extras`: optional extras installed by default for a group
- `binary_default`: whether the package is part of the default binary runtime
- `build_formats`: optional list of build artifacts, defaulting to
  `["sdist", "wheel"]`

`mirrorneuron-membrane-python-sdk` is intentionally `build_formats = ["wheel"]`
because its custom `mn_build_backend` implements `build_wheel` but not
`build_sdist`.

## Public Read-Only IAM

The public repo requires:

```bash
$HOME/google-cloud-sdk/bin/gcloud org-policies set-policy /private/tmp/public-registry-drs-exception.yaml \
  --project=mirrorneuron-public-packages

$HOME/google-cloud-sdk/bin/gcloud artifacts repositories add-iam-policy-binding agent-skills \
  --project=mirrorneuron-public-packages \
  --location=us-central1 \
  --member=allUsers \
  --role=roles/artifactregistry.reader \
  --condition=None
```

The `--condition=None` flag avoids conditional-policy prompts and was required
when the public reader binding was created.

Verify:

```bash
$HOME/google-cloud-sdk/bin/gcloud artifacts repositories get-iam-policy agent-skills \
  --project=mirrorneuron-public-packages \
  --location=us-central1 \
  --format='table(bindings.role,bindings.members)'
```

Expected public binding:

```text
ROLE                               MEMBERS
['roles/artifactregistry.reader']  [['allUsers']]
```

## Troubleshooting

If `setup_google_artifact_registry.sh` says ADC is missing, rerun:

```bash
$HOME/google-cloud-sdk/bin/gcloud auth application-default login
$HOME/google-cloud-sdk/bin/gcloud auth application-default set-quota-project mirrorneuron-public-packages
```

If adding `allUsers` fails with `constraints/iam.allowedPolicyMemberDomains`,
the project-level org-policy exception is missing or has not propagated.

If publishing fails with:

```text
ERROR UnsupportedConfiguration: ... does not have support for the following features: --skip-existing
```

make sure `publish_python_packages_to_google_artifact_registry.sh` does not pass
`--skip-existing` to `twine upload`.

If publishing fails with:

```text
AttributeError: module 'mn_build_backend' has no attribute 'build_sdist'
```

make sure the Membrane SDK entry in `package-index/python-packages.toml` still
has:

```toml
build_formats = ["wheel"]
```

If anonymous `/simple/` returns `404` before publishing, that can simply mean
the repository is empty. After publishing, package pages should be visible to
public pip clients.
