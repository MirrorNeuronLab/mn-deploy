# MirrorNeuron Deployment Specification

## Current contracts

Current installation uses explicit component pins and current release-index fingerprints (`v2:`). Historical unified-tag inference, fingerprint recovery, shell-profile migration, retired inline-watchdog matching, and host-BEAM PID cleanup are removed. Historical support snapshots are immutable release artifacts and are not modified by this source change.

Backward compatibility and automatic migration of obsolete state are unsupported.

## Full reset isolation

`install.sh --reset` retains the exact `YES` confirmation and separate desktop
reset boundary. Before deleting data it holds an installation lifecycle/reset
lock, stops and verifies owned host relays, watchdogs, model runners and native
helpers, and removes owned Docker runtime/worker/model resources. Current host processes are identified by their runtime module or executable and
installation path; retired inline Python watchdogs are unsupported. PID metadata also requires birth-time evidence; unrelated
processes and other installations are preserved. Cleanup failure aborts reset.

Reset deletes managed downloads and model caches with runtime state, rotates
Core auth/admin credentials, and discards inherited generated credentials,
identity and storage paths. Normal restarts reuse private credential files.
Fresh Compose and direct Docker Core launches receive these same generated
credentials. Source checkouts, user documents and external outputs are preserved.
Only the reset owner may start services while installation is in progress.

## Purpose

`mn-deploy` is the installation, service-management, release-support, and
uninstallation layer for a local MirrorNeuron distribution. It assembles
versioned Core, SDK, CLI, API, Web UI, Redis, OpenShell, and optional context
engine components without implementing those components.

This specification applies only to deployment assets in this repository.

## Public Entry Points

- `install.sh` installs or updates released packages.
- `install_dev.sh` builds from local checkouts or GitHub sources.
- `scripts/preapare_dev.sh` prepares Podman and the source-build WASI toolchain. Its stdout is the SDK directory. `--wasi-only` prepares the toolchain for client builds. `--wasi-path` checks existing tools read-only and prints the SDK directory.
- `uninstall.sh`: remove installed MirrorNeuron components and selected state.
- `server.sh`: start, stop, and inspect installed services.
- `prepare_cluster.sh`: prepare cluster-facing deployment configuration.
- `save_install_support.sh`: snapshot release support under a version.
- `scripts/publish.sh COMPONENT` publishes a selected component to GAR.
- `scripts/artifacts.sh` builds client artifacts and validates release tags and archives.

Flags shown by each script's `--help` are the exact command contract.

`install.sh --start-podman` starts the existing Podman machine or Linux API
socket and exits before installation path preparation. It leaves an already
reachable connection in place. The legacy `--start-docker` flag invokes the
same Podman startup. Run installation or detection as a separate command.

On macOS, developer setup, runtime installation, and uninstallation start a
stopped machine when the selected Podman connection belongs to it. The scripts
wait for the API and try one restart if a running machine continues to refuse
connections. An unreachable machine after recovery blocks runtime installation
and cleanup. Developer setup and installation can initialize a new machine.

`install.sh --detect-only` is a read-only query for integrations. It prints one
JSON object containing `installed`, `install_role`, `running`, `runtime_ready`,
`status`, the installed Core `version`, `podman_installed` and `podman_running`, and exits
without preparing paths, downloading assets, or changing runtime state.
`runtime_ready` is true only when the installed `mn-runtime status` command
succeeds. If an installation is present but Podman cannot be queried, `status`
is `podman_not_running` and `running` is JSON `null`.

## Install Modes

The installer supports:

- `binary`: install released artifacts and packages, using versioned support;
- `github`: install from component repositories, optionally at a matching tag;
  and
- `local`: use sibling workspace checkouts for editable/source development.

`install.sh` uses released packages even when `MN_ENV=dev`.
`install_dev.sh` defaults to local checkouts. Mode selection
must not silently cross into another source type. Explicit component-version
overrides take precedence over the shared release version only for their named
component.

The developer installer finds Cargo on `PATH` or under `${CARGO_HOME:-$HOME/.cargo}/bin`.
It uses the WASI SDK to build SQLite for the API. Developer setup verifies and caches
the pinned host SDK for Linux and macOS when the API needs a compiler. If the sibling `mn-client-support`
path is absent, it clones the Rust `main` branch into the workspace. An
occupied path must already contain the Rust manifest. During a local reset,
the installer prepares these prerequisites after confirmation and before cleanup.

