# MirrorNeuron Deploy

`mn-deploy` contains the installer and local service scripts for MirrorNeuron.
The package-based installer is `install_bin.sh`.

## Quick Start

Inspect installer options:

```bash
./install_bin.sh --help
```

Install the local runtime:

```bash
./install_bin.sh
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
