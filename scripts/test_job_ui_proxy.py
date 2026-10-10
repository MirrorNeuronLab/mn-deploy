"""Exercise the actual Compose proxy without Docker or a live runtime."""

import os
import shutil
import subprocess
import textwrap
from pathlib import Path

import pytest


def test_compose_proxy_readiness_authentication_lifecycle_and_ports(tmp_path):
    node = shutil.which("node")
    if node is None:
        pytest.skip("Node is required to exercise the Compose Web UI proxy")
    source = (Path(__file__).resolve().parents[1] / "docker-compose.yml").read_text()
    script = source.split("<<'NODE'\n", 1)[1].split("\n          NODE", 1)[0]
    script = textwrap.dedent(script).replace("$$", "$")
    full = tmp_path / "server.mjs"
    full.write_text(script)
    subprocess.run([node, "--check", str(full)], check=True, capture_output=True, timeout=10)
    helpers = script.split("const server = http.createServer", 1)[0]
    harness = r'''
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
let requests = [];
let status = "running";
let currentReady = false;
http.request = (target, options, callback) => {
  if (typeof options === "function") { callback = options; options = {}; }
  const descriptor = !(target instanceof URL);
  requests.push({ target, options, descriptor });
  const request = new EventEmitter();
  request.end = () => {};
  queueMicrotask(() => {
    const response = new EventEmitter();
    response.statusCode = 200;
    response.headers = { "content-type": "text/html" };
    callback(response);
    const raw = descriptor && target.path.endsWith("?check_readiness=false");
    response.emit("data", descriptor
      ? Buffer.from(JSON.stringify({ web_ui: { status: raw ? status : (currentReady ? status : "starting"),
          url: "http://docker-only-worker:8080/?control=1",
          metadata: { readiness: { ready: currentReady }, proxy: { websocket_ports: [8080] } } } }))
      : Buffer.from("<html><head></head></html>"));
    response.emit("end");
  });
  return request;
};
async function forward(token, requestedPort = 8080) {
  requests = [];
  const request = { method: "GET", headers: { "x-mn-job-ui-probe": "1", authorization: "Bearer " + token }, pipe() {} };
  const response = { writeHead(code) { this.status = code; }, end(body) { this.body = body; } };
  await proxyJobUi(request, response, { jobId: "job-1", port: requestedPort, path: "" }, "?control=1");
  await new Promise((resolve) => setImmediate(resolve));
  return response;
}
assert.equal((await forward("test-token")).status, 200);
assert.equal(requests[0].target.path, "/api/v1/jobs/job-1/ui?check_readiness=false");
assert.equal(requests[1].target.href, "http://docker-only-worker:8080/?control=1");
assert.equal(requests[1].options.headers.authorization, undefined);
assert.equal(requests[1].options.headers["x-mn-job-ui-probe"], undefined);
assert.equal((await forward("wrong-token")).status, 409);
assert.equal(requests[0].target.path, "/api/v1/jobs/job-1/ui");
assert.equal(requests.length, 1);
status = "paused";
assert.equal((await forward("test-token")).status, 409);
assert.equal(requests.length, 1);
status = "running";
assert.equal((await forward("test-token", 9999)).status, 404);
assert.equal(requests.length, 1);
const ready = { status: "running", url: "http://worker:8080/", metadata: { readiness: { ready: true }, proxy: { websocket_ports: [8080] } } };
assert.equal(jobUiTarget(ready, 8080, "bridge", "", true).href, "ws://worker:8080/bridge");
ready.metadata.readiness.ready = false;
assert.throws(() => jobUiTarget(ready, 8080, "bridge", "", true), /service not running/);
'''
    test = tmp_path / "proxy-test.mjs"
    test.write_text(helpers + harness)
    result = subprocess.run([node, str(test)], check=False, capture_output=True, text=True, timeout=10,
                            env={"PATH": os.environ.get("PATH", ""), "MN_API_TOKEN": "test-token"})
    assert result.returncode == 0, result.stderr
