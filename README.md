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

The bulk helper fetches before updating. If a checkout contains uncommitted
tracked files that are already byte-identical to the fetched remote tip, it
uses a recovery stash, fast-forwards, verifies the trees match, and removes the
redundant stash. It stops without changing unique, untracked, or divergent
work. For cross-host development, commit and push on one host and use
`git pull --ff-only` on the other; do not copy tracked files between checkouts
that will later receive the same commit.

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
  OpenShell depending on selected options. The Membrane context engine is
  provisioned lazily when a blueprint that requires context memory runs.
- OpenShell sandbox JWT keys are bootstrapped by the pinned gateway container;
  installing OpenSSL on the host is not required.
- The OpenShell host endpoint follows its published Compose bind address:
  Docker Desktop uses loopback, while native Linux uses the runtime bridge
  gateway so both the host CLI and sandbox containers can reach the service.
- The Web UI is a Docker Compose service published on port `55173` by default;
  installing it does not require npm on the host. Binary installs fetch the
  selected `mirrorneuron-web-ui` package version inside the service, while
  local installs mount and build the `mn-web-ui` checkout inside the service.
- Installs are non-interactive by default and use yes/default selections. Use
  `--interactive` for the prompt-driven setup flow.
- Use `./install.sh` or `./install.sh --mode binary` for release/package installs,
  `./install.sh --mode github` for repository installs, or `./install.sh --mode local`
  from a monorepo checkout for editable local installs.
- Local mode resolves the selected SDK, CLI, API, and skill projects together
  from sibling repositories. This allows local installs to use newly created
  MirrorNeuron packages before they are published to the package registry.
  `--no-skills` skips optional skill packages but keeps local skills required by
  the runtime packages.
- Local installs persist `MN_MEMBRANE_SOURCE_MODE=source`, so both initial and
  lazy context-engine starts build the linked `Membrane` checkout. Release and
  GitHub installs use the versioned GAR runtime image unless
  `MN_MEMBRANE_SOURCE_MODE` is explicitly overridden.
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
- Initial installs skip the Membrane context engine by default to keep setup
  light. In binary mode, use `--context-engine` to install the Membrane Python
  runtime from GAR and start the versioned GAR engine image instead of waiting
  for the first context-memory blueprint run.
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
