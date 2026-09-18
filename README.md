# MirrorNeuron Deploy

`mn-deploy` contains the unified installer and local service scripts for MirrorNeuron.
By default, `install.sh` installs released artifacts and Python packages.

## Installer compatibility fix (unreleased)

Installers on macOS Bash 3.2 now handle empty arrays under strict mode, including
reset with no remaining options, empty Python component selections, and optional
wheel-search arguments. The optional Ubuntu privilege prefix is also safe when
running as root. All three install modes retain argument boundaries and defaults.

## Reinstall and macOS paths (unreleased)

Release this installer together with the CLI change that resolves sidecars from
`MN_HOME/venv`; older CLI wheels still look under `~/.local/share/mn_venv`.

Normal reinstall preserves runtime data in place, including read-only directories,
symlinks, native-resource records, and OpenShell state. It never copies job data
into the macOS temporary directory or removes the runtime home. A failed install
can be retried with the same command; `--reset` remains explicitly destructive.

Installer-managed tools and files now default to `~/.mn`: `bin`, `venv`, `python`,
`uv`, `tmp`, `cache`, and `.config/openshell-mirror-neuron`. `MN_HOME` relocates
this tree. Existing tools under `~/.local` are left untouched; installation
creates the new environment instead of moving a virtual environment with stale
absolute paths. Explicit tool-directory overrides remain supported.

The installer writes shell setup to `~/.mn/env` without editing shell profiles.
Run `source ~/.mn/env` to use the commands in your current terminal. You can add
that command to your shell profile yourself for future terminals.

OpenShell runs through the managed containers in every install mode; the
installer does not run the upstream host package installer.

Docker must already be running. When Model Runner is required but disabled, the
installer enables it with `docker desktop enable model-runner`. Docker Desktop
may request the platform permission needed to update that setting. Docker
manages its own images, volumes, and platform permissions outside `MN_HOME`.

## Quick Start

Inspect installer options:

```bash
./install.sh --help
```

Detect an existing runtime without installing or changing anything:

```bash
./install.sh --detect-only
```

The command exits successfully after printing one JSON object. `status` is
`not_installed`, `stopped`, `running`, or `docker_not_running`. The last status
means an install was found but the Docker daemon was unavailable, so runtime
`running` is `null`. `docker_installed` and `docker_running` report Docker's
state separately. `version` is the installed Core release when it can be
determined, otherwise `null`.

Install the local runtime:

```bash
./install.sh
```

When the installer starts the runtime, it forwards the final
`Runtime node ready` block from `mn runtime start`. That block contains the
advertised endpoint, the active federation join token, and the exact
`mn node add` command for connecting another independently installed Core.
Treat the token and captured installer output as credentials.
For the default gRPC port (`55051`), that command omits `--grpc-port`; it is
shown only when the advertised endpoint uses a non-default port.

Install a specific release:

```bash
./install.sh --version v1.2.8
```

Install from the published URL:

```bash
curl -fsSL https://mirrorneuron.io/install.sh | bash
```

Ask before each install choice:

```bash
./install.sh --interactive
```

Reset all existing runtime data and perform a fresh install:

```bash
./install.sh --reset
```

Reset is destructive and always asks you to type the exact uppercase text
`YES`, even when `--yes` is also passed. It deletes and recreates `MN_HOME`
(default `~/.mn`), removes the managed Python virtual environment at
`~/.mn/venv`, clears Redis, and removes the MirrorNeuron Docker
Compose containers and persistent volumes before the selected install mode
runs.

Install from GitHub repositories:

```bash
./install.sh --mode github
```

Check or control installed services:

```bash
./server.sh status
./server.sh start
./server.sh stop
```

Clear runtime Redis state:

```bash
./scripts/clear-redis.sh --yes
```

Commit and push changes across sibling development repositories:

```bash
./git_commit_push_all.sh -m "Describe the update"
```

The bulk helper fetches the current branch and all remote tags before updating.
If a checkout contains uncommitted tracked files that are already
byte-identical to the fetched remote tip, it uses a recovery stash,
fast-forwards, verifies the trees match, and removes the redundant stash. It
stops without changing unique, untracked, or divergent work. For cross-host
development, commit and push on one host and use `git pull --ff-only` plus
`git fetch origin --tags` on the other; do not copy tracked files between
checkouts that will later receive the same commit.

Run its isolated Git regression test with:

```bash
./scripts/test-git-commit-push-all.sh
```

## Details

