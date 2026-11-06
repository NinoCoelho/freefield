// Freefield MCP server — wraps the HTTP API (npm run serve) over stdio.
// Env: FREEFIELD_URL (default http://127.0.0.1:3000)

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
  ErrorCode,
  McpError,
} from "@modelcontextprotocol/sdk/types.js";
import { join, dirname } from "node:path";
import { mkdirSync, writeFileSync } from "node:fs";

const BASE_URL = process.env.FREEFIELD_URL || "http://127.0.0.1:3000";

interface AppSummary {
  id: string;
  name: string;
  section: string;
  summary: string;
  status: string;
  runnable: boolean;
  models: Array<{ name: string; repo: string; gb: number; license: string | null; gated: boolean; optional: boolean; phase: string }>;
  vram: { whole_gb: number; largest_phase_gb: number; verdict: string; measured_gb: number | null } | null;
}

interface AppDetail extends AppSummary {
  inputs: Array<{ id: string; type: string; label: string; required?: boolean; default?: unknown; options?: Array<{ value: unknown; label: string }>; min?: number; max?: number; step?: number; help?: string; bind?: unknown }>;
  presets: Array<{ id: string; label: string }>;
  outputs: Array<{ type: string; label: string | null }>;
  credits: Array<string>;
  notes: string | null;
}

interface RunView {
  id: string;
  app: string;
  status: string;
  created: string;
  started: string | null;
  finished: string | null;
  values: Record<string, unknown>;
  preset: string | undefined;
  progress: { value: number; step: number | null; steps: number | null; node: string | null } | null;
  outputs: Array<{ node: string; name: string; type: string; url: string }>;
  error: string | null;
}

interface GPUStatus {
  configured: boolean;
  host: string | null;
  warm: boolean;
  last_contact: string | null;
  waking: { seconds: number; error: string | null } | null;
  running: number;
  device: { app: string | null; name: string | null; vram_total_gb: number | null; vram_used_gb: number | null } | null;
}

async function fetchJson<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(`${BASE_URL}${path}`, {
    headers: { "content-type": "application/json", ...init?.headers },
    ...init,
  });
  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new McpError(ErrorCode.InternalError, `${path} failed: ${res.status} ${text}`);
  }
  return res.json() as Promise<T>;
}

async function fetchBlob(path: string): Promise<Uint8Array> {
  const res = await fetch(`${BASE_URL}${path}`);
  if (!res.ok) throw new McpError(ErrorCode.InternalError, `${path} failed: ${res.status}`);
  return new Uint8Array(await res.arrayBuffer());
}

function fileTypeFromPath(path: string): string {
  const ext = path.split(".").pop()?.toLowerCase();
  if (["png", "jpg", "jpeg", "webp", "gif", "bmp"].includes(ext || "")) return `image/${ext === "jpg" ? "jpeg" : ext}`;
  if (["mp4", "webm", "mov"].includes(ext || "")) return `video/${ext}`;
  if (["mp3", "wav", "flac", "ogg", "m4a"].includes(ext || "")) return `audio/${ext}`;
  return "application/octet-stream";
}

