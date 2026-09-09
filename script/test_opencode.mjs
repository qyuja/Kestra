import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";

// Keep fixtures entirely in memory, never emit events into the user's task list.
const source = await readFile(new URL("../Sources/IslandBarDemo/Resources/islandbar-opencode.js", import.meta.url), "utf8");
const pending = new Map();
const events = [];
const factory = new Function("mkdir", "writeFile", "rename", "homedir", "join", "randomUUID",
  source.replace(/^import .*;$/gm, "").replace("export const IslandBarPlugin", "const IslandBarPlugin") + "\nreturn IslandBarPlugin;");
const plugin = await factory(
  async () => {},
  async (path, body) => pending.set(path, body),
  async (from) => { events.push(JSON.parse(pending.get(from))); pending.delete(from); },
  () => "/test", join, () => "fixture"
)({ directory: "/test/project" });

await plugin["chat.message"]({ sessionID: "one" }, {
  message: { model: { modelID: "model-a" } },
  parts: [{ type: "text", text: "real user" }, { type: "text", text: "injected", synthetic: true }],
});
await plugin["chat.params"]({ sessionID: "one", model: { id: "model-b" } });
await plugin.event({ event: { type: "session.status", properties: { sessionID: "one", status: { type: "busy" } } } });
await plugin.event({ event: { type: "session.idle", properties: { sessionID: "one" } } });
await plugin.event({ event: { type: "session.error", properties: { sessionID: "two" } } });
assert.deepEqual(events.map(e => e.hook_event_name), ["UserPromptSubmit", "ModelUpdate", "PreToolUse", "Stop", "StopFailure"]);
assert.equal(events[0].prompt, "real user");
assert.equal(events[0].model, "model-a");
assert.equal(events[3].model, "model-b");
assert.equal(events[4].session_id, "two");
console.log("OpenCode adapter: event mapping, user-only preview, model switching passed");
