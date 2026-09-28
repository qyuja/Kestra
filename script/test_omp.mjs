import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";

// Keep fixtures entirely in memory, never emit events into the user's task list.
const source = await readFile(new URL("../Sources/Kestra/Resources/kestra-omp.js", import.meta.url), "utf8");
const pending = new Map();
const events = [];
const handlers = new Map();
const factory = new Function("mkdir", "writeFile", "rename", "homedir", "join", "randomUUID",
  source.replace(/^import .*;$/gm, "").replace("export default function", "function") + "\nreturn kestra;");
factory(async () => {}, async (path, data) => pending.set(path, data),
  async (path) => { events.push(JSON.parse(pending.get(path))); pending.delete(path); },
  () => "/test", join, () => "fixture")({
  on: (name, handler) => handlers.set(name, handler),
  getThinkingLevel: () => "high",
});

const ctx = {
  sessionManager: { getSessionId: () => "session-one" },
  cwd: "/project",
  model: { id: "model-a" },
};
const emit = async (name, event = {}, context = ctx) => {
  assert.equal(await handlers.get(name)?.(event, context), undefined);
};

await emit("before_agent_start", { prompt: "real user", systemPrompt: ["private system prompt"] });
assert.equal(events.length, 0, "starting an agent without a tool call is ordinary chat");
const promptCountBeforeContinuation = events.filter(e => e.hook_event_name === "UserPromptSubmit").length;
await emit("tool_call");
await emit("session_stop", { stop_hook_active: false });
await emit("agent_end", { willContinue: true, messages: [{ role: "assistant", stopReason: "error", content: "private response" }] });
assert.equal(events.at(-1).hook_event_name, "PreToolUse", "session_stop is a continuation decision, not a terminal event");
await emit("before_agent_start", { prompt: "hidden stop-hook continuation" });
await emit("tool_call");
await emit("agent_end", { willContinue: true, messages: [{ role: "assistant", stopReason: "error" }] });
await emit("before_agent_start", { prompt: "hidden automatic retry continuation" });
await emit("tool_call");
await emit("session_stop", { stop_hook_active: true });
await emit("agent_end", { willContinue: false, messages: [{ role: "assistant", stopReason: "stop", content: "private response" }] });

assert.deepEqual(events.map(e => e.hook_event_name), ["UserPromptSubmit", "PreToolUse", "PreToolUse", "PreToolUse", "Stop"]);
assert.deepEqual(
  events.filter(e => e.hook_event_name === "UserPromptSubmit").slice(promptCountBeforeContinuation).map(e => e.prompt),
  ["real user"],
  "prompts for every automatic continuation must stay out of the user preview",
);
assert.equal(events[0].prompt, "real user");
assert.equal(events[0].model, "model-a");
assert.equal(events[0].effort, "high");
assert.equal(events.some(e => "systemPrompt" in e || "content" in e), false);

await emit("before_agent_start", { prompt: "cancelled user" });
await emit("tool_call");
await emit("agent_end", { willContinue: false, messages: [{ role: "assistant", stopReason: "aborted" }] });
assert.equal(events.at(-1).hook_event_name, "StopCancelled");

await emit("before_agent_start", { prompt: "failed user" });
await emit("tool_call");
await emit("session_stop", { stop_hook_active: false });
await emit("agent_end", {
  willContinue: false,
  messages: [
    { role: "assistant", stopReason: "error" },
    { role: "toolResult", content: "private tool output" },
  ],
});
assert.equal(events.at(-1).hook_event_name, "StopFailure");

for (const reason of ["length", "toolUse", "unknown", undefined]) {
  await emit("before_agent_start", { prompt: `terminal ${reason ?? "missing"}` });
  await emit("tool_call");
  await emit("session_stop", { stop_hook_active: false });
  await emit("agent_end", {
    willContinue: false,
    messages: [
      { role: "assistant", ...(reason ? { stopReason: reason } : {}) },
      { role: "toolResult", content: "private tool output" },
    ],
  });
  assert.equal(events.at(-1).hook_event_name, "Stop", `non-error terminal reason ${reason ?? "missing"} is not a failure`);
}

