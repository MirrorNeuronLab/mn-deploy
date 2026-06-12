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

Check or control installed services:

```bash
./server.sh status
./server.sh start
./server.sh stop
```

## Details

- [MirrorNeuron Component Guide](../mn-docs/component-guide.md#deployment-scripts)
- [Installation](../mn-docs/installation.md)
- [Docker and OpenShell for Blueprints](../mn-docs/docker_and_openshell_for_blueprints.md)
- [Security Model](../mn-docs/security.md)

## Notes

- Default runtime state is stored under `~/.mn`.
- Generated Compose settings are stored in `~/.mn/docker-compose.env`.
- The installer can set up the core, SDK, CLI, API, Web UI, Redis, OpenShell,
  and Membrane context engine depending on selected options.
- Use `./install.sh --mode local` from a monorepo checkout for editable local
  installs, or `./install.sh --mode binary` for release/package installs.
