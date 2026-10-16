// orphusbot-bridge: an Orphus extension that asks OrphusBot before every tool call,
// and runs the tools in the bot's computer.
//
// Gate: it holds no policy. Each call becomes an `input` dialog titled
// "orphusbot-gate", which the node relays to the server. The server answers
// "allow", or "deny:<reason>" from its rules, its effect ledger, or the owner
// (DESIGN §5, §7.4). Anything else, including no answer, blocks the call.
//
// Computer: when the node gives it a computer (ORPHUSBOT_COMPUTER), read,
// write, edit and bash run inside that container through `podman exec`, the
// same way Orphus's ssh.ts example runs them over ssh, and every other tool is
// switched off, so nothing runs on the host. The engine and its logins stay on
// the host (DESIGN §4.4, DECISIONS D-020). If the container can't be reached,
// the tool fails; it never falls back to the host.
//
// E2B: when the node sets ORPHUSBOT_E2B_URL instead, the computer is an E2B
// sandbox and the same operations go to its envd over HTTPS (files through
// `/files`, commands through the Connect protocol's `process.Process/Start`),
// with that sandbox's access token. The engine still runs on the node (DESIGN §6.2).
//
// The node embeds this file and loads it with `orphus -e`; it is only valid
// in RPC mode under orphusbot-node, so in any other mode it blocks everything.

import { spawn } from "node:child_process";
import { readFile } from "node:fs/promises";
import { basename, resolve } from "node:path";
import { Type } from "typebox";
import type { ExtensionAPI } from "@orphus/coding-agent";
import {
  type BashOperations,
  createBashTool,
  createEditTool,
  createReadTool,
  createWriteTool,
  type ReadOperations,
  type WriteOperations,
} from "@orphus/coding-agent";

export const GATE_TITLE = "orphusbot-gate";
/** Title of the dialog that asks the owner to take over the screen (DESIGN §4.4). */
export const TAKEOVER_TITLE = "orphusbot-takeover";

const computer = process.env.ORPHUSBOT_COMPUTER;
const runtime = process.env.ORPHUSBOT_RUNTIME ?? "podman";
const home = process.env.ORPHUSBOT_COMPUTER_HOME ?? "/home/bot";
/** In a computer, only these run: each one is redirected into it. */
// Plus `mcp`, Orphus's MCP gateway, when the owner granted the bot a connection:
// it only talks to those servers, so it is safe to run outside the computer.
const COMPUTER_TOOLS = ["read", "write", "edit", "bash", "request_takeover", "share_file", ...(process.env.ORPHUSBOT_MCP ? ["mcp"] : [])];
const IMAGES: Record<string, string> = {
  png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", gif: "image/gif", webp: "image/webp",
};

const e2bUrl = process.env.ORPHUSBOT_E2B_URL;
const e2bHeaders: Record<string, string> = {
  // envd runs commands and file access as this user.
  Authorization: `Basic ${Buffer.from("user:").toString("base64")}`,
  ...(process.env.ORPHUSBOT_E2B_TOKEN ? { "X-Access-Token": process.env.ORPHUSBOT_E2B_TOKEN } : {}),
};

/**
 * Runs `bash -l -c script bash args…` in the E2B sandbox through envd's
 * server-streaming `process.Process/Start`, in the Connect protocol's JSON form:
 * each message is a 5-byte header (flags, big-endian length) and JSON; flag 2
 * marks the closing message, which carries any error.
 */
async function e2bRun(
  script: string,
  args: string[],
  opts: { cwd?: string; onData?: (b: Buffer) => void; signal?: AbortSignal } = {},
): Promise<{ exitCode: number; stdout: Buffer; stderr: Buffer }> {
  const request = Buffer.from(JSON.stringify({
    process: { cmd: "/bin/bash", args: ["-l", "-c", script, "bash", ...args], envs: {}, ...(opts.cwd ? { cwd: opts.cwd } : {}) },
    stdin: false,
  }));
  const frame = Buffer.alloc(5 + request.length);
  frame.writeUInt32BE(request.length, 1);
  request.copy(frame, 5);
  const res = await fetch(`${e2bUrl}/process.Process/Start`, {
    method: "POST",
    headers: { "Content-Type": "application/connect+json", "Connect-Protocol-Version": "1", ...e2bHeaders },
    body: frame,
    signal: opts.signal,
  });
  if (!res.ok || !res.body) throw new Error(`E2B sandbox answered ${res.status}: ${await res.text()}`);
  const out: Buffer[] = [];
  const err: Buffer[] = [];
  let exitCode = -1;
  let pending = Buffer.alloc(0);
  for await (const chunk of res.body as AsyncIterable<Uint8Array>) {
    pending = Buffer.concat([pending, chunk]);
    while (pending.length >= 5 && pending.length >= 5 + pending.readUInt32BE(1)) {
      const flags = pending.readUInt8(0);
      const length = pending.readUInt32BE(1);
      const message = JSON.parse(pending.subarray(5, 5 + length).toString() || "{}");
      pending = pending.subarray(5 + length);
      if (flags & 2) {
        if (message.error) throw new Error(`E2B sandbox: ${message.error.message ?? message.error.code}`);
        continue;
      }
      const event = message.event ?? {};
      for (const [key, into] of [["stdout", out], ["stderr", err]] as const) {
        if (event.data?.[key]) {
          const bytes = Buffer.from(event.data[key], "base64");
          into.push(bytes);
          opts.onData?.(bytes);
        }
      }
      // Protobuf JSON leaves out a zero exit code.
      if (event.end) exitCode = event.end.exitCode ?? 0;
    }
  }
  return { exitCode, stdout: Buffer.concat(out), stderr: Buffer.concat(err) };
}

