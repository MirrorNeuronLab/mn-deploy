# MirrorNeuron Deploy

Installer and local deployment scripts for MirrorNeuron.

This repository keeps shell scripts used to install, start, stop, and remove a local MirrorNeuron installation. The current package-based installer is `install_new.sh`.

## Components Installed by `install_new.sh`

| Component | Source |
| --- | --- |
| MirrorNeuron core | GitHub Release OTP tarball from `MirrorNeuronLab/MirrorNeuron` |
| Python SDK | PyPI package `mirrorneuron-python-sdk` |
| Blueprint support skill | PyPI package `mirrorneuron-blueprint-support-skill[webui]` |
| CLI | PyPI package `mirrorneuron-cli` |
| API | PyPI package `mirrorneuron-api` |
| Web UI | npm package `mirrorneuron-web-ui` |
| Redis | Docker image `redis:7`, if selected |
| OpenShell | Docker image `mirrorneuronlab/openshell:latest`, if selected |

## Prerequisites

- macOS, Linux, or WSL2.
- `curl`
- `docker` with a running Docker daemon.
- `python3`
- `pip` or Python `ensurepip`.
- `npm` when installing the Web UI.
- Network access to GitHub Releases, PyPI, npm, and Docker registries.

## Installation

Use the package-based installer:

```bash
./install_new.sh
```

Install from a specific core release tag:

```bash
MN_CORE_RELEASE_TAG=v1.0.0 ./install_new.sh
```

Use a different core release repository:

```bash
MN_CORE_REPO=MirrorNeuronLab/MirrorNeuron ./install_new.sh
```

The installer prompts for:

- Web UI installation.
- Redis installation through Docker.
- OpenShell setup.
- Whether to start MirrorNeuron after installation.

## Installed Paths

| Path | Purpose |
| --- | --- |
| `~/.mirror_neuron` | Core install metadata and extracted core release files. |
| `~/.local/share/mn_venv` | Python virtual environment for CLI, API, SDK, and skills. |
| `~/.mirror_neuron_ui` | Installed Web UI package output. |
| `~/.local/bin/mn` | CLI symlink. |
| `~/.local/bin/mn-api` | API symlink. |
| `~/.mirror_neuron/install_metadata.json` | Installed core release tag, platform, asset URL, and update time. |

## Runtime Commands

After installation:

```bash
mn start
mn nodes
mn stop
```

The CLI manages the local core container, API process, and Web UI when installed.

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
| `install_new.sh` | Package-based installer using released artifacts. |
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
| `PIP_NO_INPUT` | `1` | Prevents interactive pip prompts during install. |
| `MN_API_HOST` | `localhost` | API host used by generated Web UI proxy config. |
| `MN_API_PORT` | `4001` | API port used by generated Web UI proxy config. |
| `MN_WEB_UI_HOST` | `localhost` | Web UI dev server bind host. |

## Testing

For shell syntax checks:

```bash
bash -n install_new.sh
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
