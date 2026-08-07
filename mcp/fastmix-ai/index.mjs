#!/usr/bin/env node
/**
 * MCP stdio bridge → FastMix AI Unix socket → single command dispatcher.
 *
 * Production agent path (user-facing):
 *   LLM → MCP tools → socket → FastMix AI handleCommand → engine → JSON
 *
 * Python scripts are for developer regression / spikes only — not this path.
 */
import { createConnection } from "node:net";
import { access } from "node:fs/promises";
import { constants as fsConstants } from "node:fs";
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";

const SOCKET_PATH = process.env.FASTMIX_SOCK || "/tmp/fastmix-ai.sock";
let nextId = 1;

/** Full socket command surface (from src/main.zig handleCommand). One dispatcher for GUI+MCP+socket. */
const COMMANDS = [
  { cmd: "get_project_summary", desc: "Short project summary", heavy: false },
  { cmd: "get_state", desc: "Full project DTO snapshot (alias: get_project_state)", heavy: false },
  { cmd: "get_live_state", desc: "Transport, live peaks, audio_diag", heavy: false },
  { cmd: "get_routing_state", desc: "Buses, sends, master_send flags", heavy: false },
  { cmd: "reset_audio_diag", desc: "Reset realtime fill-gap diagnostics", heavy: false },
  { cmd: "transport", desc: "Transport: args.action = play|stop|record", heavy: false },
  {
    cmd: "set_tempo",
    desc: "Set project BPM (grid/metronome/bar clock ONLY). Does NOT time-stretch or retarget audio stems. Stems keep their recorded tempo; wrong BPM = grid drift vs audio.",
    heavy: false,
  },
  { cmd: "add_track", desc: "Add audio track", heavy: false },
  { cmd: "remove_track", desc: "Remove track by id", heavy: false },
  { cmd: "set_track_param", desc: "Set track volume/pan/mute/solo/name/master_send_enabled/post_master_enabled/…", heavy: false },
  {
    cmd: "set_master_param",
    desc: "Master: volume, fx_enabled, and session DRY via fx_bypass_all (bool; not persisted). DRY bypasses all track/bus/master inserts.",
    heavy: false,
  },
  { cmd: "set_effect_param", desc: "Set effect params by effect_id (track/bus/master)", heavy: false },
  { cmd: "insert_effect", desc: "Insert effect on track|bus|master", heavy: false },
  { cmd: "add_bus", desc: "Add bus", heavy: false },
  { cmd: "remove_bus", desc: "Remove bus", heavy: false },
  { cmd: "set_bus_param", desc: "Set bus volume/pan/mute/solo/fx_enabled", heavy: false },
  { cmd: "add_send", desc: "Add send track→bus", heavy: false },
  { cmd: "remove_send", desc: "Remove send", heavy: false },
  { cmd: "set_send_param", desc: "Set send gain/tap/enabled", heavy: false },
  { cmd: "save", desc: "Save project JSON", heavy: false },
  { cmd: "load", desc: "Load project JSON (args.path)", heavy: false },
  { cmd: "undo", desc: "Undo last mutating op", heavy: false },
  { cmd: "redo", desc: "Redo", heavy: false },
  { cmd: "new_project", desc: "Reset to empty project", heavy: false },
  { cmd: "import_audio", desc: "Import audio onto a track (job). Stems arrive at native tempo — set_tempo will not stretch them.", heavy: true },
  { cmd: "render", desc: "Render master WAV (thread)", heavy: true },
  { cmd: "measure", desc: "Measure range (peak/RMS/LUFS/TP/GR); args: start_frame, length_frames, target", heavy: true },
  { cmd: "audition", desc: "Export range WAV + stats; args: start_frame, length_frames, optional path", heavy: true },
  { cmd: "get_job", desc: "Poll offline/import job by job_id", heavy: false },
  { cmd: "get_audio_config", desc: "Read realtime audio block_size (frames)", heavy: false },
  { cmd: "set_audio_config", desc: "Set realtime audio block_size (e.g. 256..4096); may recreate stream", heavy: false },
  { cmd: "sidechain_assess_and_adjust", desc: "Bounded SC compressor trial", heavy: true },
  { cmd: "eq_assess_and_adjust", desc: "Bounded EQ trial", heavy: true },
  { cmd: "compressor_assess_and_adjust", desc: "Track compressor trial", heavy: true },
  { cmd: "bus_compressor_assess_and_adjust", desc: "Bus compressor trial", heavy: true },
  { cmd: "master_compressor_assess_and_adjust", desc: "Master compressor trial", heavy: true },
  { cmd: "master_limiter_assess_and_adjust", desc: "Master sample-peak limiter trial (constraints required)", heavy: true },
  { cmd: "stereo_width_assess_and_adjust", desc: "Bounded stereo-width trial (track or master)", heavy: true },
  { cmd: "analyze_master_program", desc: "Full/window master loudness+TP analysis", heavy: true },
  { cmd: "analyze_wav_file", desc: "Offline analyze external WAV (args.path, analysis_scope)", heavy: false },
  { cmd: "compare_program_stereo", desc: "Compare two WAV programs (args.our_path, ref_path, analysis_scope)", heavy: false },
  { cmd: "validate_master_delivery", desc: "Read-only delivery QC checks", heavy: true },
  { cmd: "mix_session_preflight", desc: "Mix integrity gate; relative timing; decision passed|abstained", heavy: true },
  { cmd: "analyze_mix_sections", desc: "Read-only section Lead/instrumental/presence proxy metrics", heavy: true },
  { cmd: "lead_vocal_balance_assess", desc: "One bounded Lead-balance hypothesis; same-section before/after", heavy: true },
  { cmd: "begin_trial", desc: "Open professional trial snapshot", heavy: false },
  { cmd: "resolve_trial", desc: "Resolve trial decision", heavy: false },
  { cmd: "confirm_trial", desc: "Confirm needs_human trial (alias: commit_trial)", heavy: false },
  { cmd: "reject_trial", desc: "Reject/rollback needs_human trial (alias: rollback_trial)", heavy: false },
  { cmd: "abort_trial", desc: "Abort open trial", heavy: false },
];