Full installations build or download the WASI client before probing or
provisioning Podman. Runtime-only installs start with runtime preparation.
Linux uses its native API socket. macOS uses the API socket inside the Podman machine.
Before reset cleanup, the installer resolves `PODMAN_HOST_SOCKET` or the
engine-reported socket to an absolute bind path, accepting a `unix://` prefix.
The installer installs the Podman CLI and its platform dependencies on the
host. The Compose provider runs in an image and Core includes the
checksum-pinned remote CLI. Client-only installations launch the three Wasm components on host Wasmtime.

All modes use the single `mn runtime start` contract. There is no worker-only
runtime, and worker-only installer flags are rejected.

All modes leave fresh Blueprint Web UI and automatic port ranges for the
runtime to select. Reinstall preserves each saved range and its allocation
policy. Explicit environment values override the saved range and pin it.
Fresh installations leave Syncthing port selection to the runtime unless the
operator sets `MN_SYNCTHING_GUI_PORT` or `MN_SYNCTHING_SYNC_PORT`.
The installer reports TCP port conflicts and retains the startup log
when a non-interactive startup fails.

Every runtime install mode enables Wasmtime as the built-in sandbox. The
installer records the node's OpenShell policy and connection settings in
`docker-compose.env`. On the first OpenShell coworker the selected node installs
its CLI, prepares the gateway keys and starts the profiled Compose service.
The public NVIDIA gateway uses anonymous registry access during bootstrap.
Private gateway images use the operator's registry credentials. An explicit
gateway endpoint or name selects an existing service. For a Docker coworker, Podman builds the blueprint's Dockerfile in its declared
context on the selected node and starts its service there.
The base runtime uses the Podman engine for Core and its infrastructure.

Python 3.12 is the standard runtime minor version across native services,
HostLocal workers, Python containers, SDK components, agents, and skills.
Python distributions require `>=3.12`; contributor selectors and CI use 3.12.
The installer selects exactly `MN_MANAGED_PYTHON_VERSION` (default `3.12`) and
retains explicit interpreter and uv-managed provisioning options. It resolves
the executable's base interpreter and symlinks before moving or deleting an
existing virtual environment. A base interpreter inside the replacement
directory is rejected before replacement.

Local-mode Python resolution presents the SDK, every sibling SDK component,
and the other selected Python projects to pip in one
editable install transaction. Dependencies between MirrorNeuron packages must
resolve from those workspace checkouts, including packages that have not yet
been published. Local agent packages participate even with `--no-skills`, so
block compilation can fingerprint default implementations before isolated worker
preparation. `MN_AGENTS_ROOT` selects their source checkout when supplied.
`--no-skills` excludes optional blueprint capabilities but
retains skills imported by installed runtime services, including the Job
response engine and its local dependency closure. Package-index resolution
remains a binary-mode concern.
Before accepting the replacement virtual environment or starting services,
the local installer imports the SDK and runtime entry modules together. An
import incompatibility between sibling source revisions fails installation and
restores the previous virtual environment.

## Installed State

Runtime state and generated configuration live below the configured
`MN_HOME` (documented default `~/.mn`), including private Python tools,
commands, downloads, caches, and the sandbox clients and configuration created on demand. All modes
write `MN_HOME/env` and automatically maintain a marked shell startup block for
the login shell: Bash interactive and selected login profiles, Zsh interactive
and login profiles (honoring exported `ZDOTDIR`), Fish `conf.d` (honoring
`XDG_CONFIG_HOME`), or `.profile` for POSIX login shells. Fish also gets
`MN_HOME/env.fish`. New terminals can run `mn` directly; existing terminals get
a shell-appropriate one-time reload command. Reinstall preserves unrelated
profile content, symlinks and permissions and does not duplicate PATH entries.
Unsupported shells and profile-write failures are reported explicitly. Ordinary
reinstall preserves durable state in place rather than copying and deleting it. Generated Compose environment belongs in installed state, not in
this checkout. Binary and GitHub installs default `MN_ENV` to `prod` and
disable local skill sources; local source installs enable them explicitly. An
explicit `MN_ENV` or `MN_USE_LOCAL_SKILLS` value remains authoritative. Redis
is an attached service. Membrane preparation is an
explicit package-install operation: installers and `mn runtime
ensure-context-engine` prepare the configured image before it is needed. A
blueprint that requires context memory may start that prepared image but must
not build or clone Membrane source.

