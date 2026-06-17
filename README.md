# MirrorNeuron Deploy

`mn-deploy` contains the unified installer and local service scripts for MirrorNeuron.
By default, `install.sh` installs from GitHub repositories.

## Quick Start

Inspect installer options:

```bash
./install.sh --help
```

Install the local runtime:

```bash
./install.sh
```

Install released Python packages from Google Artifact Registry:

```bash
./install.sh --mode binary --gar-project YOUR_GCP_PROJECT
```

Check or control installed services:

```bash
./server.sh status
./server.sh start
./server.sh stop
```

## Details

- [Google Artifact Registry Python Publishing](./GOOGLE_ARTIFACT_REGISTRY.md)
- [MirrorNeuron Component Guide](../mn-docs/component-guide.md#deployment-scripts)
- [Installation](../mn-docs/installation.md)
- [Docker and OpenShell for Blueprints](../mn-docs/docker_and_openshell_for_blueprints.md)
- [Security Model](../mn-docs/security.md)

## Notes

- Default runtime state is stored under `~/.mn`.
- Generated Compose settings are stored in `~/.mn/docker-compose.env`.
- Redis defaults to the Docker Official Image `redis:8`, which includes Redis
  Query Engine support for vector search. Set `MN_REDIS_IMAGE` before install
  or in `~/.mn/docker-compose.env` to pin a specific Redis 8+ tag or digest.
- The installer can set up the core, SDK, CLI, API, Web UI, Redis, OpenShell,
  and Membrane context engine depending on selected options.
- Use `./install.sh --mode local` from a monorepo checkout for editable local
  installs, or `./install.sh --mode binary` for release/package installs.
- Python packages published to Google Artifact Registry are controlled by
  `package-index/python-packages.toml`.
- The current public package repository is
  `https://us-central1-python.pkg.dev/mirrorneuron-public-packages/agent-skills/simple/`.
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
