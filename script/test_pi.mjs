import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";

// Only in-memory fixtures: no events or prompts written into the real user profile.
const source = await readFile(new URL("../Sources/IslandBarDemo/Resources/islandbar-pi.js", import.meta.url), "utf8");
const pending = new Map();
const events = [];
const handlers = new Map();
let tools = ["read", "bash"];
const factory = new Function("mkdir", "writeFile", "rename", "homedir", "join", "randomUUID",
  source.replace(/^import .*;$/gm, "").replace("export default function", "function") + "\nreturn islandbar;");
factory(async () => {}, async (path, data) => pending.set(path, data),
  async (path) => { events.push(JSON.parse(pending.get(path))); pending.delete(path); },
  () => "/test", join, () => "fixture")({
  on: (name, handler) => handlers.set(name, handler), getActiveTools: () => tools,
});
const ctx = { sessionManager: { getSessionId: () => "session-one" }, cwd: "/project",
  model: { id: "model-a" }, thinkingLevel: "high", isIdle: () => true };
const emit = async (name, event = {}) => { assert.equal(await handlers.get(name)?.(event, ctx), undefined); };
await emit("before_agent_start", { prompt: "real user", systemPrompt: "must not persist" });
await emit("agent_start");
assert.equal(handlers.has("agent_end"), false);
await emit("message_end", { message: { role: "assistant", stopReason: "error", content: "private response" } });
await emit("agent_start"); // Retry: must remain running, then finish only on settled.
await emit("message_end", { message: { role: "assistant", stopReason: "stop" } });
await emit("agent_settled");
assert.deepEqual(events.map(e => e.hook_event_name), ["UserPromptSubmit", "PreToolUse", "PreToolUse", "Stop"]);
assert.equal(events[0].prompt, "real user");
assert.equal(events[0].effort, "high");
assert.equal(events.some(e => "systemPrompt" in e || "content" in e), false);
await emit("agent_settled");
assert.equal(events.length, 4);
await emit("agent_start");
await emit("message_end", { message: { role: "assistant", stopReason: "aborted" } });
await emit("agent_settled");
assert.equal(events.at(-1).hook_event_name, "StopCancelled");
await emit("agent_start");
await emit("session_shutdown");
assert.equal(events.at(-1).hook_event_name, "SessionEnd");
const count = events.length;
tools = [];
await emit("before_agent_start", { prompt: "plain chat" });
await emit("agent_start");
await emit("agent_settled");
assert.equal(events.length, count);
console.log("Pi adapter: retry/settled, cancellation, shutdown, metadata and tool-less chat filtering passed");
