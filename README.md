# MirrorNeuron Deploy

Installer and local deployment scripts for MirrorNeuron.

This repository keeps shell scripts used to install, start, stop, and remove a local MirrorNeuron installation. The current package-based installer is `install_bin.sh`.

## Components Installed by `install_bin.sh`

| Component | Source |
| --- | --- |
| MirrorNeuron core | GitHub Release OTP tarball from `MirrorNeuronLab/MirrorNeuron` |
| Python SDK | Native PyPI package `mirrorneuron-python-sdk` in `~/.local/share/mn_venv` |
| Blueprint support skill | GitHub repository `MirrorNeuronLab/mn-skills`, subdirectory `blueprint_support_skill` |
| CLI | Native PyPI package `mirrorneuron-cli` in `~/.local/share/mn_venv` |
| API | Native PyPI package `mirrorneuron-api` in `~/.local/share/mn_venv` |
| Web UI | npm package `mirrorneuron-web-ui` |
| Docker runtime | One Compose project for Core, Redis, OpenShell gateway, Membrane context engine, and context model |
| Redis | Compose service using Docker image `redis:7` |
| Membrane context engine | Compose services built from `MirrorNeuronLab/Membrane` plus native `mirrorneuron-membrane-python-sdk`, if selected |
| OpenShell | Compose service using Docker image `ghcr.io/nvidia/openshell/gateway:0.0.47`, if selected |

## Prerequisites

- macOS, Linux, or WSL2.
- `curl`
- `docker` with a running Docker daemon.
- Python 3.11 or newer when installing Python components. If none is found, `install_bin.sh`, `install.sh`, and `install_local.sh` install `uv`, let `uv` download a private Python 3.11 runtime under `~/.local/share/mn_python`, and create the MirrorNeuron venv from it.
- `pip` or Python `ensurepip` for the selected Python interpreter.
- `npm` when installing the Web UI.
- Network access to GitHub Releases, PyPI, npm, and Docker registries.

## Installation

Use the package-based installer:

```bash
./install_bin.sh
```

Run non-interactively with preselected choices:

```bash
./install_bin.sh --yes --no-web-ui
./install_bin.sh --yes --no-context-engine
./install_bin.sh --yes --no-web-ui --python-components sdk,api
MN_PYTHON=/opt/homebrew/bin/python3.11 ./install_bin.sh --yes
MN_MANAGED_PYTHON=0 ./install_bin.sh --yes
./install_bin.sh --yes --no-managed-python
```

Install from a specific core release tag:

```bash
./install_bin.sh --core-release-tag v1.1.0
```

Use a different core release repository:

```bash
MN_CORE_REPO=MirrorNeuronLab/MirrorNeuron ./install_bin.sh
```

The installer prompts for:

- Web UI installation.
- Docker runtime setup. Core, Redis, OpenShell, the Membrane context engine, and the context model share one Compose project so services can talk by service name.
- Membrane context engine installation and startup through Docker Compose. The default is yes.
- OpenShell gateway startup through Docker Compose.
- Python components: SDK, blueprint support skill, CLI, and API.
- Whether to start MirrorNeuron after installation.

Use `./install_bin.sh --help` for all non-interactive flags.

## Installed Paths

| Path | Purpose |
| --- | --- |
| `~/.mn` | Core install metadata, extracted core release files, runtime state, and generated Compose files. |
| `~/.mn/docker-compose.yml` | Generated Compose file for the local Docker runtime. |
| `~/.mn/docker-compose.env` | Generated Compose environment file with host paths and runtime tokens. |
| `~/.mn/openshell-state` | OpenShell gateway SQLite state mounted into the Compose service. |
| `~/.mn` | Native runtime data mapped into the Core container. |
| `~/.config/openshell-mirror-neuron` | Container-facing OpenShell gateway config for the Compose network. |
| `~/.local/share/mn_python` | Private uv-managed Python runtime, only when no Python 3.11+ is already available. |
| `~/.local/share/mn_uv` | Private uv install used to manage Python when uv is not already installed. |
| `~/.local/share/mn_venv` | Python virtual environment for CLI, API, SDK, and skills. |
| `~/.mn/webui` | Installed Web UI package output. |
| `~/.local/bin/mn` | CLI symlink. |
| `~/.local/bin/mn-api` | API symlink. |
| `~/.mn/install_metadata.json` | Installed core release tag, platform, asset URL, and update time. |