/** Agent-facing workflow contract (returned by list_commands / for tool choice). */
const AGENT_FLOW = {
  stem_mix_default: [
    "fastmix_ping",
    "fastmix_get_project_summary (or load path.fastmix.json)",
    "Optional: mix_session_preflight → analyze_mix_sections before vocal-balance assess",
    "measure same window → one set_effect_param / *_assess_and_adjust → measure again",
    "audition before/after if needs_human → confirm_trial | reject_trial",
    "save",
  ],
  bpm_truth: "set_tempo changes grid/metro only. Audio stems are NOT time-stretched. Matching stem tempo requires offline atempo/new files + import_audio (not a single MCP call).",
  align_truth: "ALIGN (onset snap) is GUI-only today — no socket/MCP command.",
  dry_ab: "Session DRY: set_master_param {fx_bypass_all:true|false}. Not persisted.",
  missing_vs_gui: ["ALIGN button", "bootstrap folder (CLI FASTMIX_BOOTSTRAP / --load only)"],
};
/** Stable high-level names preferred by agents (map → socket cmd). */
const ALIASES = [
  { name: "fastmix_get_project_state", cmd: "get_state", desc: "High-level: full project state (→ get_state)", heavy: false },
  { name: "fastmix_commit_trial", cmd: "confirm_trial", desc: "High-level: commit needs_human trial (→ confirm_trial)", heavy: false },
  { name: "fastmix_rollback_trial", cmd: "reject_trial", desc: "High-level: rollback needs_human trial (→ reject_trial)", heavy: false },
];

const ARGS_SCHEMA = {
  type: "object",
  description: "Socket command args (same JSON as the app API / dispatcher)",
  additionalProperties: true,
};

function toolNameFor(cmd) {
  return `fastmix_${cmd}`;
}

