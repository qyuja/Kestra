import { mkdir, writeFile, rename } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";

// Pi auto-discovers this extension. It never changes prompts, tools or permissions.
export default function islandbar(pi) {
  const folder = join(homedir(), "Library/Application Support/com.kiannest.islandbar/pi-events");
  let queue = Promise.resolve();
  let sequence = 0;
  let active = false;
  let outcome = "Stop";
  const record = (ctx, kind, fields = {}) => {
    const session = ctx.sessionManager.getSessionId();
    if (!session) return Promise.resolve();
    const event = { session_id: session, hook_event_name: kind, cwd: ctx.cwd,
      model: ctx.model?.id, effort: ctx.thinkingLevel, ...fields };
    queue = queue.then(async () => {
      await mkdir(folder, { recursive: true, mode: 0o700 });
      const name = Date.now() + "-" + String(sequence++).padStart(8, "0") + "-" + randomUUID();
      const temp = join(folder, name + ".tmp");
      await writeFile(temp, JSON.stringify(event), { mode: 0o600 });
      await rename(temp, join(folder, name + ".json"));
    }).catch(() => { console.error("IslandBar: could not record Pi task event"); });
    return queue;
  };
  pi.on("before_agent_start", async (event, ctx) => {
    if (pi.getActiveTools().length === 0) return;
    active = true;
    outcome = "Stop";
    await record(ctx, "UserPromptSubmit", { prompt: event.prompt });
  });
  pi.on("agent_start", async (_event, ctx) => {
    if (pi.getActiveTools().length === 0) return;
    active = true;
    outcome = "Stop";
    await record(ctx, "PreToolUse");
  });
  pi.on("message_end", async (event) => {
    if (!active || event.message.role !== "assistant") return;
    const reason = event.message.stopReason;
    outcome = reason === "error" ? "StopFailure" : reason === "aborted" ? "StopCancelled" : "Stop";
  });
  // agent_end can be followed by automatic retries or queued work. Do not finish there.
  pi.on("agent_settled", async (_event, ctx) => {
    if (!active || !ctx.isIdle()) return;
    active = false;
    await record(ctx, outcome);
  });
  for (const name of ["model_select", "thinking_level_select"]) {
    pi.on(name, async (_event, ctx) => { if (active) await record(ctx, "ModelUpdate"); });
  }
  pi.on("session_shutdown", async (_event, ctx) => {
    if (active) await record(ctx, "SessionEnd");
    active = false;
    await queue;
  });
}
