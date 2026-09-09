import { mkdir, writeFile, rename } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";

// OpenCode plugin API: observes events without modifying prompts or tool results.
export const IslandBarPlugin = async ({ directory }) => {
  const folder = join(homedir(), "Library/Application Support/com.kiannest.islandbar/opencode-events");
  const models = new Map();
  let queue = Promise.resolve();
  let sequence = 0;
  const record = (sessionID, kind, fields = {}) => {
    if (!sessionID) return Promise.resolve();
    const event = {
      session_id: sessionID, hook_event_name: kind, cwd: directory,
      model: models.get(sessionID), ...fields,
    };
    queue = queue.then(async () => {
      await mkdir(folder, { recursive: true, mode: 0o700 });
      const name = Date.now() + "-" + String(sequence++).padStart(8, "0") + "-" + randomUUID();
      const temporary = join(folder, name + ".tmp");
      await writeFile(temporary, JSON.stringify(event), { mode: 0o600 });
      await rename(temporary, join(folder, name + ".json"));
    }).catch(() => {
      // Monitoring failure must never interrupt the agent's work.
      console.error("IslandBar: could not record OpenCode task event");
    });
    return queue;
  };
  return {
    "chat.message": async (input, output) => {
      const model = output.message.model ?? input.model;
      if (model?.modelID) models.set(input.sessionID, model.modelID);
      const prompt = output.parts.filter(p => p.type === "text" && !p.synthetic && !p.ignored)
        .map(p => p.text).join("\n");
      await record(input.sessionID, "UserPromptSubmit", { prompt });
    },
    "chat.params": async (input) => {
      if (input.model?.id) models.set(input.sessionID, input.model.id);
      await record(input.sessionID, "ModelUpdate");
    },
    event: async ({ event }) => {
      const p = event.properties;
      if (event.type === "session.status" && p.status.type !== "idle") {
        await record(p.sessionID, "PreToolUse");
      } else if (event.type === "session.idle") {
        await record(p.sessionID, "Stop");
      } else if (event.type === "session.error") {
        await record(p.sessionID, "StopFailure");
      } else if (event.type === "session.deleted") {
        await record(p.info.id, "SessionEnd");
        models.delete(p.info.id);
      }
    },
  };
};