The native Web UI server may proxy an external job UI only after it
loads that job's authenticated durable UI handle from the local API. Its target
host is fixed by that handle and its ports are limited to the handle's declared
allowlist; it is never a general LAN proxy or browser redirect to a remote
runtime node.
The API checks readiness through this same iframe route. Authenticated probe
requests load the address/lifecycle descriptor without recursive readiness
checks; they still enforce the active lifecycle and declared ports. Ordinary
iframe and WebSocket requests require a current readiness receipt. Probe headers
and API credentials are removed before forwarding to worker services. Apply
matching API and Compose proxy revisions together; historical support snapshots
remain unchanged.

Install operations must be restartable after partial completion. Existing
valid configuration is preserved unless the selected operation explicitly
replaces it. Failures identify the failed component and a recovery action.

The current Compose template defaults both `MN_LITELLM_MAX_CONCURRENT_REQUESTS`
and `MN_LITELLM_MAX_CONCURRENT_EMBEDDINGS` to five. The matching SDK gateway
routes provide five parallel slots per model owner. Queue bounds and timeouts
are separate settings; historical support snapshots retain their released defaults.

## Release Support Contract

- `docker-compose.yml` is the current development/release template.
- `install_support/<version>/` is the immutable support snapshot for a released
  installer version.
- `package-index/python-packages.toml` defines the Python packages included in
  publishing/install flows.
- Computer Use is indexed as the optional `mirrorneuron-computer-use-skill`
  distribution; declaring it does not enable native desktop control at install.
- GAR generic packages `mn-client-support`, `mn-cli` and `mn-api` each contain one portable WASI component and its checksum at an immutable version tag.
  The configured GAR project supplies Python packages, Web UI assets and
  runtime images through its Python, npm and Docker repositories.
- Version changes across scripts, snapshots, package metadata, and artifacts
  must remain coherent.
- The release snapshot contains the runtime Compose template and its Python inventory. Client-only mode installs stock Wasmtime and the three Wasm components in a single generation under `MN_HOME`. Both public facades call the support component over WIT and Core uses its versioned gRPC contract.
- Historical snapshots are not rewritten to adopt current defaults.

## Safety and Security

`scripts/release.sh changed` is an explicit component repair flow.
Its default local preview is read-only. Apply advances changed Python/npm
versions, keeps Core and the aggregate installer version fixed, and repairs
changed Docker images under their current tags in a mutable-tag repository.
It validates compatible Python pins and built wheels, verifies GAR publication,
then writes component metadata and a new immutable support snapshot. It commits
the generated `mn-deploy` files and pushes `origin/main`.
Support and package-index defaults advance independently of the installer/Core
version; URL downloads honor those respective pins. Historical explicit
installer versions continue selecting their historical support and inventory.
`--publish-scripts` copies the finalized installer and uninstaller to
`/Users/homer/Projects/mn-website/public` and commits and pushes them to
`origin/main`. `--remove-old-versions` requires that flag. Cleanup starts after
all selected releases are verified and both pushes succeed. Its scope is the
previous Python and npm pins replaced by the apply and the recorded Docker
digests whose tags moved and that have no remaining tags. Pending finalization
can resume after a Git or GAR failure. Source repositories and the paths
being published must be clean when starting apply.
Python retry caches reuse complete, checksum-validated package builds across
release plans only for matching package versions, source fingerprints and build
formats. Existing uploads require exact GAR hashes; a rebuilt retry can restore
the matching original cached build but cannot accept different published bytes.
Plans reserve versions recorded by earlier completed builds. Changed package
inputs advance to a new patch, with SDK version grouping and dependency checks
preserved, even if an earlier attempt stopped before updating the main index.
Full automatic releases skip version numbers already used by support snapshots.
Full and component releases pin the Web UI version in the installer. They
update the Compose pin only in templates that include the Web UI.
The aggregate release entrypoint is `scripts/release.sh all`. Its read-only
`--plan` uses an explicitly selected Python, the existing publishing environment,
or `python3` on PATH when that environment is absent. Planning requires Python
3.12 with `packaging` and `tomllib`; publishing retains the Python 3.12 contract.
Preview never prepares an environment or installs dependencies.

