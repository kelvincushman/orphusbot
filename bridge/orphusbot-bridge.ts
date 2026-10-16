// orphusbot-bridge: an Orphus extension that asks OrphusBot before every tool call.
//
// It holds no policy. Each call becomes an `input` dialog titled
// "orphusbot-gate", which the node relays to the server. The server answers
// "allow", or "deny:<reason>" from its rules, its effect ledger, or the owner
// (DESIGN §5, §7.4). Anything else, including no answer, blocks the call.
//
// The node embeds this file and loads it with `orphus -e`; it is only valid
// in RPC mode under orphusbot-node, so in any other mode it blocks everything.

import type { ExtensionAPI } from "@orphus/coding-agent";

export const GATE_TITLE = "orphusbot-gate";

export default function (pi: ExtensionAPI) {
  pi.on("tool_call", async (event, ctx) => {
    if (ctx.mode !== "rpc") {
      return { block: true, reason: "orphusbot-bridge only runs under orphusbot-node." };
    }
    const request = JSON.stringify({
      toolCallId: event.toolCallId,
      tool: event.toolName,
      input: event.input,
    });
    const answer = await ctx.ui.input(GATE_TITLE, request);
    if (answer === "allow") return;
    const reason = typeof answer === "string" && answer.startsWith("deny:")
      ? answer.slice("deny:".length)
      : "OrphusBot did not approve this tool call.";
    return { block: true, reason };
  });
}
