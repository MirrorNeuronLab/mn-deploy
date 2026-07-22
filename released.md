# Released Packages

This is the append-only record of published MirrorNeuron release artifacts.
Add a new dated section for each release; do not edit an earlier release to
represent a later publication. Record only destinations that were actually
published. Python distributions use the public GAR `agent-skills` repository;
`mirrorneuron-runtime` is Docker-only.

## 2026-07-18

| What | Version | Where |
| --- | --- | --- |
| MirrorNeuron Core runtime | `v1.2.27` | GitHub Releases (OTP tarballs). GAR: not published. |
| `mirrorneuron-api` | `1.2.27` | PyPI; GAR Python: `agent-skills` (`https://us-central1-python.pkg.dev/mirrorneuron-public-packages/agent-skills/simple/`). |
| `mirrorneuron-cli` | `1.2.27` | PyPI; GAR Python: `agent-skills` (`https://us-central1-python.pkg.dev/mirrorneuron-public-packages/agent-skills/simple/`). |
| `mirrorneuron-python-sdk` | `1.2.27` | PyPI; GAR Python: `agent-skills` (`https://us-central1-python.pkg.dev/mirrorneuron-public-packages/agent-skills/simple/`). |
| `mirrorneuron-web-ui` | `1.2.27` | npm. GAR: not published. |
| `mirrorneuron-membrane-python-sdk` | `1.2.27` | GAR Python: `agent-skills` (`https://us-central1-python.pkg.dev/mirrorneuron-public-packages/agent-skills/simple/`). |
| `membrane-context-engine` runtime image | `v1.2.27`, `1.2.27` | GAR Docker: `mirrorneuron-runtime` (`us-central1-docker.pkg.dev/mirrorneuron-public-packages/mirrorneuron-runtime/membrane-context-engine`). |
| `mirrorneuron-actor-review-skill` | `1.2.27` | GAR Python: `agent-skills`. |
| `mirrorneuron-autonomous-research-skill` | `1.2.27` | GAR Python: `agent-skills`. |
| `mirrorneuron-blueprint-support-skill` | `1.2.27` | GAR Python: `agent-skills`. |
| `mirrorneuron-client-report-skill` | `1.2.27` | GAR Python: `agent-skills`. |
| `mirrorneuron-document-reading-skill` | `1.2.27` | GAR Python: `agent-skills`. |
| `mirrorneuron-evidence-engine-skill` | `1.2.27` | GAR Python: `agent-skills`. |
| `mirrorneuron-litellm-communicate-skill` | `1.2.27` | GAR Python: `agent-skills`. |
| `mirrorneuron-llm-ocr-skill` | `1.2.27` | GAR Python: `agent-skills`. |
| `mirrorneuron-public-research-orchestrator-skill` | `1.2.27` | GAR Python: `agent-skills`. |
| `mirrorneuron-rag-skill` | `1.2.27` | GAR Python: `agent-skills`. |
| `mirrorneuron-scoring-framework-skill` | `1.2.27` | GAR Python: `agent-skills`. |
| `mirrorneuron-w3m-browser-skill` | `1.2.27` | GAR Python: `agent-skills`. |
| `mirrorneuron-web-browser-skill` | `1.2.27` | GAR Python: `agent-skills`. |
| `mirrorneuron-websocket-stream-skill` | `1.2.27` | GAR Python: `agent-skills`. |
| `mn-prototype-actor-review-agent` | `1.2.27` | GAR Python: `agent-skills`. |
| `mn-prototype-artifact-finalizer-agent` | `1.2.27` | GAR Python: `agent-skills`. |
| `mn-prototype-bounded-tool-loop-agent` | `1.2.27` | GAR Python: `agent-skills`. |
| `mn-prototype-entity-queue-agent` | `1.2.27` | GAR Python: `agent-skills`. |
| `mn-prototype-stateful-step-agent` | `1.2.27` | GAR Python: `agent-skills`. |
| `mn-prototype-stream-processor-agent` | `1.2.27` | GAR Python: `agent-skills`. |
| `mn-prototype-supervised-service-agent` | `1.2.27` | GAR Python: `agent-skills`. |

The `latest` image tag also points to the Membrane engine release digest at
publication time, but installers must use the immutable `:v1.2.27` tag.

## 2026-07-19

| What | Version | Where |
| --- | --- | --- |
| MirrorNeuron Core runtime | `v1.2.29` | GitHub Releases (OTP tarballs). |
| `mirrorneuron-api` | `1.2.29` | GAR Python: `agent-skills` (`https://us-central1-python.pkg.dev/mirrorneuron-public-packages/agent-skills/simple/`). |
| `mirrorneuron-cli` | `1.2.29` | GAR Python: `agent-skills`. |
| `mirrorneuron-python-sdk` | `1.2.29` | GAR Python: `agent-skills`. |
| `mirrorneuron-web-ui` | `1.2.29` | npm. GAR: not published. |
| `mirrorneuron-membrane-python-sdk` | `1.2.29` | PyPI; GAR Python: `agent-skills`. |
| `membrane-context-engine` runtime image | `v1.2.29`, `1.2.29` | GAR Docker: `mirrorneuron-runtime` (`us-central1-docker.pkg.dev/mirrorneuron-public-packages/mirrorneuron-runtime/membrane-context-engine`). |
| All indexed skill and agent distributions | `1.2.29` | GAR Python: `agent-skills` — 52 packages, 103 wheel/source distributions. |

The Membrane runtime image digest is
`sha256:4833dd00e712a054a35225b82f7b472d3fffbd41edceb64508943ede79e49bfa`.
The `latest` image tag also points to this digest at publication time, but
installers must use the immutable `:v1.2.29` tag.

## 2026-07-21

| What | Version | Where |
| --- | --- | --- |
| `mirrorneuron-use-generic-model-skill` | `1.2.29` | GAR Python: `agent-skills` (`https://us-central1-python.pkg.dev/mirrorneuron-public-packages/agent-skills/simple/`). |
