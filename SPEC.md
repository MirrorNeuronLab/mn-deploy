# MirrorNeuron Deployment Specification

## Purpose

`mn-deploy` is the installation, service-management, release-support, and
uninstallation layer for a local MirrorNeuron distribution. It assembles
versioned Core, SDK, CLI, API, Web UI, Redis, OpenShell, and optional context
engine components without implementing those components.

This specification applies only to deployment assets in this repository.

## Public Entry Points

- `install.sh`: install or update the selected component set.
- `uninstall.sh`: remove installed MirrorNeuron components and selected state.
- `server.sh`: start, stop, and inspect installed services.
- `prepare_cluster.sh`: prepare cluster-facing deployment configuration.
- `save_install_support.sh`: snapshot release support under a version.
- publishing scripts: build or publish explicitly selected release artifacts.

Flags shown by each script's `--help` are the exact command contract.

## Install Modes

The installer supports:

- `binary`: install released artifacts and packages, using versioned support;
- `github`: install from component repositories, optionally at a matching tag;
  and
- `local`: use sibling workspace checkouts for editable/source development.

An omitted mode follows the documented release/package default. Mode selection
must not silently cross into another source type. Explicit component-version
overrides take precedence over the shared release version only for their named
component.

All modes use the single `mn runtime start` contract. There is no worker-only
runtime. The historical `--start-as-worker` spelling may remain temporarily as
a hidden deprecated alias, but it performs a normal start and must not appear
in help output or generate worker-specific Compose state.

Local-mode Python resolution presents all selected sibling projects to pip in
one editable install transaction. Dependencies between MirrorNeuron packages
must resolve from those workspace checkouts, including packages that have not
yet been published. Package-index resolution remains a binary-mode concern.

## Installed State

Runtime state and generated configuration live below the configured
`MN_HOME` (documented default `~/.mn`) and established executable/install
locations. Generated Compose environment belongs in installed state, not in
this checkout. Redis is an attached service. Membrane may be prepared lazily
when a blueprint requires context memory.

Install operations must be restartable after partial completion. Existing
valid configuration is preserved unless the selected operation explicitly
replaces it. Failures identify the failed component and a recovery action.

## Release Support Contract

- `docker-compose.yml` is the current development/release template.
- `install_support/<version>/` is the immutable support snapshot for a released
  installer version.
- `package-index/python-packages.toml` defines the Python packages included in
  publishing/install flows.
- Version changes across scripts, snapshots, package metadata, and artifacts
  must remain coherent.
- Snapshot creation rejects a Docker Compose template whose default Web UI npm
  version does not match the requested release version.
- Historical snapshots are not rewritten to adopt current defaults.

## Safety and Security

- Installation, removal, service control, state clearing, registry setup, and
  publishing are state-changing operations and require explicit invocation.
- Destructive targets must be resolved to known installed roots before removal.
  Empty variables, home-directory globs, and workspace-wide deletion are
  invalid targets.
- Credentials and tokens come from the environment or approved credential
  mechanisms and are never emitted to normal logs, except that successful
  runtime startup intentionally returns the active federation join token and
  exact `mn node add` command to the invoking operator. Non-interactive
  installer filtering may forward only that final readiness block, not
  unrelated command output.
- Downloaded artifacts and metadata are validated where checksums/signatures or
  version checks are part of the release flow.
- Federation joins remain opt-in and visibly reported. LiteLLM must be
  reachable by authenticated peer gateways; documentation must call out the
  firewall boundary for its published port.
- Workspace update helpers may reconcile dirty tracked files automatically only
  when the complete working tree is byte-identical to the fetched remote tip,
  the local branch can fast-forward, and a verified recovery stash protects the
  operation. Unique, untracked, or divergent work must remain untouched and
  produce an actionable error.

## Portability and Output

User-facing entrypoints support the documented macOS/Linux host paths. Shell
code must quote values, handle spaces in paths, and avoid undocumented global
tools. Non-interactive execution is line-oriented and deterministic; color is
TTY-only and disabled by `NO_COLOR`.

## Compatibility

Install mode meanings, installed paths, service names, support file formats,
default component selection, cleanup scope, and public flags are compatibility
contracts. Changes require installer regression tests and release notes. A new
release uses a new support snapshot rather than mutating an old one.

## Verification

All shell files must pass `bash -n`. Behavioral changes require the installer
contract suite in `mn-system-tests/installer` and, where practical, an isolated
mode-specific smoke test. Publishing, live uninstall, and host-level mutation
are never implicit test steps.
