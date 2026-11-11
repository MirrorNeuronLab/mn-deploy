# Application surfaces and runtime nodes

Binary installations have three explicit roles. `MN_HOME` overrides the default
home and each installed command remembers its home.

| Command                       | Role      | Installed components                                                     | Default home    |
| ----------------------------- | --------- | ------------------------------------------------------------------------ | --------------- |
| `./install.sh`                | `full`    | CLI/API surface and runtime node                                         | `~/.mn`         |
| `./install.sh --no-runtime`   | `client`  | CLI/API and their Python libraries                                       | `~/.mn-client`  |
| `./install.sh --runtime-only` | `runtime` | Core, native runtime, Redis, Compose and selected execution dependencies | `~/.mn-runtime` |

The role flags are mutually exclusive. Local and GitHub source modes print a
notice, consume the flags, and install both parts. Client mode performs no Docker
discovery, compute registration, model setup, or service startup. Runtime mode
installs neither `mirrorneuron-cli` nor `mirrorneuron-api` nor the application Web
UI. Job-provided UIs remain supported as execution services.

Full and runtime installations start their selected services by default. Use
`--no-start` to prepare an installation without starting services. A full startup
waits for authenticated runtime readiness before starting its surface. It creates
an automatic local connection if no profile exists. A client starts no services;
`mn-api` is an optional foreground process.

## Connect

```bash
# On the execution computer:
./install.sh --runtime-only
# Share its reachable Core gRPC host/port and runtime.token securely.

# On an application computer:
./install.sh --no-runtime
mn node add runtime.example --grpc-port 55051 --token "$RUNTIME_NODE_TOKEN"
mn blueprint run example --node worker@example --queue

# Alternatively, attach separately installed parts on the same computer:
mn node add local --runtime-home ~/.mn-runtime
mn-api
```

Use a runtime control token, not a surface API bearer token or federation token.
A remote host is a hostname or IP address, optionally with a port; HTTP API URLs
are not runtime endpoints. IPv6 addresses with ports use brackets. Local
attachment reads installed private credentials and validates the installation
identity; omitting `--runtime-home` requires exactly one discoverable runtime.
No anonymous remote attachment is supported. Expose the Core endpoint only over
your intended trusted network or secure tunnel.

CLI and API share one atomic mode-0600 `MN_HOME/client.json` profile. Validation
checks runtime identity, protocol version and required capabilities before
committing the profile. A failed connection leaves the prior profile intact;
subsequent requests use a successful change while existing streams retain their
original connection. Legacy `api_url` profiles require explicit reconnection
with a runtime endpoint/token and remain intact until that succeeds.

The first `mn node add` attaches the surface to an entry runtime. Later additions
ask that runtime to federate with another runtime. All runtime nodes belong to
the shared cluster; the surface never registers as a compute node. A full install
uses this same native connection protocol for its local node.

`mn node list/show` inspect cluster membership. `mn node remove NODE` removes that
runtime from the cluster only after its authoritative drain and admission checks
pass. Drain and finish existing work first; removal does not cancel work, stop
services, uninstall packages or erase data. Removing the entry node also deletes
this surface's connection profile. The REST equivalents are `POST /api/v1/nodes`
and `DELETE /api/v1/nodes/{node_id}`.

## Runtime ownership

`mirrorneuron-runtime` lives in `mn-python-sdk/packages/runtime` and imports as
`mn_runtime`. It owns host lifecycle, native service hosting, model/storage
monitors, context-service startup, blueprint catalogs, preparation hooks,
dependency setup, durable preparation operations, and delivery observation.
Core owns membership, admission, scheduling, execution, persistence and ownership.
The SDK owns wire contracts, clients, validation and reusable preparation logic.
Neither surface package depends on the runtime package; runtime modules never
import either surface package.

Core's exposed gRPC endpoint serves the versioned runtime-control gateway. It
terminates the runtime credential and delegates host work to its private native
service. Peer forwarding uses registered Core membership and separate federation
credentials. Required capabilities cover catalog, preparation, durable operations,
events, artifacts, uploads, job UIs, membership and MCP. Incompatible nodes fail
with an upgrade instruction instead of selecting another transport.

The surface continues to expose REST `/api/v1`, including structured errors,
operations, SSE, byte ranges, downloads, existing uploads and job UI HTTP and
WebSockets. Its bearer token comes from `api.token` or `MN_API_TOKEN` and is never
forwarded to a runtime or job UI. Runtime owner streams replace owner-node REST
calls. File reads retain owner/generation fences; UI streams retain execution
identity, registered port allowlists and cancellation.

Blueprint preparation runs on runtime nodes and survives a surface disconnect.
Remote catalog IDs and input paths resolve on the runtime. Existing local path,
repository, revision and offline workflows require attachment to a local runtime;
there is no new implicit source packaging/upload workflow. Configuration overrides,
job/run IDs, node selection, queue admission, scheduling and monitoring keep their
existing meanings. After an interrupted request, observe its existing job or
operation before submitting again: transport clients never automatically resubmit.

## Lifecycle and maintenance

`MN_HOME/bin/mn-runtime` and `MN_HOME/server.sh` operate without CLI/API packages:

```bash
~/.mn-runtime/bin/mn-runtime status --json
~/.mn-runtime/server.sh start
~/.mn-runtime/server.sh stop
```

The `mn runtime` commands delegate to that installed entry point. In client mode
they report that no local runtime is installed and never bootstrap one. Stopping
an API or CLI process leaves runtime preparation and execution running.

`install_metadata.json.install_role` is `full`, `client` or `runtime`. Same-role
reinstallation preserves identity, jobs, credentials and connection settings.
Changing roles requires another installation directory; an installer does not
implicitly convert an existing directory. Detection, reset, uninstall, package
selection and service startup follow the persisted role. An explicit reset remains
destructive and uses the installer's existing confirmation. Uninstall only targets
the selected installation and its owned resources.

## Release gate

Release the matching Core, SDK components, runtime, CLI and API pins together with
a new immutable installer-support snapshot. Historical snapshots are unchanged.
Run package/import closure checks, offline contracts, fake-tool installer tests,
and pinned repository checks before publishing. The live acceptance gate must be
explicitly provisioned:

```bash
cd ../mn-system-tests
RUN_MN_SYSTEM_TESTS=1 MN_SPLIT_RUNTIME_ACCEPTANCE=1 \
  PYTHONPATH=../mn-python-sdk/packages/runtime/src \
  .venv/bin/python -m pytest tests/integration/live/test_split_runtime_acceptance.py
```

That test uses two private Core/native processes, temporary Redis containers,
independent credentials and ephemeral ports; it never attaches to an installed
node. A skipped live gate is not release acceptance.

The coordinated installer pins are Core `v1.4.1`, Python SDK/runtime/CLI/API
`1.4.8`, and support snapshot `v1.4.15`. These artifacts must be published together
before the binary defaults can be consumed from the public package registry.

`bash scripts/validate-runtime-split.sh --two-runtimes` runs all required local
checks, clean wheel builds and the provisioned acceptance test. `release_all.sh`
requires it before publishing, including resumed releases. Review-time source
checks use `prepare-python-package-index.py --verify-worktree`; publishing still
requires clean committed source matching the index and immutable release tags.
