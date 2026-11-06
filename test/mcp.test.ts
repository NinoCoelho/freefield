// Smoke test for the MCP server: spawns it and checks the tool list + catalog tools work without GPU
import { spawn, type ChildProcess } from "node:child_process";
import { once } from "node:events";
import { test } from "node:test";
import assert from "node:assert/strict";

const MCP_CMD = ["node", "--experimental-strip-types", "--disable-warning=ExperimentalWarning", "server/mcp.ts"];
const TIMEOUT = 15000;

async function sendRequest(proc: ChildProcess, method: string, params: object, id: number): Promise<unknown> {
  const req = JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n";
  proc.stdin?.write(req);
  // Read lines from stdout until we get our response
  let buffer = "";
  while (true) {
    const [chunk] = await once(proc.stdout!, "data");
    buffer += chunk.toString();
    const lines = buffer.split("\n");
    buffer = lines.pop() || "";
    for (const line of lines) {
      if (line.trim()) {
        const parsed = JSON.parse(line);
        if (parsed.id === id) return parsed.result;
      }
    }
  }
}

test("mcp server starts and lists tools", async () => {
  const proc = spawn(MCP_CMD[0], MCP_CMD.slice(1), { stdio: ["pipe", "pipe", "pipe"], cwd: process.cwd() });
  try {
    const init = await sendRequest(proc, "initialize", { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "test", version: "1" } }, 1);
    assert.ok(init);
    await sendRequest(proc, "notifications/initialized", {}, 2);

    const tools = await sendRequest(proc, "tools/list", {}, 3);
    const names = (tools as { tools: Array<{ name: string }> }).tools.map((t) => t.name);
    assert.ok(names.includes("list_apps"));
    assert.ok(names.includes("get_app"));
    assert.ok(names.includes("run_app"));
    assert.ok(names.includes("get_run"));
    assert.ok(names.includes("list_runs"));
    assert.ok(names.includes("save_run_file"));
    assert.ok(names.includes("gpu_status"));
    assert.ok(names.includes("gpu_wake"));
  } finally {
    proc.kill();
    await once(proc, "exit");
  }
});

test("list_apps works without GPU/backend", async () => {
  const proc = spawn(MCP_CMD[0], MCP_CMD.slice(1), { stdio: ["pipe", "pipe", "pipe"], cwd: process.cwd() });
  try {
    await sendRequest(proc, "initialize", { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "test", version: "1" } }, 1);
    await sendRequest(proc, "notifications/initialized", {}, 2);

    const result = await sendRequest(proc, "tools/call", { name: "list_apps", arguments: {} }, 3);
    const content = (result as { content: Array<{ type: string; text: string }> }).content[0].text;
    const apps = JSON.parse(content);
    assert.ok(Array.isArray(apps));
    assert.ok(apps.length > 0);
    assert.ok(apps[0].id);
    assert.ok(apps[0].name);
    assert.ok(apps[0].section);
    assert.ok(["ready", "draft"].includes(apps[0].status));
  } finally {
    proc.kill();
    await once(proc, "exit");
  }
});

test("get_app returns full schema for z-image", async () => {
  const proc = spawn(MCP_CMD[0], MCP_CMD.slice(1), { stdio: ["pipe", "pipe", "pipe"], cwd: process.cwd() });
  try {
    await sendRequest(proc, "initialize", { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "test", version: "1" } }, 1);
    await sendRequest(proc, "notifications/initialized", {}, 2);

    const result = await sendRequest(proc, "tools/call", { name: "get_app", arguments: { id: "z-image" } }, 3);
    const content = (result as { content: Array<{ type: string; text: string }> }).content[0].text;
    const app = JSON.parse(content);
    assert.equal(app.id, "z-image");
    assert.ok(Array.isArray(app.inputs));
    assert.ok(app.inputs.some((i: { id: string }) => i.id === "prompt"));
    assert.ok(app.inputs.some((i: { id: string }) => i.id === "width"));
    assert.ok(app.inputs.some((i: { id: string }) => i.id === "seed"));
    assert.ok(Array.isArray(app.models));
    assert.ok(app.models.length > 0);
  } finally {
    proc.kill();
    await once(proc, "exit");
  }
});