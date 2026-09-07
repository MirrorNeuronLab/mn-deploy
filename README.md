# MirrorNeuron Deploy

`mn-deploy` contains the unified installer and local service scripts for MirrorNeuron.
By default, `install.sh` installs released artifacts and Python packages.

## Quick Start

Inspect installer options:

```bash
./install.sh --help
```

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
`~/.local/share/mn_venv`, clears Redis, and removes the MirrorNeuron Docker
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
  profile export for both MirrorNeuron and OtterDesk:
  `export MN_HOME="$HOME/.mn"`.
- Generated Compose settings are stored in `~/.mn/docker-compose.env`.
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
  The installer adds that directory to the active zsh or bash startup file; open a new terminal
  after the first install, or run the reload command printed by the installer.
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
  selected `mirrorneuron-web-ui` package version inside the service, while
  local installs mount and build the `mn-web-ui` checkout inside the service.
  Its local job-UI proxy resolves the authenticated job handle and forwards
  only that job's declared dashboard and companion ports; it never redirects a
  browser to a selected remote node's LAN address.
- Installs are non-interactive by default and use yes/default selections. Use
  `--interactive` for the prompt-driven setup flow.
- Use `./install.sh` or `./install.sh --mode binary` for release/package installs,
  `./install.sh --mode github` for repository installs, or `./install.sh --mode local`
  from a monorepo checkout for editable local installs.
- Local mode resolves the selected SDK, CLI, API, and skill projects together
  from sibling repositories. This allows local installs to use newly created
  MirrorNeuron packages before they are published to the package registry.
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
  With no version flags, binary installs use core `v1.2.24` and SDK, CLI, API,
  and Web UI `v1.2.24`.
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
- Binary mode uses the current public package repository by default:
  `https://us-central1-python.pkg.dev/mirrorneuron-public-packages/agent-skills/simple/`.
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
    --repository agent-skills
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

- Public Otterdesk desktop app package GAR apply:

  ```bash
  ./publish_public_otterdesk_to_google_artifact_registry.sh \
    --apply \
    --version v1.2.8
  ```

## Optional Python SDK components

The Python package index includes independently built SDK component projects
under `mn-python-sdk/packages/`. Local and GitHub source installation resolve the SDK, common component, and
web UI component in one pip transaction. Local source installation also includes
the CLI/API projects in that transaction. Binary installation selects versioned wheels from the same
inventory and preserves extras when using a bundled wheelhouse.

RAG, models, MCP, collaboration, and Job response engines are not installer
defaults. Blueprints declare their component dependencies for preparation by
the SDK. Native response services prepare their own optional host components
when needed. A new release must publish the indexed packages and refresh its
version pins and install-support snapshot together; historical snapshots remain
immutable. Source and wheel tests do not require a live runtime installation.
