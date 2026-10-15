// Local status only. No prompts, responses, tool arguments or credentials are recorded.
import { mkdirSync, writeFileSync, renameSync, unlinkSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  const instance = randomUUID();
  const directory = join(process.env.AGENT_LANTERN_STATE_DIR || join(homedir(), "Library/Application Support/AgentLantern"), "pi");
  const file = join(directory, `${process.pid}-${instance}.json`);
  let state = "idle", started = 0, cwd = "", processStart = "";
  let timer: ReturnType<typeof setInterval> | undefined;
  let initialized = false;
  let blocked = 0;
  let uiBlocked = 0;
  let run = randomUUID();
  let completion: {id: string, at: number} | undefined;
  const activeTools = new Set<string>();
  function publish() {
    if (!initialized) return;
    try {
      const temporary = file + ".tmp";
      writeFileSync(temporary, JSON.stringify({schema: 1, instance, pid: process.pid,
        processStart, cwd, state, started, completion, updated: Date.now()}), {mode: 0o600});
      renameSync(temporary, file);
    } catch { /* An optional display must never interrupt the agent. */ }
  }
  pi.on("session_start", (_event, ctx) => {
    try {
      mkdirSync(directory, {recursive: true, mode: 0o700});
      processStart = execFileSync("/bin/ps", ["-p", String(process.pid), "-o", "lstart="],
        {encoding: "utf8", timeout: 1000, env: {...process.env, LC_ALL: "C", LANG: "C"}}).trim().replace(/\s+/g, " ");
      initialized = true;
      cwd = ctx.cwd;
      state = ctx.isIdle() ? "idle" : "running";
      started = state === "running" ? Date.now() : 0;
      if (timer) clearInterval(timer);
      timer = setInterval(publish, 5000);
      timer.unref();
      publish();
    } catch { /* Keep Pi usable if the state directory is unavailable. */ }
  });
  pi.on("agent_start", (_event, ctx) => {
    cwd = ctx.cwd;
    state = "running";
    started = Date.now();
    run = randomUUID();
    blocked = 0;
    uiBlocked = 0;
    activeTools.clear();
    publish();
  });
  // agent_end may be followed by retries or queued continuation; settled is the final boundary.
  pi.on("agent_settled", (event, ctx) => {
    if (ctx.isIdle()) {
      if (!event.aborted && state !== "idle") completion = {id: run, at: Date.now()};
      state = "idle"; blocked = 0; uiBlocked = 0; activeTools.clear(); publish();
    }
  });
  pi.on("tool_execution_start", (event) => {
    activeTools.add(event.toolCallId);
    publish();
  });
  pi.on("tool_execution_end", (event) => {
    activeTools.delete(event.toolCallId);
    publish();
  });
  // Cooperate with existing Herdr approval providers without changing any tool behavior.
  pi.events.on("herdr:blocked", (event: any) => {
    blocked = Math.max(0, blocked + (event?.active ? 1 : -1));
    if (state !== "idle") state = blocked + uiBlocked > 0 ? "waiting" : "running";
    publish();
  });
  pi.on("ui_prompt_start", () => {
    uiBlocked += 1;
    if (state !== "idle") state = "waiting";
    publish();
  });
  pi.on("ui_prompt_end", () => {
    uiBlocked = Math.max(0, uiBlocked - 1);
    if (state !== "idle") state = blocked + uiBlocked > 0 ? "waiting" : "running";
    publish();
  });
  pi.on("session_shutdown", () => {
    if (timer) clearInterval(timer);
    timer = undefined;
    initialized = false;
    try { unlinkSync(file); } catch {}
  });
}
