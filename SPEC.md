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

`install.sh --detect-only` is a read-only query for integrations. It prints one
JSON object containing `installed`, `running`, `runtime_ready`, `status`, the
installed Core `version`, `docker_installed`, and `docker_running`, and exits
without preparing paths, downloading assets, or changing runtime state.
`runtime_ready` is true only when the installed `mn runtime status` command
succeeds. If an installation is present but Docker cannot be queried, `status`
is `docker_not_running` and `running` is JSON `null`.

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
runtime, and worker-only installer flags are rejected.

Local-mode Python resolution presents the SDK, every sibling SDK component,
the CLI, the API, and all other selected sibling projects to pip in one
editable install transaction. Dependencies between MirrorNeuron packages must
resolve from those workspace checkouts, including packages that have not yet
been published. `--no-skills` excludes optional blueprint capabilities but
retains skills imported by installed runtime services, including the Job
response engine and its local dependency closure. Package-index resolution
remains a binary-mode concern.
Before accepting the replacement virtual environment or starting services,
the local installer imports the SDK, CLI, and API entry modules together. An
import incompatibility between sibling source revisions fails installation and
restores the previous virtual environment.

## Installed State

Runtime state and generated configuration live below the configured
`MN_HOME` (documented default `~/.mn`), including private Python tools,
commands, downloads, caches, and generated OpenShell configuration. Shell setup
is written to `MN_HOME/env`; the installer does not edit shell profiles. Ordinary
reinstall preserves durable state in place rather than copying and deleting it. Generated Compose environment belongs in installed state, not in
this checkout. Binary and GitHub installs default `MN_ENV` to `prod` and
disable local skill sources; local source installs enable them explicitly. An
explicit `MN_ENV` or `MN_USE_LOCAL_SKILLS` value remains authoritative. Redis
is an attached service. Membrane preparation is an
explicit package-install operation: installers and `mn runtime
ensure-context-engine` pull the versioned GAR image before it is needed. A
blueprint that requires context memory may start that prepared image but must
not build or clone Membrane source.

The local Web UI Compose service may proxy an external job UI only after it
loads that job's authenticated durable UI handle from the local API. Its target
host is fixed by that handle and its ports are limited to the handle's declared
allowlist; it is never a general LAN proxy or browser redirect to a remote
runtime node.

Install operations must be restartable after partial completion. Existing
valid configuration is preserved unless the selected operation explicitly
replaces it. Failures identify the failed component and a recovery action.

## Release Support Contract

- `docker-compose.yml` is the current development/release template.
- `install_support/<version>/` is the immutable support snapshot for a released
  installer version.
- `package-index/python-packages.toml` defines the Python packages included in
  publishing/install flows.
- The configured GAR project is the sole binary artifact authority. Its Python,
  npm, and Docker artifacts use format-specific repositories.
- Version changes across scripts, snapshots, package metadata, and artifacts
  must remain coherent.
- Snapshot creation rejects a Docker Compose template whose default Web UI npm
  version does not match the requested release version or whose GAR npm
  registry is missing.
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
- The default gRPC port (`55051`) is implicit in the displayed add-node
  command. A non-default advertised port is included with `--grpc-port` so the
  displayed command remains exact.
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

## Current installer contract

Install mode meanings, installed paths, service names, support file formats,
default component selection, cleanup scope, and public flags define the current
installer contract. Changes require installer regression tests and release
notes. A new release uses a new support snapshot rather than mutating an old one.

## Verification

All shell files must pass `bash -n`. Behavioral changes require the installer
contract suite in `mn-system-tests/installer` and, where practical, an isolated
mode-specific smoke test. Publishing, live uninstall, and host-level mutation
are never implicit test steps.

## Optional Python SDK components

The Python package index includes independently built SDK component projects
under `mn-python-sdk/packages/`. Local source installation resolves every SDK
component plus the SDK, CLI, and API projects in one editable transaction, so
no internal SDK dependency falls back to GAR. GitHub source installation uses
the SDK installer group, and binary installation selects versioned wheels from
the same inventory and preserves extras when using a bundled wheelhouse.

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
historical snapshots remain immutable. The aggregate release builds the indexed Python inventory and a
self-contained Web UI npm package from local sibling worktrees, publishes and
verifies them in the single configured GAR project, and only then pushes the
prepared source tags. GitHub release workflow outputs are not release inputs. MirrorNeuron-owned packages are installed from GAR; third-party dependencies continue to resolve directly from PyPI and npmjs. GAR's Python, npm, and Docker formats
remain separate repositories within that project.
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

## Explicit GAR cleanup

`CLEARN_GAR.sh -v MAJOR.MINOR.PATCH` deletes stored versions strictly below the
numeric cutoff across every repository location in the selected GAR project.
`-a` selects all stored versions. These modes are mutually exclusive. Neither
mode deletes repositories or IAM, and neither is invoked by release automation.
A complete deletion preview and the exact response `YES` are required before
any mutation; `--dry-run` only inventories. No `--yes` bypass is provided.
The default project is `mirrorneuron-public-packages`, overridden explicitly
by `--project` or `MN_GAR_PROJECT`.

Docker digests are compared using their version tags and retained if any
comparable tag is at or above the cutoff. Cutoff mode reports unversioned or
unrecognized versions without deleting them; `-a` includes them. Deleted
versions lose all their tags. Failures during inventory abort before deletion;
failures during deletion stop and report completed deletions and the failed
resource. An updated deletion plan during confirmation aborts for fresh review.
Tests use a fake gcloud executable and must never clean the live registry.
# Desktop node identity contract

Managed Core launch commands reject empty, malformed, and nonode@nohost names
in both release and source modes. Reinstall preserves the configured name before
rewriting Compose environment; the CLI validates and persists identity before
creating containers. Installer detection uses runtime status JSON and reports
status identity_invalid with runtime_ready false for an identity failure.
Release these templates together with the persistent-identity CLI and Core;
historical install-support snapshots must not be modified.
