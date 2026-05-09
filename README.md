# MirrorNeuron Deploy

Installer and local deployment scripts for MirrorNeuron.

This repository keeps shell scripts used to install, start, stop, and remove a local MirrorNeuron installation. The current package-based installer is `install_bin.sh`.

## Components Installed by `install_bin.sh`

| Component | Source |
| --- | --- |
| MirrorNeuron core | GitHub Release OTP tarball from `MirrorNeuronLab/MirrorNeuron` |
| Python SDK | PyPI package `mirrorneuron-python-sdk` |
| Blueprint support skill | GitHub repository `MirrorNeuronLab/mn-skills`, subdirectory `blueprint_support_skill` |
| CLI | PyPI package `mirrorneuron-cli` |
| API | PyPI package `mirrorneuron-api` |
| Web UI | npm package `mirrorneuron-web-ui` |
| Redis | Docker image `redis:7`, if selected |
| OpenShell | Docker image `mirrorneuronlab/openshell:latest`, if selected |

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
- Redis installation through Docker.
- OpenShell setup.
- Python components: SDK, blueprint support skill, CLI, and API.
- Whether to start MirrorNeuron after installation.

Use `./install_bin.sh --help` for all non-interactive flags.

## Installed Paths

| Path | Purpose |
| --- | --- |
| `~/.mirror_neuron` | Core install metadata and extracted core release files. |
| `~/.local/share/mn_python` | Private uv-managed Python runtime, only when no Python 3.11+ is already available. |
| `~/.local/share/mn_uv` | Private uv install used to manage Python when uv is not already installed. |
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