/** envd's file API: read, or write (making parent folders). */
async function e2bFile(path: string, content?: Buffer): Promise<Buffer> {
  const url = `${e2bUrl}/files?path=${encodeURIComponent(path)}&username=user`;
  const res = await fetch(url, content
    ? { method: "POST", headers: { ...e2bHeaders, "Content-Type": "application/octet-stream" }, body: content }
    : { headers: e2bHeaders });
  if (!res.ok) throw new Error(`${path}: ${(await res.text()).trim() || res.status}`);
  return Buffer.from(await res.arrayBuffer());
}

/** Runs a bash script in the computer. `args` become $1, $2…, so paths need no quoting. */
async function inComputer(script: string, args: string[] = [], input?: Buffer): Promise<Buffer> {
  if (e2bUrl) {
    if (input) throw new Error("input isn't supported in E2B; write files with e2bFile");
    const r = await e2bRun(script, args);
    if (r.exitCode !== 0) throw new Error(r.stderr.toString().trim() || `exit ${r.exitCode}`);
    return r.stdout;
  }
  return new Promise((resolve, reject) => {
    const child = spawn(runtime, ["exec", "-i", "-w", home, computer!, "bash", "-c", script, "bash", ...args], {
      stdio: ["pipe", "pipe", "pipe"],
    });
    const out: Buffer[] = [];
    const err: Buffer[] = [];
    child.stdout.on("data", (d) => out.push(d));
    child.stderr.on("data", (d) => err.push(d));
    child.on("error", reject);
    child.on("close", (code) =>
      code === 0 ? resolve(Buffer.concat(out)) : reject(new Error(Buffer.concat(err).toString().trim() || `exit ${code}`)),
    );
    child.stdin.end(input);
  });
}