## Runtime Commands

After installation:

```bash
mn start
mn nodes
mn stop
```

The CLI manages the Compose runtime, native API process, and Web UI when installed. The Core gRPC port and OpenShell gateway port are exposed on loopback for the native CLI. Redis stays inside the Compose network and is not published to the host. The API port remains native because `mn-api` is installed outside Docker.

For a two-machine Compose cluster, keep the native `mn` CLI and Python SDK installed on each host, then use an externally reachable Redis or Redis Sentinel endpoint for shared cluster state. The local Compose Redis is internal-only and is intended for a single host.

```bash
# machine 1
MN_NODE_NAME=mn1@192.168.4.10 \
MN_CLUSTER_NODES=mn1@192.168.4.10,mn2@192.168.4.173 \
MN_REDIS_URL=redis://192.168.4.10:6379/0 \
MN_GRPC_BIND_HOST=0.0.0.0 \
MN_EPMD_BIND_HOST=0.0.0.0 \
MN_DIST_BIND_HOST=0.0.0.0 \
mn start

# machine 2
MN_NODE_NAME=mn2@192.168.4.173 \
MN_CLUSTER_NODES=mn1@192.168.4.10,mn2@192.168.4.173 \
MN_REDIS_URL=redis://192.168.4.10:6379/0 \
MN_EPMD_BIND_HOST=0.0.0.0 \
MN_DIST_BIND_HOST=0.0.0.0 \
mn start
```

The default host-facing cluster ports are gRPC `50051`, EPMD `4369`, fixed BEAM distribution `4370`, and OpenShell `8080`.

## Update Behavior

The CLI includes an acknowledged update flow:

```bash
mn update --check-only
mn update
```

If the user confirms an update, the CLI stops all MirrorNeuron components, upgrades released packages, updates the core from GitHub Releases when needed, and restarts the local runtime.

Updating stops running jobs. Run it only when no important jobs are active.

## Other Scripts

| Script | Purpose |
| --- | --- |
| `install_bin.sh` | Package-based installer using released artifacts. |
| `install.sh` | Existing installer kept for compatibility. |
| `install_local.sh` | Local-source installer for development workflows. |
| `server.sh` | Local server helper script. |
| `setup.sh` | Environment setup helper. |
| `uninstall.sh` | Removes local installation files created by the installer. |

## Configuration