function request(cmd, args = {}, timeoutMs = 120_000) {
  const id = nextId++;
  const payload = JSON.stringify({ id, cmd, args }) + "\n";
  return new Promise((resolve, reject) => {
    const sock = createConnection(SOCKET_PATH);
    let buf = "";
    const timer = setTimeout(() => {
      sock.destroy();
      reject(new Error(`timeout after ${timeoutMs}ms waiting for ${cmd}`));
    }, timeoutMs);

    sock.setEncoding("utf8");
    sock.on("connect", () => sock.write(payload));
    sock.on("data", (chunk) => {
      buf += chunk;
      const nl = buf.indexOf("\n");
      if (nl === -1) return;
      clearTimeout(timer);
      const line = buf.slice(0, nl);
      sock.end();
      try {
        resolve(JSON.parse(line));
      } catch (e) {
        reject(new Error(`bad JSON from FastMix AI: ${e.message}; line=${line.slice(0, 200)}`));
      }
    });
    sock.on("error", (err) => {
      clearTimeout(timer);
      reject(err);
    });
  });
}

async function waitJob(jobId, timeoutMs) {
  const t0 = Date.now();
  while (Date.now() - t0 < timeoutMs) {
    const r = await request("get_job", { job_id: jobId }, Math.min(30_000, timeoutMs));
    const st = r?.result?.status;
    if (st === "succeeded") return r;
    if (st === "failed" || (r?.ok === false && st !== "running")) return r;
    await new Promise((r) => setTimeout(r, 50));
  }
  throw new Error(`get_job timeout job_id=${jobId}`);
}

async function cmdWithJobPoll(cmd, args, waitJobFlag, timeoutMs) {
  const first = await request(cmd, args, timeoutMs);
  const jobId = first?.result?.job_id;
  const st = first?.result?.status;
  if (waitJobFlag && jobId != null && (st === "running" || st === "queued")) {
    const done = await waitJob(jobId, timeoutMs);
    const payload = done?.result?.payload;
    if (payload && typeof payload === "object") {
      return {
        ok: done.ok !== false,
        revision: done.revision,
        result: payload,
        job: done.result,
      };
    }
    return done;
  }
  return first;
}

function textResult(obj, isError = false) {
  return {
    content: [{ type: "text", text: JSON.stringify(obj, null, 2) }],
    isError,
  };
}

function buildTools() {
  const tools = [
    {
      name: "fastmix_ping",
      description:
        "Health: socket reachable + get_live_state. Prefer before heavy mix/master work.",
      inputSchema: { type: "object", properties: {}, additionalProperties: false },
    },
    {
      name: "fastmix_cmd",
      description:
        "Escape hatch: any socket cmd by name. Prefer high-level fastmix_* tools. Still hits the same dispatcher.",
      inputSchema: {
        type: "object",
        properties: {
          cmd: { type: "string" },
          args: ARGS_SCHEMA,
          wait_job: { type: "boolean", description: "Poll offline jobs (default true)" },
          timeout_ms: { type: "number" },
        },
        required: ["cmd"],
        additionalProperties: false,
      },
    },
    {
      name: "fastmix_list_commands",
      description:
        "List MCP↔socket commands + AGENT_FLOW (BPM truth, DRY, mix loop). Call once when starting a mix session.",
      inputSchema: { type: "object", properties: {}, additionalProperties: false },
    },
  ];

  for (const c of COMMANDS) {
    tools.push({
      name: toolNameFor(c.cmd),
      description: `${c.desc} [socket cmd=${c.cmd}${c.heavy ? "; may run offline while play" : ""}]`,
      inputSchema: {
        type: "object",
        properties: {
          args: ARGS_SCHEMA,
          wait_job: {
            type: "boolean",
            description: "Poll get_job when offline worker returns running (default true for heavy cmds)",
          },
          timeout_ms: { type: "number", description: "Timeout ms (default 180000 heavy / 60000 light)" },
        },
        additionalProperties: false,
      },
    });
  }
  for (const a of ALIASES) {
    tools.push({
      name: a.name,
      description: `${a.desc} [socket cmd=${a.cmd}]`,
      inputSchema: {
        type: "object",
        properties: {
          args: ARGS_SCHEMA,
          wait_job: { type: "boolean" },
          timeout_ms: { type: "number" },
        },
        additionalProperties: false,
      },
    });
  }
  return tools;
}