await emit("before_agent_start", { prompt: "completed without a continuation" });
await emit("tool_call");
await emit("session_stop", { stop_hook_active: false });
await emit("agent_end", { willContinue: false, messages: [{ role: "assistant", stopReason: "stop" }] });
await emit("before_agent_start", { prompt: "next real user turn" });
await emit("tool_call");
assert.equal(events.filter(e => e.hook_event_name === "UserPromptSubmit").at(-1)?.prompt, "next real user turn");

await emit("session_shutdown");
const count = events.length;
await emit("before_agent_start", { prompt: "plain chat" });
await emit("session_stop", { session_id: "session-one" });
assert.equal(events.length, count);

const firstLateSessionID = { value: undefined };
const secondLateSessionID = { value: undefined };
const firstLateContext = {
  ...ctx,
  sessionManager: { getSessionId: () => firstLateSessionID.value },
};
const secondLateContext = {
  ...ctx,
  sessionManager: { getSessionId: () => secondLateSessionID.value },
};
await emit("before_agent_start", { prompt: "first pending prompt" }, firstLateContext);
await emit("before_agent_start", { prompt: "second pending prompt" }, secondLateContext);
firstLateSessionID.value = "late-session-one";
secondLateSessionID.value = "late-session-two";
await emit("tool_call", {}, firstLateContext);
await emit("tool_call", {}, secondLateContext);
assert.deepEqual(
  events.filter(e => e.hook_event_name === "UserPromptSubmit").slice(-2).map(e => [e.session_id, e.prompt]),
  [
    ["late-session-one", "first pending prompt"],
    ["late-session-two", "second pending prompt"],
  ],
);

const delayedSessionID = { value: undefined };
const delayedContext = {
  ...ctx,
  sessionManager: { getSessionId: () => delayedSessionID.value },
};
const eventCountBeforeDelayedID = events.length;
await emit("before_agent_start", { prompt: "single tool before session ID" }, delayedContext);
await emit("tool_call", {}, delayedContext);
assert.equal(events.length, eventCountBeforeDelayedID, "events without a session ID wait in memory");
delayedSessionID.value = "session-assigned-after-tool";
await emit("agent_end", { willContinue: false, messages: [{ role: "assistant", stopReason: "stop" }] }, delayedContext);
assert.deepEqual(
  events.slice(-3).map(event => [event.session_id, event.hook_event_name, event.prompt]),
  [
    ["session-assigned-after-tool", "UserPromptSubmit", "single tool before session ID"],
    ["session-assigned-after-tool", "PreToolUse", undefined],
    ["session-assigned-after-tool", "Stop", undefined],
  ],
  "late identity must flush the full task lifecycle in order",
);

const switchedSessionID = { value: "session-before-switch" };
const switchedContext = {
  ...ctx,
  sessionManager: { getSessionId: () => switchedSessionID.value },
};
await emit("before_agent_start", { prompt: "task before session switch" }, switchedContext);
await emit("tool_call", {}, switchedContext);
await emit("session_before_switch", { reason: "resume" }, switchedContext);
switchedSessionID.value = "session-after-switch";
await emit("session_switch", { reason: "resume", previousSessionFile: "/project/old.jsonl" }, switchedContext);
assert.deepEqual(
  [events.at(-1).session_id, events.at(-1).hook_event_name],
  ["session-before-switch", "SessionEnd"],
  "switching sessions must terminate the old task under its original ID",
);

await emit("before_agent_start", { prompt: "task before branch" }, switchedContext);
await emit("tool_call", {}, switchedContext);
await emit("session_before_branch", {}, switchedContext);
switchedSessionID.value = "session-after-branch";
await emit("session_branch", { previousSessionFile: "/project/source.jsonl" }, switchedContext);
assert.deepEqual(
  [events.at(-1).session_id, events.at(-1).hook_event_name],
  ["session-after-switch", "SessionEnd"],
  "branching must terminate the source task under its original ID",
);

console.log("oh-my-pi adapter: OMP lifecycle, retries, cancellation, metadata and privacy passed");