| Variable | Default | Description |
| --- | --- | --- |
| `MN_CORE_REPO` | `MirrorNeuronLab/MirrorNeuron` | GitHub repository that hosts core releases. |
| `MN_CORE_RELEASE_TAG` | `latest` | Core release tag to install. |
| `MN_CORE_ASSET_URL` | unset | Direct OTP release tarball URL. When set, skips release asset URL construction. |
| `MN_PYTHON` | unset | Python 3.11+ interpreter used to create `~/.local/share/mn_venv`. |
| `MN_MANAGED_PYTHON` | `1` | Set to `0` to disable uv-managed private Python fallback. |
| `MN_MANAGED_PYTHON_VERSION` | `3.11` | Python minor version for the uv-managed private runtime fallback. |
| `MN_MANAGED_PYTHON_DIR` | `~/.local/share/mn_python` | Root directory for uv-managed private Python runtimes. |
| `MN_UV_DIR` | `~/.local/share/mn_uv` | Private uv install root when no `uv` command is already available. |
| `MN_SKILLS_REPO` | `MirrorNeuronLab/mn-skills` | GitHub repository used to install Python skills. |
| `MN_SKILLS_GIT_URL` | unset | Direct Git URL for skills. When set, overrides `MN_SKILLS_REPO`. |
| `MN_MEMBRANE_REPO` | `MirrorNeuronLab/Membrane` | GitHub repository used to install the Membrane context engine. |
| `MN_MEMBRANE_GIT_URL` | unset | Direct Git URL for Membrane. When set, overrides `MN_MEMBRANE_REPO`. |
| `MN_MEMBRANE_DIR` | `~/.mn/Membrane` | Local Membrane checkout or source path used by installers. |
| `MN_CONTEXT_ADDR` | `localhost:50052` | Context engine address used by blueprints and OtterDesk conversation memory. |
| `MN_GRPC_BIND_HOST` | `127.0.0.1` | Native host address used for the Core gRPC Compose port binding. |
| `MN_GRPC_PORT` | `50051` | Native host port mapped to Core gRPC in Docker. |
| `MN_EPMD_BIND_HOST` | `127.0.0.1` | Native host address used for Erlang EPMD in Compose. |
| `MN_EPMD_PORT` | `4369` | Native host port mapped to Erlang EPMD. |
| `MN_DIST_BIND_HOST` | `127.0.0.1` | Native host address used for the fixed BEAM distribution port in Compose. |
| `MN_DIST_PORT` | `4370` | Fixed BEAM distribution port used for cluster communication. |
| `MN_NODE_NAME` | unset | Erlang node name for cluster mode, for example `mn1@192.168.4.10`. |
| `MN_CLUSTER_NODES` | unset | Comma-separated Erlang node names expected in the cluster. |
| `MN_REDIS_URL` | `redis://redis:6379/0` | Redis URL used by Core. The default points to the internal Compose Redis; use an externally reachable Redis or Sentinel setup for multi-host clusters. |
| `MN_HOST_MN_DIR` | `~/.mn` | Native runtime-data directory mounted into Core. |
| `MN_HOST_OPENSHELL_STATE_DIR` | `~/.mn/openshell-state` | Host directory mounted at the same absolute path inside the OpenShell gateway so Docker-backed sandbox supervisor bind mounts resolve correctly. |
| `OPENSHELL_GATEWAY_BIND_HOST` | `127.0.0.1` | Native host address used for the OpenShell gateway Compose port binding. |
| `OPENSHELL_GATEWAY_PORT` | `8080` | Native host port mapped to the OpenShell gateway for custom image builds and sandbox utilities. |
| `OPENSHELL_GATEWAY_ENDPOINT` | `http://127.0.0.1:8080` | Endpoint used by native OpenShell CLI commands. |
| `OPENSHELL_GATEWAY_USER` | current host uid/gid | Numeric user used for the OpenShell gateway container so it can access the Docker socket and its SQLite state directory. |
| `OPENSHELL_GATEWAY_DOCKER_GROUP` | `0` | Supplemental container group used for Docker socket access on Docker Desktop. |
| `OPENSHELL_GATEWAY_IMAGE` | `ghcr.io/nvidia/openshell/gateway:0.0.47` | OpenShell gateway image used by the Compose runtime; keep this aligned with the installed OpenShell CLI. |
| `GITHUB_TOKEN` / `GH_TOKEN` | unset | Optional token passed to GitHub release download requests. |
| `PIP_NO_INPUT` | `1` | Prevents interactive pip prompts during install. |
| `MN_API_HOST` | `localhost` | API host used by generated Web UI proxy config. |
| `MN_API_PORT` | `4001` | API port used by generated Web UI proxy config. |
| `MN_WEB_UI_HOST` | `localhost` | Web UI dev server bind host. |

## Testing

For shell syntax checks:

```bash
bash -n install_bin.sh
bash -n install.sh
bash -n install_local.sh
bash -n server.sh
bash -n setup.sh
bash -n uninstall.sh
```

For a full installer test, run on a clean machine or disposable VM with Docker running.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Installer cannot find Docker | Start Docker and confirm `docker info` succeeds. |
| Core asset is not found | Confirm the selected release tag contains an OTP tarball for your Docker platform. |
| `mn` is not found after install | Ensure `~/.local/bin` is on `PATH` or restart the shell. |
| Web UI install fails | Confirm `npm` is installed and the npm registry is reachable. |
| API commands fail after install | Run `mn start`, then check `mn nodes`. |

## Contributing

Keep installer changes idempotent and avoid hard-coded local paths beyond the documented install directories. Test shell syntax before committing.

## License

No top-level license file is currently present in this repository. Add one before distributing these scripts outside the project.