async function ensureSocket() {
  await access(SOCKET_PATH, fsConstants.R_OK | fsConstants.W_OK);
}

const server = new Server(
  { name: "fastmix-ai", version: "0.3.0" },
  { capabilities: { tools: {} } },
);

const TOOLS = buildTools();

server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: TOOLS }));

server.setRequestHandler(CallToolRequestSchema, async (req) => {
  const name = req.params.name;
  const a = req.params.arguments ?? {};
  try {
    if (name === "fastmix_list_commands") {
      return textResult({
        socket: SOCKET_PATH,
        architecture: "LLM → MCP → Unix socket → handleCommand dispatcher → engine",
        agent_path: "MCP only (Python is developer/regression only)",
        agent_flow: AGENT_FLOW,
        count: COMMANDS.length,
        aliases: ALIASES,
        commands: COMMANDS.map((c) => ({
          tool: toolNameFor(c.cmd),
          cmd: c.cmd,
          heavy: c.heavy,
          desc: c.desc,
        })),
      });
    }

    if (name === "fastmix_ping") {
      try {
        await ensureSocket();
      } catch {
        return textResult(
          {
            ok: false,
            error: "socket_missing",
            socket: SOCKET_PATH,
            hint: "Start ./zig-out/bin/fastmix-ai --load …",
          },
          true,
        );
      }
      const live = await request("get_live_state", {}, 10_000);
      return textResult({ ok: true, socket: SOCKET_PATH, tool_count: TOOLS.length, live });
    }

    let cmd;
    let cmdArgs = {};
    let waitJobFlag;
    let timeoutMs;

    if (name === "fastmix_cmd") {
      cmd = a.cmd;
      if (typeof cmd !== "string" || !cmd) return textResult({ ok: false, error: "missing_cmd" }, true);
      cmdArgs = a.args && typeof a.args === "object" ? a.args : {};
      waitJobFlag = a.wait_job !== false;
      timeoutMs = Number(a.timeout_ms) > 0 ? Number(a.timeout_ms) : 180_000;
    } else if (name.startsWith("fastmix_")) {
      const alias = ALIASES.find((x) => x.name === name);
      if (alias) {
        cmd = alias.cmd;
      } else {
        cmd = name.slice("fastmix_".length);
      }
      const meta = COMMANDS.find((c) => c.cmd === cmd);
      if (!meta) return textResult({ ok: false, error: `unknown_tool:${name}` }, true);
      cmdArgs = a.args && typeof a.args === "object" ? a.args : {};
      // If caller put fields at top-level (not nested in args), merge them — nicer UX.
      for (const [k, v] of Object.entries(a)) {
        if (k === "args" || k === "wait_job" || k === "timeout_ms") continue;
        if (cmdArgs[k] === undefined) cmdArgs[k] = v;
      }
      waitJobFlag = a.wait_job !== undefined ? !!a.wait_job : meta.heavy;
      timeoutMs = Number(a.timeout_ms) > 0 ? Number(a.timeout_ms) : meta.heavy ? 180_000 : 60_000;
    } else {
      return textResult({ ok: false, error: `unknown_tool:${name}` }, true);
    }

    try {
      await ensureSocket();
    } catch {
      return textResult({ ok: false, error: "socket_missing", socket: SOCKET_PATH }, true);
    }

    const out = await cmdWithJobPoll(cmd, cmdArgs, waitJobFlag, timeoutMs);
    return textResult(out, out?.ok === false);
  } catch (e) {
    return textResult(
      {
        ok: false,
        error: e instanceof Error ? e.message : String(e),
        socket: SOCKET_PATH,
      },
      true,
    );
  }
});

const transport = new StdioServerTransport();
await server.connect(transport);
