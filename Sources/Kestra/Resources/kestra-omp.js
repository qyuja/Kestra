import { mkdir, writeFile, rename } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";

// oh-my-pi (omp) is a Pi-compatible harness with a different lifecycle:
// it settles through session_stop instead of Pi's agent_settled event.
// This extension only writes lifecycle metadata and user prompts.
export default function kestra(pi) {
  const folder = join(homedir(), "Library/Application Support/__KESTRA_BUNDLE_IDENTIFIER__/oh-my-pi-events");
  const states = new Map();
  const unpersistedStates = new WeakMap();
  const sessionIDsByManager = new WeakMap();
  let queue = Promise.resolve();
  let sequence = 0;

  const sessionID = (ctx) => ctx.sessionManager.getSessionId();
  const stateKey = (ctx) => {
    const manager = ctx.sessionManager;
    return manager && (typeof manager === "object" || typeof manager === "function") ? manager : ctx;
  };
  const newState = () => ({
    active: false,
    pendingPrompt: null,
    hiddenContinuationExpected: false,
    pendingEvents: [],
  });
  const stateFor = (ctx) => {
    const id = sessionID(ctx);
    const key = stateKey(ctx);
    if (id) {
      sessionIDsByManager.set(key, id);
      let state = states.get(id);
      if (!state) {
        state = unpersistedStates.get(key) ?? newState();
      }
      unpersistedStates.delete(key);
      states.set(id, state);
      return state;
    }

    let state = unpersistedStates.get(key);
    if (!state) {
      state = newState();
      unpersistedStates.set(key, state);
    }
    return state;
  };
  const contextMetadata = (ctx) => ({
    cwd: ctx.cwd,
    model: ctx.model?.id,
    effort: typeof pi.getThinkingLevel === "function" ? pi.getThinkingLevel() : ctx.thinkingLevel,
  });
  const record = (ctx, kind, fields = {}, session = sessionID(ctx), metadata = contextMetadata(ctx)) => {
    if (!session) return Promise.resolve();
    const event = {
      session_id: session,
      hook_event_name: kind,
      ...metadata,
      ...fields,
    };
    queue = queue.then(async () => {
      await mkdir(folder, { recursive: true, mode: 0o700 });
      const name = Date.now() + "-" + String(sequence++).padStart(8, "0") + "-" + randomUUID();
      const temp = join(folder, name + ".tmp");
      await writeFile(temp, JSON.stringify(event), { mode: 0o600 });
      await rename(temp, join(folder, name + ".json"));
    }).catch(() => { console.error("Kestra: could not record oh-my-pi task event"); });
    return queue;
  };
  const flushPendingEvents = (ctx, state, session = sessionID(ctx)) => {
    if (!session || state.pendingEvents.length === 0) return Promise.resolve();
    const pendingEvents = state.pendingEvents.splice(0);
    for (const pending of pendingEvents) {
      record(ctx, pending.kind, pending.fields, session, pending.metadata);
    }
    return queue;
  };
  const recordForState = (ctx, state, kind, fields = {}, session = sessionID(ctx)) => {
    if (!session) {
      state.pendingEvents.push({ kind, fields: { ...fields }, metadata: contextMetadata(ctx) });
      return Promise.resolve();
    }
    flushPendingEvents(ctx, state, session);
    return record(ctx, kind, fields, session);
  };
  const stopReason = (event) => {
    const messages = event?.messages;
    let message = event?.last_assistant_message;
    if (!message && Array.isArray(messages)) {
      for (let index = messages.length - 1; index >= 0; index -= 1) {
        if (messages[index]?.role === "assistant") {
          message = messages[index];
          break;
        }
      }
      message ??= messages[messages.length - 1];
    }
    return message?.stopReason ?? message?.stop_reason;
  };
  const stopEvent = (reason) => {
    if (reason === "aborted") return "StopCancelled";
    if (reason === "error") return "StopFailure";
    return "Stop";
  };
  const closePreviousSession = async (_event, ctx) => {
    const manager = stateKey(ctx);
    const previousID = sessionIDsByManager.get(manager);
    const currentID = sessionID(ctx);
    if (!currentID) return;
    if (previousID && previousID !== currentID) {
      const previousState = states.get(previousID);
      if (previousState?.active) {
        previousState.active = false;
        previousState.pendingPrompt = null;
        previousState.hiddenContinuationExpected = false;
        await recordForState(ctx, previousState, "SessionEnd", {}, previousID);
      } else if (previousState) {
        await flushPendingEvents(ctx, previousState, previousID);
      }
      states.delete(previousID);
      unpersistedStates.delete(manager);
    }
    sessionIDsByManager.set(manager, currentID);
    const currentState = stateFor(ctx);
    await flushPendingEvents(ctx, currentState, currentID);
  };

  pi.on("before_agent_start", async (event, ctx) => {
    const state = stateFor(ctx);
    // This hook runs for ordinary chat too. Defer starting a task until OMP
    // actually invokes a tool. Automatic continuations are marked by
    // agent_end.willContinue and are not user messages for the task preview.
    if (state.active) {
      if (state.hiddenContinuationExpected) {
        state.hiddenContinuationExpected = false;
        return;
      }
      await recordForState(ctx, state, "UserPromptSubmit", { prompt: event.prompt });
      return;
    }
    state.pendingPrompt = event.prompt;
  });
  pi.on("tool_call", async (_event, ctx) => {
    const state = stateFor(ctx);
    if (!state.active) {
      if (state.pendingPrompt == null) return;
      state.active = true;
      await recordForState(ctx, state, "UserPromptSubmit", { prompt: state.pendingPrompt });
      state.pendingPrompt = null;
    }
    await recordForState(ctx, state, "PreToolUse");
  });
  pi.on("agent_end", async (event, ctx) => {
    const state = stateFor(ctx);
    if (!state.active) return;
    if (event.willContinue === true) {
      state.hiddenContinuationExpected = true;
      return;
    }

    const reason = stopReason(event);
    state.active = false;
    state.pendingPrompt = null;
    state.hiddenContinuationExpected = false;
    await recordForState(ctx, state, stopEvent(reason));
  });
  // These events run after OMP has changed the active session. Keep the old
  // session ID separately so a running task is ended against its original ID.
  pi.on("session_switch", closePreviousSession);
  pi.on("session_branch", closePreviousSession);
  pi.on("session_shutdown", async (_event, ctx) => {
    const state = stateFor(ctx);
    if (state.active) {
      state.active = false;
      await recordForState(ctx, state, "SessionEnd");
    } else {
      await flushPendingEvents(ctx, state);
    }
    states.delete(sessionID(ctx));
    unpersistedStates.delete(stateKey(ctx));
    sessionIDsByManager.delete(stateKey(ctx));
    await queue;
  });
}