- Installation, removal, service control, state clearing, registry setup, and
  publishing are state-changing operations and require explicit invocation.
- Destructive targets must be resolved to known installed roots before removal.
  Empty variables, home-directory globs, and workspace-wide deletion are
  invalid targets.
- Credentials and tokens come from the environment or approved credential
  mechanisms and stay out of installer diagnostics. After successful startup,
  the installer intentionally prints a copyable `mn node add` command with the
  runtime control token to the invoking operator.
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
- The bulk commit/push helper publishes existing local commits even when the
  working tree is clean. Remote updates are fast-forwarded before local work
  is committed; pushes never force-update remote history.
- Rust clients use `main` for published implementations. The paired Python
  archive directories publish only to `python-legacy`. A legacy checkout on
  `main` switches automatically when its commit matches the published Python
  tip. A Rust checkout can inherit a missing `origin` from its paired archive.
- After synchronization, `--markdown-prettier` applies Prettier to Markdown
  and `--ruff-format` applies Ruff to Python files and type stubs. Each
  flag is optional and the two may be combined.
  Each uses its repository's configured hook and pinned environment through
  `uvx`. Selection intersects the hook filters with pending push files,
  including non-ignored untracked files. A formatter failure stops the
  repository before commit or push. Ordinary pre-push checks remain enabled.

## Portability and Output

User-facing entrypoints support the documented macOS/Linux host paths. Shell
code must quote values, handle spaces in paths, and avoid undocumented global
tools. Non-interactive execution is line-oriented and deterministic; color is
TTY-only and disabled by `NO_COLOR`.

Installer output presents one resolved plan, detected host information, and
numbered stages for the selected installation role. It confirms client
installation, runtime installation and runtime startup separately. A successful
installation prints one completion message. The primary `Next:` command includes
the environment reload when needed. An installation that starts a runtime ends
with the connect command for its advertised gRPC endpoint. Reinstalling a
connected client preserves its credential and offers `mn node list` as the next
step.

`--help` shows common choices; `--help-all` includes the selected mode's complete
reference. `--mode MODE --help` retains its mode-specific reference. Help does
not prepare an installation or acquire its lifecycle lock. `--verbose` exposes
substeps, Podman output, and local editable Python build diagnostics. Default
failures identify retained logs and keep nonzero exit status.
TTY progress may animate while waiting for background work; redirected output,
`NO_COLOR` (including an empty value), and `TERM=dumb` contain no ANSI controls.
Yes/no prompts preserve defaults, validate responses and fail with instructions
on EOF. Exact `YES` reset confirmation and deterministic non-interactive behavior
are unchanged. `--detect-only` remains JSON-only.

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

The SDK installer group includes `mn-blueprint-blocks` in binary and GitHub
installs. GitHub source selection uses group membership and a validated SDK
component path, without requiring a distribution-name prefix. Local discovery
includes the same component. It remains in the runtime publishing inventory and
shares the SDK version group. Release this selection change with a new immutable
install-support snapshot; historical snapshots retain their original defaults.

The Python package index includes independently built SDK component projects
under `mn-python-sdk/packages/`. Local source installation resolves every SDK
component and the runtime in one editable transaction, so
no internal SDK dependency falls back to GAR. GitHub source installation uses
the SDK installer group, and binary installation selects versioned wheels from
the same inventory and preserves extras when using a bundled wheelhouse.

RAG, models, MCP, collaboration, and Job response engines are not binary or
GitHub installer defaults. Local development installs bind their distributions
to sibling source checkouts, while blueprints and native response services
still decide which capabilities to enable or prepare at runtime. A new release
must publish the indexed packages and refresh its version pins and
install-support snapshot together. Release preparation compares tracked package inputs with the previous release
and automatically increments changed packages by one patch. Before writing
metadata, preparation selects the lowest compatible final `MAJOR.MINOR.PATCH`
at or above those proposals using every indexed project's runtime and optional
requirements, across platforms. Development minimums may promote a package to
its matching final release; no development versions or downgrades are selected.
Conflicting constraints fail preparation without changing the release inputs.
Unchanged packages retain their versions when compatible; manually advanced
static versions are preserved. Frozen dependency pins are checked before builds,
and built-wheel dependencies remain a separate gate before upload. Python builds
use temporary archives of clean committed repositories, preserving shared build
configuration and keeping backend-generated files out of source checkouts. An
incompatible frozen set requires a new aggregate version and snapshot. The SDK
and its component wheels share one version group because blueprint capability
defaults derive from SDK identity. Skills, agents, and Membrane Python
projects advance independently. The CLI, API, and support Wasm releases share
a version so each client can use its matching support component. Missing SDK index entries fail preparation;
historical snapshots remain immutable. The aggregate release builds the indexed Python inventory and a
self-contained Web UI npm package from local sibling worktrees, publishes and
verifies them in the single configured GAR project, and only then pushes the
prepared source tags. GitHub release workflow outputs are not release inputs. MirrorNeuron-owned packages are installed from GAR; third-party dependencies continue to resolve directly from PyPI and npmjs. GAR's Python, npm, and Docker formats
remain separate repositories within that project.
Source and wheel tests do not require a live runtime installation.

