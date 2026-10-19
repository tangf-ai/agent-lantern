// Local status only. No prompts, responses, tool arguments or credentials are recorded.
import { mkdirSync, writeFileSync, renameSync, unlinkSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export class TokenRate {
  phase = "waiting";
  active = false;
  began = 0;
  samples: {count: number, time: number}[] = [];
  recent: {outputTokens: number, durationMs: number, at: number} | undefined;
  private clock: () => number;
  private wall: () => number;
  constructor(clock = () => performance.now(), wall = () => Date.now()) { this.clock = clock; this.wall = wall; }
  reset() { this.phase = "waiting"; this.active = false; this.samples = []; this.recent = undefined; }
  begin() { this.phase = "generating"; this.active = true; this.began = this.clock(); this.samples = []; }
  setPhase(phase: string) { this.phase = phase; this.active = false; this.samples = []; }
  observe(count: unknown) {
    if (!this.active || typeof count !== "number" || !Number.isFinite(count) || count <= 0 || count > 1e9) return;
    const now = this.clock(), last = this.samples.at(-1);
    if (last && count === last.count) return;
    if (last && count < last.count) this.samples = [];
    this.samples.push({count, time: now});
    while (this.samples.length > 2 && this.samples[1].time < now - 5000) this.samples.shift();
    if (this.samples.length > 64) this.samples.splice(1, this.samples.length - 64);
  }
  finish(outputTokens: unknown, durationMs: unknown, success: boolean) {
    if (success && typeof outputTokens === "number" && typeof durationMs === "number" &&
        Number.isFinite(outputTokens) && Number.isFinite(durationMs) && outputTokens > 0 && outputTokens <= 1e9 && durationMs > 0) {
      this.recent = {outputTokens, durationMs, at: this.wall()};
    }
    this.setPhase("waiting");
  }
  snapshot() {
    const now = this.clock(), first = this.samples[0], last = this.samples.at(-1);
    let live: {startCount: number, endCount: number, elapsedMs: number, at: number} | undefined;
    // Two positive, increasing counters are required. An end-only usage report never becomes "live".
    if (this.active && first && last && last.count > first.count && last.time - first.time >= 250 && now - last.time <= 3000) {
      live = {startCount: first.count, endCount: last.count, elapsedMs: last.time - first.time,
        at: this.wall() - (now - last.time)};
    }
    return {version: 1, phase: this.phase, updated: this.wall(), live, recent: this.recent};
  }
}

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
  const rate = new TokenRate();
  let lastPublished = 0;
  function publish() {
    if (!initialized) return;
    try {
      const temporary = file + ".tmp";
      writeFileSync(temporary, JSON.stringify({schema: 1, instance, pid: process.pid,
        processStart, cwd, state, started, completion, metrics: rate.snapshot(), updated: Date.now()}), {mode: 0o600});
      renameSync(temporary, file);
      lastPublished = Date.now();
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
      timer = setInterval(() => {
        if (rate.active || Date.now() - lastPublished >= 5000) publish();
      }, 1000);
      timer.unref();
      publish();
    } catch { /* Keep Pi usable if the state directory is unavailable. */ }
  });
  pi.on("agent_start", (_event, ctx) => {
    cwd = ctx.cwd;
    state = "running";
    started = Date.now();
    run = randomUUID();
    rate.reset();
    blocked = 0;
    uiBlocked = 0;
    activeTools.clear();
    publish();
  });
  // agent_end may be followed by retries or queued continuation; settled is the final boundary.
  pi.on("agent_settled", (event, ctx) => {
    if (ctx.isIdle()) {
      if (!event.aborted && state !== "idle") completion = {id: run, at: Date.now()};
      state = "idle"; blocked = 0; uiBlocked = 0; activeTools.clear(); rate.setPhase("idle"); publish();
    }
  });
  pi.on("tool_execution_start", (event) => {
    activeTools.add(event.toolCallId);
    rate.setPhase("tools");
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
    rate.setPhase("waiting");
    publish();
  });
  pi.on("ui_prompt_end", () => {
    uiBlocked = Math.max(0, uiBlocked - 1);
    if (state !== "idle") state = blocked + uiBlocked > 0 ? "waiting" : "running";
    publish();
  });
  pi.on("before_provider_request", () => { rate.begin(); publish(); });
  pi.on("message_start", (event) => {
    if (event.message?.role === "assistant" && !rate.active) { rate.begin(); publish(); }
  });
  pi.on("message_update", (event) => {
    const part = event.assistantMessageEvent;
    if (part && ["text_delta", "thinking_delta", "toolcall_delta"].includes(part.type)) {
      rate.observe((event.message as any)?.usage?.output);
      if (Date.now() - lastPublished >= 1000) publish();
    }
  });
  pi.on("provider_stream_event", (event) => {
    const data = event.data as any;
    if (!data || typeof data !== "object") return;
    // Continuous-usage OpenAI-compatible chunks. Empty/final chunks are not live samples.
    if (Array.isArray(data.choices) && data.choices.length && data.choices.every((c: any) => c.finish_reason == null)) {
      rate.observe(data.usage?.completion_tokens);
    } else if (["content_block_delta", "response.output_text.delta", "response.reasoning_summary_text.delta"].includes(data.type)) {
      rate.observe(data.usage?.output_tokens);
    }
    if (Date.now() - lastPublished >= 1000) publish();
  });
  pi.on("message_end", (event) => {
    const message = event.message as any;
    if (message?.role !== "assistant") return;
    rate.finish(message.usage?.output, message.durationMs, ["stop", "length", "toolUse", "deferred"].includes(message.stopReason));
    if (message.stopReason === "toolUse") rate.setPhase("tools");
    publish();
  });
  pi.on("session_shutdown", () => {
    if (timer) clearInterval(timer);
    timer = undefined;
    initialized = false;
    try { unlinkSync(file); } catch {}
  });
}