- [Google Artifact Registry Python Publishing](./GOOGLE_ARTIFACT_REGISTRY.md)
- [Released Package Inventory](./released.md)
- [MirrorNeuron Component Guide](../mn-docs/component-guide.md#deployment-scripts)
- [Installation](../mn-docs/installation.md)
- [Docker and OpenShell for Blueprints](../mn-docs/docker_and_openshell_for_blueprints.md)
- [Security Model](../mn-docs/security.md)

## Notes

- Default runtime state is stored under `~/.mn`. The installer also keeps a shell
  environment file for both MirrorNeuron and OtterDesk at `~/.mn/env`.
- Generated Compose settings are stored in `~/.mn/docker-compose.env`. Binary and
  GitHub installs default to `MN_ENV=prod` and `MN_USE_LOCAL_SKILLS=0`; local
  source installs enable local skills explicitly. User-provided values override
  these defaults.
- Every installation starts the same federation-capable runtime; there is no
  worker-only install or runtime mode.
- LiteLLM binds to a federation-reachable interface by default so an
  authenticated peer gateway can route remote model requests through it.
  Restrict port `4000` to trusted LAN/VPN peers with the host firewall; agents
  still call their owner Core's LiteLLM gateway first.
- If the default Blueprint Web UI range (`61000`–`61049`) conflicts with a
  local service, set `MN_BLUEPRINT_WEB_UI_PORT_START` and
  `MN_BLUEPRINT_WEB_UI_PORT_END` for one local install. The selected range is
  retained by later local-source refreshes unless explicitly overridden.
- The Syncthing sidecar is forced into LAN-only mode before every start,
  including when it reuses an existing configuration. Relay and global
  discovery connections, NAT/STUN traversal, usage reporting, automatic
  upgrade checks, and crash reporting are disabled; configured LAN or VPN peer
  addresses continue to work.
- In binary mode, the `mn` and `mn-api` commands are linked under `~/.mn/bin`.
  Run `source ~/.mn/env` to add that directory to your current shell.
- Redis defaults to the Docker Official Image `redis:8`, which includes Redis
  Query Engine support for vector search. Set `MN_REDIS_IMAGE` before install
  or in `~/.mn/docker-compose.env` to pin a specific Redis 8+ tag or digest.
- The installer can set up the core, SDK, CLI, API, Web UI, Redis, and
  OpenShell depending on selected options. `--context-engine` prepares the
  versioned Membrane GAR image before use. A blueprint that requires context
  memory only starts that prepared image; it never builds Membrane source.
- OpenShell sandbox JWT keys are bootstrapped by the pinned gateway container;
  installing OpenSSL on the host is not required. Keys are generated in the
  container filesystem and copied out, so reset-time Docker Desktop host-mount
  caching cannot break bootstrap. The temporary container is removed on success
  and failure, and the signing key is installed with mode 0600.
- The OpenShell host endpoint follows its published Compose bind address:
  Docker Desktop uses loopback, while native Linux uses the runtime bridge
  gateway so both the host CLI and sandbox containers can reach the service.
- The Web UI is a Docker Compose service published on port `55173` by default;
  installing it does not require npm on the host. Binary installs fetch the
  selected `mirrorneuron-web-ui` package from the public GAR npm repository
  inside the service, while local installs mount and build the `mn-web-ui`
  checkout inside the service.
  Its local job-UI proxy resolves the authenticated job handle and forwards
  only that job's declared dashboard and companion ports; it never redirects a
  browser to a selected remote node's LAN address.
- Installs are non-interactive by default and use yes/default selections. Use
  `--interactive` for the prompt-driven setup flow.
- Use `./install.sh` or `./install.sh --mode binary` for release/package installs,
  `./install.sh --mode github` for repository installs, or `./install.sh --mode local`
  from a monorepo checkout for editable local installs.
- Local mode resolves the SDK, every SDK component under
  `mn-python-sdk/packages/`, the CLI, API, and selected skill projects together
  from sibling repositories. This prevents internal dependencies from falling
  back to GAR and allows local installs to use newly created MirrorNeuron
  packages before they are published to the package registry.
  `--no-skills` skips optional skill packages but keeps local skills required by
  runtime services, including the definition-scoped Job response engine and its
  local dependency closure.
- Local, GitHub, and binary installs persist `MN_MEMBRANE_SOURCE_MODE=image`
  and use the versioned Membrane GAR runtime image. The context engine is a
  released container package in every install mode; its source checkout is not
  cloned or built when a blueprint starts.
- GitHub mode without `--version` installs from each repository's default branch.
  Use `--version v1.2.8` only when you want to pin GitHub installs to matching
  release tags.
- Use `--version v1.2.8` to install a matching released set of core, CLI, SDK,
  API, Web UI, package metadata, and runtime support files. In binary mode,
  `--core-version`, `--python-sdk-version`, `--cli-version`, `--api-version`,
  and `--web-ui-version` can override those components independently; for
  example, `./install.sh --core-version v1.2.24 --python-sdk-version v1.2.24
  --cli-version v1.2.24 --api-version v1.2.24 --web-ui-version v1.2.24`.
  With no version flags, binary installs use `v1.3.47` for Core, SDK, CLI, API,
  Web UI, the package index, Membrane, and installer support.
- Versioned installer support files live under `install_support/<version>/`.
  Create a release snapshot with:

  ```bash
  ./save_install_support.sh --version v1.2.8
  ```

- For URL installs without a local checkout, the installer downloads the
  versioned runtime Docker Compose template and binary package index from the
  public `mn-deploy` GitHub repository.
- Installs prepare the Membrane context engine by default: the installer pulls
  the versioned GAR image before any context-memory blueprint runs. Use
  `--no-context-engine` only when the local runtime must omit it. `mn runtime
  ensure-context-engine` performs the same package preparation for an existing
  install.
- Python packages published to Google Artifact Registry are controlled by
  `package-index/python-packages.toml`.
- Binary mode uses one GAR project as its artifact authority. Python packages
  come from
  `https://us-central1-python.pkg.dev/mirrorneuron-public-packages/agent-skills/simple/`, with public dependencies resolved directly from PyPI; the Web UI comes from `https://us-central1-npm.pkg.dev/mirrorneuron-public-packages/mirrorneuron-npm/`, while its public build dependencies come directly from npmjs;
  and runtime images come from the `mirrorneuron-runtime` Docker repository.
- Binary mode installs agent definitions and the Membrane Python runtime from
  that package repository and uses the versioned Membrane GAR image. It does
  not clone `mn-agents` or `Membrane`; repository checkouts remain development
  inputs for GitHub/local modes.
- Binary mode does not preinstall skill packages. Each blueprint installs its
  declared skill dependencies when they are needed.
- GAR setup:

  ```bash
  ./setup_google_artifact_registry.sh \
    --project mirrorneuron-public-packages \
    --location us-central1 \
    --repository agent-skills \
    --npm-repository mirrorneuron-npm
  ```

- GAR publish/sync dry run:

  ```bash
  ./publish_python_packages_to_google_artifact_registry.sh \
    --project mirrorneuron-public-packages \
    --location us-central1 \
    --repository agent-skills
  ```

- GAR publish/sync apply:

  ```bash
  ./publish_python_packages_to_google_artifact_registry.sh \
    --apply \
    --project mirrorneuron-public-packages \
    --location us-central1 \
    --repository agent-skills
  ```

- Web UI GAR npm publish dry run:

  ```bash
  ./publish_web_ui_to_google_artifact_registry.sh --version v1.2.30
  ```

- Web UI GAR npm publish apply:

  ```bash
  ./publish_web_ui_to_google_artifact_registry.sh \
    --apply \
    --version v1.2.30
  ```

- Public Core multi-platform Docker image GAR apply:

  ```bash
  ./publish_public_core_to_google_artifact_registry.sh \
    --apply \
    --version v1.2.30
  ```

  On Apple Silicon this automatically registers QEMU for the x64 release
  image. The standard `./release_all.sh -v 1.2.30` flow runs this local
  publisher; the Core GitHub Actions workflow only publishes OTP archives.

- Public Membrane Rust binary and Docker image GAR dry run:

  ```bash
  ./publish_public_membrane_to_google_artifact_registry.sh \
    --version v1.2.8
  ```

- Public Membrane Rust binary and Docker image GAR apply:

  ```bash
  ./publish_public_membrane_to_google_artifact_registry.sh \
    --apply \
    --version v1.2.8
  ```

  On ARM64 hosts this automatically registers the pinned QEMU binfmt handler
  before building the amd64 image. Use `--qemu never` only when the host already
  provides amd64 emulation.

- Public Otterdesk desktop app package GAR apply:

  ```bash
  ./publish_public_otterdesk_to_google_artifact_registry.sh \
    --apply \
    --version v1.2.8
  ```

## Optional Python SDK components

The Python package index includes independently built SDK component projects
under `mn-python-sdk/packages/`. Local source installation resolves every SDK
component plus the SDK, CLI, and API projects in one editable transaction, so
no internal SDK dependency falls back to GAR. GitHub source installation uses
the SDK installer group, and binary installation selects versioned wheels from
the same inventory and preserves extras when using a bundled wheelhouse. Local
installation also imports the SDK, CLI, and API together before accepting the
new virtual environment. If sibling checkouts are revision-incompatible,
installation stops before service startup and restores the previous virtual
environment.

RAG, models, MCP, collaboration, and Job response engines are not binary or
GitHub installer defaults. Local development installs bind their distributions
to sibling source checkouts, while blueprints and native response services
still decide which capabilities to enable or prepare at runtime. A new release
must publish the indexed packages and refresh its version pins and
install-support snapshot together. Release preparation compares tracked package inputs with the previous release
and automatically increments changed packages by one patch. Unchanged packages
retain their versions; manually advanced static versions are preserved. The SDK
and its component wheels share one version group because blueprint capability
defaults derive from SDK identity. CLI, API, skills, agents, and Membrane Python
projects advance independently. Missing SDK index entries fail preparation;
historical snapshots remain immutable. The aggregate release builds and verifies the complete Python
inventory and self-contained Web UI package directly from sibling worktrees in
GAR before it pushes the prepared source tags. `release_all.sh` uses `uv` to
create its dedicated Python publishing environment and install the required
build, Twine, keyring, and GAR authentication packages automatically. GitHub
release workflows are neither awaited nor used as package sources.

Each publishing step is a named resume phase. On failure, the script prints the
exact recovery command, for example:

```bash
./release_all.sh -v 1.3.46 --resume-from web-ui
```

A resumed release validates the existing local release tags. Web UI builds run
from the release tag in a temporary directory, and Membrane/Core Docker builds
also use their tagged source, so those repositories may advance without changing
the release inputs. Resuming at the Python phase additionally requires package
source checkouts to remain at their tagged commits. Earlier phases are skipped.
Source and wheel tests do not require a live runtime installation.


The default Compose runtime starts Membrane alongside LiteLLM for automatic
request context compression. No blueprint profile is needed. The SDK gateway
uses the configured serving window and calls Membrane's `CompilePrompt` RPC
when necessary; deploy the SDK and Membrane image together. Model compression
remains optional, and no workflow timeout behavior changes. Historical release
support snapshots remain unchanged.

Use `./install.sh --mode local --build-membrane` to build the Membrane runtime
image from the sibling `Membrane` checkout. Set `MN_MEMBRANE_DIR` to use a
specific local checkout. Binary and GitHub install modes ignore this flag and
continue using their normal GAR images. The flag overrides the released engine image with
`mirror-neuron-memory-engine:local`, records source mode, and builds the Dockerfile
`runtime` target once per installer invocation using the normal Docker cache.
Without the flag, all modes retain their normal GAR image selection and pull.
Subsequent runtime/blueprint startup does not build images. Missing source and
`--build-membrane --no-context-engine` fail before installation; a failed build
stops the installer without pulling GAR as a fallback. No image is published.

## Delete GAR package versions

```bash
./CLEARN_GAR.sh -v 1.3.48             # Delete versions strictly below 1.3.48.
./CLEARN_GAR.sh -a                   # Delete all stored package versions.
./CLEARN_GAR.sh -v 1.3.48 --dry-run   # Preview only.
```

The script inventories every repository location in
`mirrorneuron-public-packages`. Set `MN_GAR_PROJECT` or pass `--project` to
select another project. It prints each selected version and its tags, then
requires the exact uppercase answer `YES`. There is no confirmation bypass.
Repository definitions and IAM are retained; virtual repositories have no
stored artifacts and are skipped. An inventory failure prevents deletion.
A changed deletion plan after confirmation requires a fresh run and confirmation.

Cutoff comparisons are numeric, so `1.3.9` is older than `1.3.48`, while
`1.3.100` is newer. Common prereleases are older than their final release.
Docker versions are selected by release tags; a digest with any comparable tag
at or above the cutoff is retained. Untagged images and unrecognized version
names are reported and skipped in cutoff mode, but included by `-a`.
Deleting a selected version removes its associated tags, including aliases.
This uses Google's [Artifact Registry version deletion command](https://docs.cloud.google.com/sdk/gcloud/reference/artifacts/versions/delete).

**Deletion is permanent.** The cutoff applies to each package's own version,
including independently versioned packages still required by a newer release.
Old installer snapshots, blueprints, and deployed applications can therefore
lose required artifacts. The script does not rewrite their dependency pins.

Requires authenticated `gcloud` with Artifact Registry deletion permission and
Python 3.10+. Run offline regression tests with:

```bash
../mn-python-sdk/.venv/bin/python -m pytest scripts/test_clean_gar.py -q
```