const server = new Server(
  { name: "freefield", version: "0.1.0" },
  { capabilities: { tools: {} } },
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "list_apps",
      description: "List all Freefield apps with their models and VRAM info. Optionally filter by section (image, video, audio, utility).",
      inputSchema: {
        type: "object",
        properties: { section: { type: "string", enum: ["image", "video", "audio", "utility"] } },
        additionalProperties: false,
      },
    },
    {
      name: "get_app",
      description: "Get full details for one app: input schema with types/options/defaults, presets, outputs, credits, notes, and the lab example.",
      inputSchema: { type: "object", properties: { id: { type: "string" } }, required: ["id"], additionalProperties: false },
    },
    {
      name: "run_app",
      description: "Run an app. File inputs take a local path (server reads + uploads). Polls to completion by default; saves outputs to out/mcp/<run-id>/ and returns local paths. Image outputs also returned as image content blocks.",
      inputSchema: {
        type: "object",
        properties: {
          id: { type: "string" },
          inputs: { type: "object", additionalProperties: true },
          preset: { type: "string" },
          wait_seconds: { type: "number", default: 3600 },
        },
        required: ["id"],
        additionalProperties: false,
      },
    },
    {
      name: "get_run",
      description: "Get a run's status, live progress (step/steps, current node), outputs, and error.",
      inputSchema: { type: "object", properties: { id: { type: "string" } }, required: ["id"], additionalProperties: false },
    },
    {
      name: "list_runs",
      description: "List recent runs, optionally filtered by app.",
      inputSchema: { type: "object", properties: { app: { type: "string" } }, additionalProperties: false },
    },
    {
      name: "save_run_file",
      description: "Download a run's output file to a local path.",
      inputSchema: { type: "object", properties: { run_id: { type: "string" }, file: { type: "string" }, path: { type: "string" } }, required: ["run_id", "file"], additionalProperties: false },
    },
    {
      name: "gpu_status",
      description: "Check if the GPU backend is warm and VRAM in use.",
      inputSchema: { type: "object", properties: {}, additionalProperties: false },
    },
    {
      name: "gpu_wake",
      description: "Wake the GPU container now (while preparing inputs).",
      inputSchema: { type: "object", properties: {}, additionalProperties: false },
    },
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  try {
    switch (name) {
      case "list_apps": {
        const data = await fetchJson<{ apps: AppSummary[] }>("/api/apps");
        let apps = data.apps;
        if (args?.section) apps = apps.filter((a) => a.section === args.section);
        return { content: [{ type: "text", text: JSON.stringify(apps, null, 2) }] };
      }

      case "get_app": {
        if (!args?.id) throw new McpError(ErrorCode.InvalidParams, "id required");
        const data = await fetchJson<{ apps: AppDetail[] }>("/api/apps");
        const app = data.apps.find((a) => a.id === args.id);
        if (!app) throw new McpError(ErrorCode.InvalidParams, `app ${args.id} not found`);
        return { content: [{ type: "text", text: JSON.stringify(app, null, 2) }] };
      }

      case "run_app": {
        if (!args?.id) throw new McpError(ErrorCode.InvalidParams, "id required");
        const appId = args.id as string;
        const inputs = (args.inputs as Record<string, unknown>) || {};
        const preset = args.preset as string | undefined;
        const waitSeconds = (args.wait_seconds as number) || 3600;

        // Prepare multipart form
        const form = new FormData();
        if (preset) form.append("preset", preset);

        for (const [key, value] of Object.entries(inputs)) {
          if (value && typeof value === "object" && "bytes" in value) {
            // File input: { bytes: Uint8Array, name?: string, type?: string }
            const fileInput = value as { bytes: number[] | Uint8Array; name?: string; type?: string };
            const bytes = fileInput.bytes instanceof Uint8Array ? fileInput.bytes : new Uint8Array(fileInput.bytes);
            const blob = new Blob([bytes.buffer as ArrayBuffer], { type: fileInput.type || "application/octet-stream" });
            form.append(key, blob, fileInput.name || "upload");
          } else {
            form.append(key, String(value));
          }
        }

        // Submit
        const submitRes = await fetch(`${BASE_URL}/api/apps/${appId}/run`, {
          method: "POST",
          body: form,
        });
        if (!submitRes.ok) {
          const text = await submitRes.text().catch(() => "");
          throw new McpError(ErrorCode.InternalError, `run submit failed: ${submitRes.status} ${text}`);
        }
        const entry = (await submitRes.json()) as RunView;
        const runId = entry.id;

        // Poll to completion
        const deadline = Date.now() + waitSeconds * 1000;
        let run = entry;
        while (Date.now() < deadline) {
          if (["succeeded", "failed", "canceled", "expired", "lost"].includes(run.status)) break;
          await new Promise((r) => setTimeout(r, 1000));
          run = await fetchJson<RunView>(`/api/history/${runId}`);
        }

        // Download outputs to out/mcp/<run-id>/
        const outDir = join(process.cwd(), "out", "mcp", runId);
        mkdirSync(outDir, { recursive: true });

        const saved: string[] = [];
        const imageBlocks: Array<{ type: "image"; data: string; mimeType: string }> = [];

        for (const out of run.outputs) {
          const bytes = await fetchBlob(`/api/history/${runId}/files/${out.name}`);
          const localPath = join(outDir, out.name);
          writeFileSync(localPath, bytes);
          saved.push(localPath);

          const mime = fileTypeFromPath(out.name);
          if (mime.startsWith("image/")) {
            imageBlocks.push({ type: "image", data: Buffer.from(bytes).toString("base64"), mimeType: mime });
          }
        }

        const result: Record<string, unknown> = {
          run_id: runId,
          status: run.status,
          progress: run.progress,
          error: run.error,
          outputs: saved,
        };
        if (imageBlocks.length) result.images = imageBlocks;

        return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }, ...imageBlocks] };
      }

      case "get_run": {
        if (!args?.id) throw new McpError(ErrorCode.InvalidParams, "id required");
        const run = await fetchJson<RunView>(`/api/history/${args.id}`);
        return { content: [{ type: "text", text: JSON.stringify(run, null, 2) }] };
      }

      case "list_runs": {
        const data = await fetchJson<{ entries: RunView[] }>(`/api/history${args?.app ? `?app=${args.app}` : ""}`);
        return { content: [{ type: "text", text: JSON.stringify(data.entries, null, 2) }] };
      }

      case "save_run_file": {
        if (!args?.run_id || !args?.file) throw new McpError(ErrorCode.InvalidParams, "run_id and file required");
        const runId = args.run_id as string;
        const file = args.file as string;
        const dest = (args.path as string) || join(process.cwd(), "out", "mcp", runId, file);
        const bytes = await fetchBlob(`/api/history/${runId}/files/${file}`);
        mkdirSync(dirname(dest), { recursive: true });
        writeFileSync(dest, bytes);
        return { content: [{ type: "text", text: `saved ${dest} (${bytes.length} bytes)` }] };
      }

      case "gpu_status": {
        const status = await fetchJson<GPUStatus>("/api/gpu?device=1");
        return { content: [{ type: "text", text: JSON.stringify(status, null, 2) }] };
      }

      case "gpu_wake": {
        const res = await fetch(`${BASE_URL}/api/gpu/wake`, { method: "POST" });
        if (!res.ok) throw new McpError(ErrorCode.InternalError, `gpu_wake failed: ${res.status}`);
        const status = await fetchJson<GPUStatus>("/api/gpu");
        return { content: [{ type: "text", text: JSON.stringify(status, null, 2) }] };
      }

      default:
        throw new McpError(ErrorCode.MethodNotFound, `Unknown tool: ${name}`);
    }
  } catch (e) {
    if (e instanceof McpError) throw e;
    throw new McpError(ErrorCode.InternalError, (e as Error).message);
  }
});

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("freefield mcp server started");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});