The current Compose template starts the authenticated Membrane v2 service with
CPU processing, authoritative Markdown and one disposable DuckDB index per job.
Optional last-resort record selection uses the existing LiteLLM `default` route
after CPU compaction still exceeds the final budget. Context preparation does not
download or start a separate Docker Model Runner compressor. The installer creates a private persistent
`context_auth.token` and forwards the same token to Core and workers. Publish a
coordinated SDK/engine release before using binary installs; immutable historical
support snapshots retain their original contracts.

The current installer selects Membrane GAR release `v2.0.0` by default through
`MN_DEFAULT_MEMBRANE_CONTEXT_ENGINE_VERSION`. The image implements
`mirrorneuron.context.v2` for matching Membrane SDK 2 clients. Older context
protocols and automatic memory migration are unsupported; historical
install-support snapshots remain immutable.
The engine version is independent of the aggregate installer `--version`;
`MN_MEMBRANE_ENGINE_IMAGE_TAG` remains the explicit engine-tag override.

Core and Membrane source builds on small local macOS Podman machines can use
temporary guest swap to reach 6 GiB of combined build memory. Each build owns
and releases its allocation. Remote connections use their configured resources.

Use `./install_dev.sh --build-membrane` to build the Membrane runtime
image from the sibling `Membrane` checkout. `MN_MEMBRANE_DIR` may select another
local checkout. Binary and GitHub modes ignore this flag and use GAR images.
The flag selects `mirror-neuron-memory-engine:local`, records source mode, and
builds the Dockerfile `runtime` target once per installer invocation using the
normal Docker cache. Subsequent runtime/blueprint startup does not build images.
Missing source and `--build-membrane --no-context-engine` fail before installation;
a failed build stops installation without selecting an older image. No image is
published and no memory migration is performed.

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
resource. When GAR reports that a selected OCI child manifest is still
referenced, its selected parent manifest is deleted first and the child is
retried; a parent outside the confirmed plan is never added to the deletion
set. An updated deletion plan during confirmation aborts for fresh review.
Tests use a fake gcloud executable and must never clean the live registry.

# Desktop node identity contract

Managed Core launch commands reject empty, malformed, and nonode@nohost names
in both release and source modes. Reinstall preserves the configured name before
rewriting Compose environment; the CLI validates and persists identity before
creating containers. Installer detection uses runtime status JSON and reports
status identity_invalid with runtime_ready false for an identity failure.
Release these templates together with the persistent-identity CLI and Core;
historical install-support snapshots must not be modified.

## Filesystem runtime memory (unreleased)

The current Compose template mounts the installed home directory's `memory/`
into Membrane at `/var/lib/mirrorneuron/memory` and sets
`MN_CONTEXT_FS_MEMORY_ROOT`. Markdown revisions hold complete preprocessed text
and durable runtime receipts. Job memory is shared explicitly; run memory is
isolated. One disposable DuckDB file per job provides lexical, graph and vector
queries. `MN_CONTEXT_AUTH_TOKEN` binds trusted runtime access. Optional
`MN_CONTEXT_OBSERVABILITY=true` logs detailed authorized sources and assembly.
Membrane has no Redis dependency and CPU settings default to two DuckDB threads
and 256 MiB. Optional embeddings require a configured local CPU checkpoint.
This profile requires Membrane SDK 2 and the matching v2 engine. A new coordinated
release is required for binary installations; historical snapshots remain unchanged.
These source edits do not restart or reset an installed runtime.