export default function (pi: ExtensionAPI) {
  pi.on("tool_call", async (event, ctx) => {
    if (ctx.mode !== "rpc") {
      return { block: true, reason: "orphusbot-bridge only runs under orphusbot-node." };
    }
    // Anything else (an MCP tool, another extension's tool) would run on the host.
    if (computer && !COMPUTER_TOOLS.includes(event.toolName)) {
      return { block: true, reason: `${event.toolName} isn't available in this bot's computer; use bash.` };
    }
    const request = JSON.stringify({
      toolCallId: event.toolCallId,
      tool: event.toolName,
      input: event.input,
      // Lets the server tell a file edit inside the computer (reversible) from one on the host.
      inComputer: !!computer,
    });
    const answer = await ctx.ui.input(GATE_TITLE, request);
    if (answer === "allow") return;
    const reason = typeof answer === "string" && answer.startsWith("deny:")
      ? answer.slice("deny:".length)
      : "OrphusBot did not approve this tool call.";
    return { block: true, reason };
  });

  // The engine's working folder on the host stands for the computer's home.
  const cwd = process.cwd();
  const inside = (p: string) => (p === cwd || p.startsWith(cwd + "/") ? home + p.slice(cwd.length) : p);

  // An artifact (DESIGN §11.1): the file travels in `details`, which the node
  // forwards to the server and the model never sees.
  const MAX_SHARE = 10 * 1024 * 1024;
  pi.registerTool({
    name: "share_file",
    label: "Share a file with the owner",
    description:
      "Give the owner a copy of a file you made, such as a report, a spreadsheet or an image. It appears in the chat with a download link; sharing the same name again adds a new version. Up to 10 MB.",
    promptSnippet: "Give the owner a file you made",
    parameters: Type.Object({
      path: Type.String({ description: "The file's path" }),
    }),
    async execute(_id, params) {
      const path = resolve(cwd, params.path);
      const data = computer
        ? await inComputer('head -c 10485761 -- "$1"', [inside(path)])
        : await readFile(path);
      if (data.length > MAX_SHARE) throw new Error("That file is over 10 MB; share a smaller one.");
      const name = basename(path);
      return {
        content: [{ type: "text", text: `Shared ${name} with the owner.` }],
        details: { artifact: { name, data: data.toString("base64") } },
      };
    },
  });

  if (!computer) return; // ORPHUSBOT_RUNTIME=none: tools run on the host, still gated.

  const read: ReadOperations = {
    readFile: (p) => (e2bUrl ? e2bFile(inside(p)) : inComputer('cat -- "$1"', [inside(p)])),
    access: (p) => inComputer('test -r "$1"', [inside(p)]).then(() => {}),
    detectImageMimeType: async (p) => IMAGES[p.split(".").pop()?.toLowerCase() ?? ""] ?? null,
  };
  const write: WriteOperations = {
    writeFile: (p, content) =>
      (e2bUrl ? e2bFile(inside(p), Buffer.from(content)) : inComputer('cat > "$1"', [inside(p)], Buffer.from(content))).then(() => {}),
    mkdir: (dir) => inComputer('mkdir -p -- "$1"', [inside(dir)]).then(() => {}),
  };
  const bash: BashOperations = {
    exec: (command, dir, { onData, signal, timeout }) =>
      e2bUrl
        ? e2bRun(timeout ? `timeout -s KILL ${Number(timeout)} bash -c "$1"` : 'bash -c "$1"', [command], { cwd: inside(dir), onData, signal })
            .then((r) => {
              if (timeout && r.exitCode === 137) throw new Error(`timeout:${timeout}`);
              return { exitCode: r.exitCode };
            })
            .catch((e) => {
              // ponytail: as with podman, an aborted command runs on in the sandbox until it ends.
              throw signal?.aborted ? new Error("aborted") : e;
            })
        : new Promise((resolve, reject) => {
        // ponytail: stopping the podman client doesn't stop the command inside; the in-container
        // `timeout` covers time limits, and an aborted command runs on until it ends.
        const limited = timeout ? ["timeout", "-s", "KILL", String(timeout), "bash", "-c", command] : ["bash", "-c", command];
        const child = spawn(runtime, ["exec", "-w", inside(dir), computer, ...limited], { stdio: ["ignore", "pipe", "pipe"] });
        child.stdout.on("data", onData);
        child.stderr.on("data", onData);
        child.on("error", reject);
        const onAbort = () => child.kill();
        signal?.addEventListener("abort", onAbort, { once: true });
        child.on("close", (code) => {
          signal?.removeEventListener("abort", onAbort);
          if (signal?.aborted) reject(new Error("aborted"));
          else if (timeout && code === 137) reject(new Error(`timeout:${timeout}`));
          else resolve({ exitCode: code });
        });
      }),
  };

  pi.registerTool(createReadTool(cwd, { operations: read }));
  pi.registerTool(createWriteTool(cwd, { operations: write }));
  pi.registerTool(createEditTool(cwd, { operations: { readFile: read.readFile, access: read.access, writeFile: write.writeFile } }));
  pi.registerTool(createBashTool(cwd, { operations: bash }));
  // Runs here, not in the computer, but only asks the owner a question.
  pi.registerTool({
    name: "request_takeover",
    label: "Ask the owner to take over",
    description:
      "Ask the owner to use your computer's screen themselves, for example to log in, solve a captcha or approve a payment page. Waits until they say they're done or can't help.",
    promptSnippet: "Ask the owner to do something on your screen, such as log in",
    promptGuidelines: [
      "Your computer has a screen (DISPLAY=:1). Open a web page on it with bash: `setsid chromium --no-sandbox --disable-dev-shm-usage <url> >/dev/null 2>&1 &`.",
      "Use request_takeover when a page needs the owner (a login, a captcha, a payment); leave the page open on the screen first, then carry on when it returns.",
    ],
    parameters: Type.Object({
      reason: Type.String({ description: "What the owner should do, in one short sentence" }),
    }),
    async execute(_id, params, _signal, _onUpdate, ctx) {
      const hasScreen = await inComputer("command -v Xvnc").then(() => true, () => false);
      if (!hasScreen) {
        return { content: [{ type: "text", text: "This computer has no screen, so the owner can't take over." }], details: {} };
      }
      const done = await ctx.ui.confirm(TAKEOVER_TITLE, params.reason);
      const text = done
        ? "The owner says they're done. Check the screen, then carry on."
        : "The owner couldn't do it. Find another way, or say what is blocking you.";
      return { content: [{ type: "text", text }], details: {} };
    },
  });
  // Offer only the redirected tools (find, grep and ls are done with bash, in the computer).
  // Set before every agent start, since other tools can register after the session starts.
  const onlyComputerTools = async () => pi.setActiveTools(COMPUTER_TOOLS);
  pi.on("session_start", onlyComputerTools);
  pi.on("before_agent_start", onlyComputerTools);
}
