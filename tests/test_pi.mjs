import assert from "node:assert/strict";
import {mkdtempSync, readdirSync, readFileSync, rmSync} from "node:fs";
import {tmpdir} from "node:os";
import {join} from "node:path";

const dir = mkdtempSync(join(tmpdir(), "lantern-pi-test-"));
process.env.AGENT_LANTERN_STATE_DIR = dir;
const {default: extension} = await import("../Resources/agent-lantern.ts");
const handlers = new Map();
const events = new Map();
let idle = true;
const ctx = {cwd: "/tmp/example-project", isIdle: () => idle};
extension({on: (name, handler) => handlers.set(name, handler), events: {on: (name, handler) => events.set(name, handler)}});
function state() {
  const files = readdirSync(join(dir, "pi")).filter(f => f.endsWith(".json"));
  assert.equal(files.length, 1);
  return JSON.parse(readFileSync(join(dir, "pi", files[0]), "utf8"));
}
try {
  assert.equal(readdirSync(dir).length, 0, "factory must not start resources");
  handlers.get("session_start")({}, ctx);
  assert.equal(state().state, "idle");
  assert.ok(state().processStart);
  idle = false;
  handlers.get("agent_start")({}, ctx);
  assert.equal(state().state, "running");
  handlers.get("before_provider_request")({payload: {secret: "DO_NOT_STORE"}}, ctx);
  handlers.get("message_start")({message: {role: "assistant"}}, ctx);
  handlers.get("message_update")({message: {role: "assistant", usage: {output: 0}}, assistantMessageEvent: {type: "text_delta", delta: "DO_NOT_STORE"}}, ctx);
  assert.equal(state().metrics.live, undefined);
  handlers.get("message_end")({message: {role: "assistant", usage: {output: 120, reasoning: 40}, durationMs: 3000, stopReason: "toolUse"}}, ctx);
  assert.equal(state().metrics.recent.outputTokens, 120, "reasoning is already included in output");
  assert.equal(state().metrics.recent.durationMs, 3000);
  assert.equal(state().metrics.phase, "tools");
  assert.equal(JSON.stringify(state()).includes("DO_NOT_STORE"), false);
  assert.equal(handlers.has("agent_end"), false, "intermediate agent_end must not end retries");
  handlers.get("ui_prompt_start")({kind: "confirm"}, ctx);
  assert.equal(state().state, "waiting");
  handlers.get("ui_prompt_start")({kind: "input"}, ctx);
  handlers.get("ui_prompt_end")({kind: "input"}, ctx);
  assert.equal(state().state, "waiting", "nested prompts remain blocked");
  handlers.get("ui_prompt_end")({kind: "confirm"}, ctx);
  assert.equal(state().state, "running");
  handlers.get("agent_settled")({}, ctx);
  assert.equal(state().state, "running", "settle while not idle must not hide continuation");
  idle = true;
  handlers.get("agent_settled")({}, ctx);
  assert.equal(state().state, "idle");
  assert.ok(state().completion.id);
  const completed = state().completion.id;
  idle = false;
  handlers.get("agent_start")({}, ctx);
  idle = true;
  handlers.get("agent_settled")({aborted: true}, ctx);
  assert.equal(state().completion.id, completed, "abort must not produce a new completion sound");
  assert.equal("prompt" in state(), false);
  handlers.get("session_shutdown")({}, ctx);
  assert.equal(readdirSync(join(dir, "pi")).filter(f => f.endsWith(".json")).length, 0);
  handlers.get("session_shutdown")({}, ctx);
  console.log("Pi lifecycle: idle → running → nested waiting → running → settled → shutdown: PASS");
} finally {
  handlers.get("session_shutdown")?.({}, ctx);
  rmSync(dir, {recursive: true, force: true});
}