The current template publishes Membrane gRPC only on `127.0.0.1`, using
`MN_CONTEXT_HOST_PORT` (default `50052`). Authentication remains mandatory.
This host endpoint serves the native SDK Job responder; container clients use
the internal service DNS. Ship the matching SDK connection selection with this
template. Existing deployments need template application and a native SDK
restart, without resetting Job data or memory. Historical snapshots remain
unchanged.

Managed Markdown context turns may bind a trusted serving-tokenizer integration
with `MN_CONTEXT_TOKEN_COUNTER_FACTORY=package.module:create_counter`. The factory
receives `request`, `scope` and `principal` keyword arguments and returns a
Membrane `VerifiedCounter` calibrated against actual provider prompt usage for
that request's serving route, including tools and schema framing. Workers receive
the setting through native/runtime preparation. No factory means counting remains
unavailable; errors or lexical/byte estimates never authorize dispatch. Install
the serving integration in the worker environment before enabling live managed
turns. Tokenization and context processing must remain on CPU.

Register `mn-context-source-code` as an optional `membrane-tools` package with
`binary_default=false`. Version-constrained local runtime requirements resolve
its authoritative source path through this inventory. Registration is not a
publication; binary deployments require the coordinated SDK/child release and
a new immutable install-support snapshot.
Include the existing code-search and BEAM-analysis skill packages in the optional
skill inventory; neither becomes a binary default or an automatically enabled
runtime capability.

## GPU model serving

The SDK prepares each catalog GGUF model with native llama.cpp on the owner.
macOS selects Metal and Linux selects CUDA or Vulkan. The host stores weights
and starts a dedicated authenticated server on first use. The LiteLLM gateway
runs in Podman and reaches each native model through the host gateway.
Legacy model and worker identifiers remain accepted by the SDK and Core.

## Federated live Web UI routing

The native Web UI proxy consumes the API's `mn.web_ui.transport.v1` owner route
for HTTP assets, streams and WebSockets. It forwards the current execution and
one relay hop using server-side API credentials, and strips those credentials
from direct worker requests. Same-origin API calls use the installed surface
credential when the request has no Authorization header. Browser-facing job
pages receive their local proxy path for companion connections. Private Docker
addresses are resolved on their hosting computer. Client disconnects close
upstream connections. Established WebSockets stay open after the handshake.

## Native computer-use app releases

`scripts/publish.sh computer-use` plans by default;
`--apply` builds, Developer ID signs, notarizes, staples and publishes macOS arm64
and x86_64 ZIPs to public `mirrorneuron-binaries/mn-computer-use` in GAR. The native
app version plus the SHA-256 of bundled Swift/plist sources identifies an immutable
release. Per-architecture checksum manifests are uploaded last; existing artifacts
must match and are verified through anonymous HTTPS downloads. Unchanged releases
are verified and reused. The tool never changes repository IAM or overwrites files.

`release.sh all` runs the `computer-use` phase before Python publication;
`update-changed-components.py` also publishes/verifies native artifacts before a
changed computer-use skill wheel. New builds require macOS with Xcode Command Line
Tools, a Developer ID Application identity for team `983M79B224`, and either
`MN_NOTARY_KEYCHAIN_PROFILE`, `KEY`/`KEY_ID`/`ISSUER`, or
`APPLE_ID`/`APPLE_APP_SPECIFIC_PASSWORD`/`APPLE_TEAM_ID`.
`MN_COMPUTER_USE_SIGNING_IDENTITY` optionally selects the signing identity. Keep
credentials in the release environment/keychain, never in source or command logs.

The helper is not installed by OtterDesk or any runtime installer mode. Its skill
remains `binary_default = false`. Co-worker dependencies opt in with
`setup: on_install`; the SDK invokes setup during API hiring or CLI blueprint add.
Customer setup downloads and verifies the notarized artifact without a compiler,
Xcode or gcloud. Existing immutable install-support snapshots remain unchanged.

The developer-only `--use-experiemental-sdk` option selects the `mn-sdk` host and Python authoring interface for the complete runtime installation. It requires a runtime source installation and applies to local and GitHub modes.
Executable agent factories and host-backed WIT skills install into the selected SDK environment. GitHub mode pins the skills checkout by commit. Membrane-enabled installations include its gRPC client for document and review memory.
