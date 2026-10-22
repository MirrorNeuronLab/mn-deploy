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
let transport;
let contentType = "text/html";
let upstreamRequest;
http.request = (target, options, callback) => {
  if (typeof options === "function") { callback = options; options = {}; }
  const descriptor = !(target instanceof URL);
  requests.push({ target, options, descriptor });
  const request = new EventEmitter();
  if (!descriptor) upstreamRequest = request;
  request.end = () => {};
  request.destroy = () => { request.destroyed = true; };
  queueMicrotask(() => {
    const response = new EventEmitter();
    response.statusCode = 200;
    response.headers = { "content-type": contentType };
    response.pipe = (destination) => {
      response.on("data", (chunk) => destination.end(chunk));
    };
    callback(response);
    const raw = descriptor && target.path.endsWith("?check_readiness=false");
    response.emit("data", descriptor
      ? Buffer.from(JSON.stringify({ web_ui: { status: raw ? status : (currentReady ? status : "starting"),
          url: "http://docker-only-worker:8080/?control=1", transport,
          metadata: { readiness: { ready: currentReady }, proxy: { websocket_ports: [8080] } } } }))
      : Buffer.from("<html><head></head></html>"));
    response.emit("end");
  });
  return request;
};
async function forward(token, requestedPort = 8080, path = "", method = "GET") {
  requests = [];
  const request = { method, headers: { "x-mn-job-ui-probe": "1", authorization: "Bearer " + token, cookie: "private=1" }, pipe() {} };
  const response = Object.assign(new EventEmitter(), { writeHead(code) { this.status = code; }, end(body) { this.body = body; } });
  await proxyJobUi(request, response, { jobId: "job-1", port: requestedPort, path }, "?control=1");
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
transport = { schema_version: "mn.web_ui.transport.v1", execution_id: "execution", owner_api_url: "http://10.0.4.32:54001/api/v1" };
assert.equal((await forward("test-token")).status, 200);
assert.equal(requests[1].target.href, "http://10.0.4.32:54001/api/v1/jobs/job-1/ui-proxy/8080/?control=1");
assert.equal(requests[1].options.headers.authorization, "Bearer test-token");
assert.equal(requests[1].options.headers["x-mn-ui-hop"], "1");
assert.equal(requests[1].options.headers["x-mn-ui-execution"], "execution");
assert.equal(relayTarget({transport}, "job-1", 8080, "bridge", "?control=1", true).href,
  "ws://10.0.4.32:54001/api/v1/jobs/job-1/ui-proxy/8080/ws/bridge?control=1");
const raw = { rawHeaders: ["Authorization", "Bearer browser", "Cookie", "secret", "X-MN-UI-Hop", "5", "Sec-WebSocket-Key", "key"] };
const forwarded = websocketHeaders(raw, new URL("ws://owner/"), {transport});
assert.ok(forwarded.includes("Authorization: Bearer test-token"));
assert.ok(!forwarded.includes("browser") && !forwarded.includes("secret") && !forwarded.includes("5"));
transport.owner_api_url = "http://user:secret@10.0.4.32:54001/api/v1";
assert.throws(() => relayTarget({transport}, "job-1", 8080, "", ""), /invalid relay/);
transport.owner_api_url = "http://10.0.4.32:54001/api/v1";
const ownerTransport = transport;
for (const placement of [undefined, ownerTransport]) {
  transport = placement;
  for (const [path, type, method] of [["index.html", "text/html", "GET"],
    ["assets/app.js", "application/javascript", "GET"], ["assets/app.css", "text/css", "HEAD"],
    ["stream", "multipart/x-mixed-replace;boundary=frame", "GET"]]) {
    contentType = type;
    const result = await forward("test-token", 8080, path, method);
    assert.equal(result.status, 200);
    assert.ok(requests[1].target.href.endsWith("/" + path + "?control=1"));
    assert.equal(requests[1].options.method, method);
    assert.equal(requests[1].options.headers.cookie, undefined);
    result.emit("close");
    assert.equal(upstreamRequest.destroyed, true);
  }
}
transport = ownerTransport;
currentReady = true;
const remote = Object.assign(new EventEmitter(), { write(data) { this.written = data; }, pipe(destination) { return destination; }, destroy() { this.destroyed = true; } });
const socket = Object.assign(new EventEmitter(), { pipe(destination) { return destination; }, destroy() { this.destroyed = true; } });
net.connect = () => remote;
await proxyJobUiWebSocket({ headers: {}, rawHeaders: ["Sec-WebSocket-Key", "client-key"] }, socket, Buffer.alloc(0),
  { jobId: "job-1", port: 8080, path: "bridge" }, "?control=1");
remote.emit("connect");
assert.ok(remote.written.startsWith("GET /api/v1/jobs/job-1/ui-proxy/8080/ws/bridge?control=1 HTTP/1.1"));
assert.ok(remote.written.includes("Authorization: Bearer test-token"));
remote.emit("data", Buffer.from("HTTP/1.1 101 Switching Protocols\r\n\r\n"));
socket.emit("close");
assert.equal(remote.destroyed, true);
'''
    test = tmp_path / "proxy-test.mjs"
    test.write_text(helpers + harness)
    result = subprocess.run([node, str(test)], check=False, capture_output=True, text=True, timeout=10,
                            env={"PATH": os.environ.get("PATH", ""), "MN_API_TOKEN": "test-token"})
    assert result.returncode == 0, result.stderr
