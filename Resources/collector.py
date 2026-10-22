#!/usr/bin/env python3
"""Local, read-only adapters. Never emit prompts, responses, credentials or tool input."""
from __future__ import annotations

import argparse
import datetime as dt
import json
import hashlib
import math
import copy
import io
import os
from pathlib import Path
import re
import signal
import shutil
import sqlite3
import subprocess
import sys
import time


def timestamp(value):
    if isinstance(value, (int, float)):
        return value / 1000 if value > 1e11 else float(value)
    try:
        return dt.datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp()
    except (ValueError, TypeError):
        return 0.0


def read_json(path):
    with Path(path).open() as f:
        return json.load(f)


def no_speed(detail, status="unavailable"):
    return {"status": status, "detail": detail}


def finite_number(value, minimum=0):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and value >= minimum


def read_speed(metrics, now, state="running", not_before=0):
    if not isinstance(metrics, dict) or metrics.get("version") != 1:
        return no_speed("等待扩展加载 TPS 采集功能", "reload")
    live, recent = metrics.get("live"), metrics.get("recent")
    if state == "running" and metrics.get("phase") == "generating" and isinstance(live, dict):
        start, end, elapsed, at = (live.get(k) for k in ["startCount", "endCount", "elapsedMs", "at"])
        at = timestamp(at)
        if all(finite_number(v) for v in [start, end, elapsed]) and end > start > 0 and 250 <= elapsed <= 60000 and 0 <= now - at <= 3 and at >= not_before:
            value = (end - start) * 1000 / elapsed
            if 0 < value < 1e6:
                return {"status": "live", "value": value, "measuredAt": at,
                        "detail": "实时输出 TPS：实际增量 token 计数 / 本地接收时间差；最近约 5 秒窗口，不按文字块数量估算"}
    if isinstance(recent, dict):
        count, duration, at = (recent.get(k) for k in ["outputTokens", "durationMs", "at"])
        at = timestamp(at)
        if finite_number(count, 1) and finite_number(duration, 0.001) and count <= 1e9 and 0 <= now - at <= 300 and at >= not_before:
            value = count * 1000 / duration
            if 0 < value < 1e6:
                return {"status": "recent", "value": value, "measuredAt": at,
                        "outputTokens": int(count), "durationMs": duration,
                        "detail": "最近一次模型响应均速 = 输出 token / 请求耗时；包含首 token 等待，不包含工具执行；输出用量已含提供商计入的推理 token"}
    if metrics.get("phase") == "tools":
        return no_speed("执行工具中，尚无有效响应速度；工具时间不用于计算模型 TPS", "tools")
    return no_speed("尚无有效输出计数与响应计时；只有最终用量的提供商需要等响应结束", "sampling")


def flow(phase="unknown", at=0, detail="当前数据只确认任务运行，尚未确认模型收发"):
    return {"phase": phase, "at": at, "detail": detail}


def record_transfer(events, kind, at, key=""):
    if not finite_number(at, 0.001): return
    identity = f"{kind}:{hashlib.sha256(str(key).encode()).hexdigest()[:16]}:{at}"
    if not any(e["id"] == identity for e in events):
        events.append({"id": identity, "kind": kind, "at": at})
        del events[:-12]


def clean_transfers(values, started, now):
    result = []
    if not isinstance(values, list): return result
    for event in values[-12:]:
        if not isinstance(event, dict): continue
        at = timestamp(event.get("at"))
        identity, kind = event.get("id"), event.get("kind")
        if (isinstance(identity, str) and 0 < len(identity) <= 200 and
            kind in {"request", "response", "context"} and finite_number(at, 0.001) and
            started <= at <= now and now - at <= 30):
            result.append({"id": identity, "kind": kind, "at": at})
    return result


def pi_flow(data, now):
    value = data.get("flow")
    started = timestamp(data.get("started"))
    if isinstance(value, dict) and value.get("phase") in {"request", "receiving", "response", "tools", "processing", "unknown"}:
        at = timestamp(value.get("at"))
        if finite_number(at) and started <= at <= now:
            # Never forward arbitrary extension text or conversation data.
            return {**flow(value["phase"], at, "Pi 扩展生命周期与流式事件；光点仅表示方向，不代表 token 数量或网络数据包"),
                    "transfers": clean_transfers(value.get("transfers"), started, now)}
    return flow(detail="Pi 扩展尚未提供收发阶段；下次启动或 /reload 后接入")


def hermes_speed(state_dir, pid, sid, acquired, processes, now):
    name = f"{pid}-{hashlib.sha256(str(sid).encode()).hexdigest()[:24]}.json"
    try:
        data = read_json(state_dir / "hermes" / name)
        if data.get("schema") == 1 and data.get("pid") == pid and data.get("sessionId") == sid and alive(pid, processes, data.get("processStart")):
            return read_speed(data.get("metrics"), now, not_before=acquired)
    except (OSError, ValueError, TypeError):
        pass
    return no_speed("Hermes TPS 插件尚未产生当前任务的响应统计；插件加载后首次响应结束才有均速")


def process_table():
    out = subprocess.run(["/bin/ps", "-axo", "pid=,ppid=,lstart=,comm="],
                         capture_output=True, text=True, timeout=4, check=True,
                         env={**os.environ, "LC_ALL": "C", "LANG": "C"}).stdout
    result = {}
    for line in out.splitlines():
        parts = line.strip().split(None, 7)
        if len(parts) == 8:
            result[int(parts[0])] = {"parent": int(parts[1]), "start": " ".join(parts[2:7]),
                                     "name": parts[7]}
    return result


def process_fingerprint(value):
    """Normalize both C and day-first BSD ps dates, including heartbeats from loaded older extensions."""
    clean = " ".join(str(value or "").split())
    match = re.fullmatch(
        r"[A-Za-z]{3} (?:(?P<month_a>[A-Za-z]{3}) (?P<day_a>\d{1,2})|"
        r"(?P<day_b>\d{1,2}) (?P<month_b>[A-Za-z]{3})) "
        r"(?P<clock>\d{2}:\d{2}:\d{2}) (?P<year>\d{4})", clean)
    if not match:
        return clean
    month = match["month_a"] or match["month_b"]
    day = int(match["day_a"] or match["day_b"])
    return f"{match['year']} {month} {day} {match['clock']}"


def alive(pid, processes, fingerprint=None):
    row = processes.get(int(pid or 0))
    return bool(row and (not fingerprint or process_fingerprint(row["start"]) == process_fingerprint(fingerprint)))


def open_rollouts(processes):
    pids = [str(p) for p, row in processes.items()
            if Path(row["name"]).name.lower() == "codex"]
    if not pids:
        return {}
    proc = subprocess.run(["/usr/sbin/lsof", "-nP", "-p", ",".join(pids), "-Fn"],
                          capture_output=True, text=True, timeout=6)
    if proc.returncode not in (0, 1):
        raise RuntimeError("lsof unavailable")
    result, pid = {}, None
    for line in proc.stdout.splitlines():
        if re.fullmatch(r"p\d+", line):
            pid = int(line[1:])
        elif line.startswith("n/") and "/sessions/" in line and line.endswith(".jsonl"):
            result[Path(line[1:])] = pid
    return result


class CodexLog:
    """Incremental complete-line reader; preserve an unterminated line for the next poll."""
    def __init__(self, path):
        self.path = Path(path)
        self.offset = 0
        self.inode = None
        self.session = self.path.stem[-36:]
        self.project = "Codex 会话"
        self.turn = None
        self.started = 0.0
        self.last_event = 0.0
        self.state = "idle"
        self.pending = set()
        self.tools = set()
        self.flow = flow()
        self.transfers = []
        self.valid = False
        self.completions = []

    def poll(self):
        st = self.path.stat()
        if self.inode != st.st_ino or st.st_size < self.offset:
            self.__init__(self.path)
            self.inode = st.st_ino
        with self.path.open("rb") as f:
            f.seek(self.offset)
            for line in f:
                if not line.endswith(b"\n"):
                    break
                self.offset += len(line)
                try:
                    self.consume(json.loads(line))
                except (ValueError, TypeError, AttributeError):
                    continue

    def consume(self, event):
        payload = event.get("payload") or {}
        kind = event.get("type")
        at = timestamp(event.get("timestamp"))
        if kind == "session_meta":
            self.session = payload.get("id", self.session)
            self.project = Path(payload.get("cwd") or "Codex 会话").name
        if kind == "event_msg":
            typ = payload.get("type")
            turn = payload.get("turn_id")
            if typ == "task_started":
                self.turn = turn
                self.started = timestamp(payload.get("started_at")) or at
                self.state = "running"
                self.pending.clear()
                self.tools.clear()
                self.flow = flow()
                self.transfers.clear()
                self.valid = True
            elif typ in {"task_complete", "turn_aborted", "task_cancelled", "task_failed"}:
                if typ == "task_complete" and turn:
                    self.completions.append({"id": f"codex:{self.session}:{turn}", "agent": "Codex",
                                             "label": self.project, "at": at})
                    self.completions = self.completions[-16:]
                # A delayed completion for an old turn must not stop the new one.
                if not turn or turn == self.turn:
                    self.state = "idle"
                    self.pending.clear()
                    self.valid = True
            if typ in {"agent_message", "agent_reasoning"} and self.state != "idle":
                record_transfer(self.transfers, "response", at)
                if not self.tools: self.flow = flow("response", at, "观察到 Codex 响应落盘；非实时网络收包")
            self.last_event = max(at, self.last_event)
        if kind == "response_item" and self.state != "idle":
            typ = payload.get("type")
            name = payload.get("name", "")
            call = payload.get("call_id")
            if typ in {"function_call", "custom_tool_call"}:
                record_transfer(self.transfers, "response", at, call or "tool-call")
                if call:
                    self.tools.add(call)
                    if name.split(".")[-1] == "request_user_input": self.pending.add(call)
                self.flow = flow("tools", at, "Codex 已记录工具调用；工具输出不等于已发送给模型")
            elif typ in {"function_call_output", "custom_tool_call_output"}:
                self.pending.discard(call)
                self.tools.discard(call)
                record_transfer(self.transfers, "context", at, call or "tool-result")
                if not self.tools: self.flow = flow("processing", at, "工具已返回，后续模型请求尚未确认")
            elif typ == "reasoning" or (typ == "message" and payload.get("role") == "assistant"):
                record_transfer(self.transfers, "response", at)
                if not self.tools: self.flow = flow("response", at, "观察到 Codex 响应落盘；非实时网络收包")
            self.state = "waiting" if self.pending else "running"

    def task(self, pid):
        return {"id": "codex:" + self.session, "agent": "Codex", "label": self.project,
                "state": self.state, "started": self.started, "pid": pid,
                "evidence": "任务生命周期事件", "flow": {**self.flow, "transfers": self.transfers},
                "speed": no_speed("Codex 当前本地用量记录缺少单次模型请求的完整计时和实时 token 计数，无法准确计算 TPS")}


class DeepSeekLog:
    """Read committed Harness lifecycle events without keeping conversation content."""
    def __init__(self, path):
        self.path = Path(path)
        self.offset = 0
        self.inode = None
        self.session = None
        self.project = "DeepSeek 会话"
        self.turn = None
        self.started = 0.0
        self.state = "idle"
        self.pending = set()
        self.tools = set()
        self.flow = flow()
        self.transfers = []
        self.completions = []

    def consume(self, event):
        kind = event.get("type")
        if kind == "session":
            version = event.get("version", 0)
            if isinstance(version, bool) or not isinstance(version, int) or version not in range(5):
                raise ValueError("Unsupported DeepSeek session format")
            if not isinstance(event.get("id"), str) or not event["id"]:
                raise ValueError("Missing DeepSeek session id")
            self.session = event["id"]
            cwd = event.get("cwd")
            if isinstance(cwd, str) and cwd: self.project = Path(cwd).name
            return
        if not self.session:
            raise ValueError("DeepSeek session header must precede events")
        data = event.get("data") or {}
        if not isinstance(data, dict): raise ValueError("Invalid DeepSeek event data")
        turn = data.get("turn")
        if kind == "turn/start":
            if not isinstance(turn, int) or isinstance(turn, bool): raise ValueError("Invalid DeepSeek turn")
            self.turn = turn
            self.started = timestamp(event.get("time"))
            self.pending.clear()
            self.tools.clear()
            self.flow = flow()
            self.transfers.clear()
            self.state = "running"
        elif kind == "turn/end" and turn == self.turn:
            reason = data.get("reason") or {}
            if isinstance(reason, dict) and reason.get("kind") == "completed":
                self.completions.append({"id": f"deepseek:{self.session}:{turn}:{self.started}", "agent": "DeepSeek",
                                         "label": self.project, "at": timestamp(event.get("time"))})
                self.completions = self.completions[-16:]
            self.state = "idle"
            self.pending.clear()
        elif kind == "approval/asked" and self.state != "idle" and isinstance(data.get("id"), str):
            self.pending.add(data["id"])
            self.state = "waiting"
        elif kind == "approval/decided" and self.state != "idle":
            self.pending.discard(data.get("id"))
            self.state = "waiting" if self.pending else "running"
        elif self.state != "idle" and turn == self.turn:
            at = timestamp(event.get("time"))
            if kind == "tool/call" and isinstance(data.get("callId"), str):
                self.tools.add(data["callId"])
                record_transfer(self.transfers, "response", at, data["callId"])
                self.flow = flow("tools", at, "DeepSeek Harness 已落盘的工具调用")
            elif kind == "tool/result":
                self.tools.discard(data.get("callId"))
                record_transfer(self.transfers, "context", at, data.get("callId") or "tool-result")
                if not self.tools: self.flow = flow("processing", at, "工具已返回，后续模型请求尚未确认")
            elif kind == "assistant/message":
                record_transfer(self.transfers, "response", at)
                if not self.tools: self.flow = flow("response", at, "DeepSeek Harness 响应已落盘；随持久化检查点更新，非实时网络收包")

    def poll(self, zstd):
        stat = self.path.stat()
        reset = self.inode != stat.st_ino or stat.st_size < self.offset
        if not reset and stat.st_size == self.offset: return
        candidate = DeepSeekLog(self.path) if reset else copy.deepcopy(self)
        candidate.inode = stat.st_ino
        with self.path.open("rb", buffering=0) as source:
            source.seek(candidate.offset)
            if self.path.name.endswith(".zstd"):
                if not zstd: raise ValueError("zstd is required to read compressed DeepSeek logs")
                result = subprocess.run([zstd, "-dq", "-c"], stdin=source, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, timeout=5)
                if result.returncode != 0: raise ValueError("DeepSeek compressed frame is incomplete or invalid")
                # Each Harness append is a complete independent Zstandard frame. Commit only after checksum validation.
                for line in io.BytesIO(result.stdout):
                    if not line.endswith(b"\n"): raise ValueError("DeepSeek JSONL row is incomplete")
                    candidate.consume(json.loads(line))
                candidate.offset = source.tell()
            else:
                for line in source:
                    if not line.endswith(b"\n"): break
                    candidate.consume(json.loads(line))
                    candidate.offset += len(line)
        self.__dict__.update(candidate.__dict__)

    def task(self, pid):
        return {"id": "deepseek:" + self.session, "agent": "DeepSeek", "label": self.project,
                "state": self.state, "started": self.started, "pid": pid,
                "evidence": "DeepSeek Harness 进程持有会话文件，日志中存在未结束的 turn/start",
                "flow": {**self.flow, "transfers": self.transfers}, "speed": no_speed("DeepSeek Harness 已接入任务状态，尚未接入同口径的模型 TPS 统计")}


def deepseek_owners(home, processes):
    candidates = [str(pid) for pid, row in processes.items() if
                  "deepseek" in Path(row["name"]).name.lower() or Path(row["name"]).name.lower() in {"node", "nodejs", "dsh"}]
    if not candidates: return {}
    roots = [(home / ".dsh/sessions").resolve()]
    if os.environ.get("DSH_HOME"): roots.append((Path(os.environ["DSH_HOME"]).expanduser() / "sessions").resolve())
    result = subprocess.run(["/usr/sbin/lsof", "-nP", "-p", ",".join(candidates), "-Fn"],
                            capture_output=True, text=True, timeout=6)
    if result.returncode not in (0, 1): raise RuntimeError("Cannot inspect DeepSeek session owners")
    owners, pid = {}, None
    for line in result.stdout.splitlines():
        if re.fullmatch(r"p\d+", line): pid = int(line[1:])
        elif pid in processes and line.startswith("n/") and line.endswith("/session.lock"):
            path = Path(line[1:]).parent.resolve()
            known_process = "deepseek" in Path(processes[pid]["name"]).name.lower() or Path(processes[pid]["name"]).name.lower() == "dsh"
            if known_process or any(path.is_relative_to(root) for root in roots): owners[path] = pid
    return owners


def deepseek_log_path(folder):
    found = []
    for path in folder.iterdir():
        match = re.fullmatch(r"session(?:\.v([1-9]\d*))?\.jsonl(?:\.zstd)?", path.name)
        if match and path.is_file(): found.append((int(match[1] or 0), path))
    if not found: return None
    highest = max(version for version, _ in found)
    current = [path for version, path in found if version == highest]
    if highest > 4 or len(current) != 1: raise ValueError("Unsupported or ambiguous DeepSeek session generation")
    return current[0]


class DeepSeekAdapter:
    def __init__(self, home):
        self.home = home
        self.logs = {}
        self.owners = {}
        self.last_seen = {}
        self.last_discovery = 0
        self.discovery_error = False
        self.zstd = next((p for p in [shutil.which("zstd"), "/opt/homebrew/bin/zstd", "/usr/local/bin/zstd"] if p and os.path.isfile(p)), None)

    def snapshot(self, processes, now):
        problems, tasks, completions = [], [], []
        unsupported = set()
        if now - self.last_discovery >= 8:
            try:
                self.owners = deepseek_owners(self.home, processes)
                self.discovery_error = False
            except (OSError, RuntimeError, subprocess.SubprocessError):
                self.discovery_error = True
                self.owners = {}
            self.last_discovery = now
        if self.discovery_error: problems.append("无法确认 DeepSeek 会话进程")
        for folder in self.owners:
            self.last_seen[folder] = now
            try:
                path = deepseek_log_path(folder)
                if path and (folder not in self.logs or self.logs[folder].path != path): self.logs[folder] = DeepSeekLog(path)
            except (OSError, ValueError):
                unsupported.add(folder)
                problems.append("DeepSeek 会话格式暂不支持")
        for folder in list(self.logs):
            if folder in unsupported: continue
            if now - self.last_seen.get(folder, 0) > 300:
                del self.logs[folder]; self.last_seen.pop(folder, None)
                continue
            log = self.logs[folder]
            try:
                log.poll(self.zstd)
            except (OSError, ValueError, subprocess.SubprocessError):
                problems.append("压缩会话需要 zstd" if not self.zstd and log.path.name.endswith(".zstd") else "DeepSeek 日志暂时不可读")
                continue
            pid = self.owners.get(folder)
            born = 0
            if pid and alive(pid, processes):
                try: born = dt.datetime.strptime(process_fingerprint(processes[pid]["start"]), "%Y %b %d %H:%M:%S").timestamp()
                except ValueError: pass
                if log.state in {"running", "waiting"} and log.started > 0:
                    if born and log.started < born - 2:
                        problems.append("历史未结束任务等待现场确认")
                    else: tasks.append(log.task(pid))
            completions.extend(e for e in log.completions if 0 <= now - e["at"] < 60 and e["at"] >= born)
        installed = (self.home / ".dsh").is_dir() or any("deepseek" in row["name"].lower() for row in processes.values())
        adapter = {"agent": "DeepSeek", "status": "degraded" if problems else ("ready" if installed or self.logs else "unavailable"),
                   "detail": "；".join(sorted(set(problems))) if problems else ("DeepSeek Harness 会话开始与结束事件" if installed or self.logs else "未发现本机 DeepSeek Harness")}
        return tasks, adapter, completions


def read_hermes(home, processes, now, state_dir=None):
    tasks, problems, capable = [], [], False
    state_dir = Path(state_dir or home / "Library/Application Support/AgentLantern")
    homes = [home / ".hermes"]
    profiles = home / ".hermes/profiles"
    if profiles.is_dir():
        homes.extend(p for p in profiles.iterdir() if p.is_dir() and not p.name.startswith("."))
    configured = os.environ.get("HERMES_HOME")
    if configured and Path(configured) not in homes:
        homes.append(Path(configured))
    for root in homes:
        per_pid = {}
        db = root / "state.db"
        if db.exists():
            try:
                con = sqlite3.connect(db.as_uri() + "?mode=ro", uri=True, timeout=0.15)
                try:
                    con.execute("pragma query_only=on")
                    tables = {r[0] for r in con.execute("select name from sqlite_master where type='table'")}
                    if "session_turn_leases" in tables:
                        capable = True
                        rows = con.execute("select conversation_id, holder, acquired_at, expires_at "
                                           "from session_turn_leases where expires_at > ?", (now,)).fetchall()
                        for sid, holder, acquired, expires in rows:
                            match = re.search(r"(?:^|:)pid=(\d+)(?:\D|$)", holder or "")
                            pid = int(match[1]) if match else None
                            # A lease from a killed process is not an active task.
                            if not pid or not alive(pid, processes):
                                continue
                            if "python" not in processes[pid]["name"].lower() and "hermes" not in processes[pid]["name"].lower():
                                continue
                            per_pid[pid] = per_pid.get(pid, 0) + 1
                            profile = "默认" if root.name == ".hermes" else root.name
                            tasks.append({"id": f"hermes:{root}:{sid}", "agent": "Hermes",
                                          "label": f"{profile} · 会话 {str(sid)[-6:]}",
                                          "state": "running", "started": timestamp(acquired), "pid": pid,
                                          "leaseExpires": timestamp(expires),
                                          "speed": hermes_speed(state_dir, pid, sid, timestamp(acquired), processes, now),
                                          "evidence": "未过期任务租约"})
                finally:
                    con.close()
            except (sqlite3.Error, OSError, ValueError):
                problems.append("Hermes 状态暂时不可读")
        # Gateway's count includes its own leased turns and API/cron work: only add the difference.
        status = root / "gateway_state.json"
        if status.exists():
            try:
                d = read_json(status)
                pid = d.get("pid")
                fresh = 0 <= now - timestamp(d.get("updated_at")) < 90
                if fresh and alive(pid, processes) and d.get("gateway_state") in {"running", "degraded", "draining"}:
                    capable = True
                    count = max(0, min(int(d.get("active_agents") or 0), 128))
                    for i in range(max(0, count - per_pid.get(pid, 0))):
                        tasks.append({"id": f"hermes:gateway:{pid}:{i}", "agent": "Hermes",
                                      "label": "网关任务", "state": "running", "started": 0,
                                      "pid": pid, "evidence": "网关实时任务计数",
                                      "speed": no_speed("仅有聚合网关任务计数，无法把 token 与单个请求准确关联")})
            except (ValueError, TypeError, OSError):
                problems.append("Hermes 网关状态暂时不可读")
    return tasks, {"agent": "Hermes", "status": "degraded" if problems else ("ready" if capable else "unavailable"),
                   "detail": "；".join(sorted(set(problems))) if problems else ("读取实际任务租约" if capable else "未找到受支持的状态库")}


def read_pi(state_dir, home, processes, now, completions=None):
    tasks, connected, errors = [], False, False
    for path in (state_dir / "pi").glob("*.json"):
        try:
            d = read_json(path)
            if d.get("schema") != 1 or not alive(d.get("pid"), processes, d.get("processStart")):
                continue
            if not (0 <= now - timestamp(d.get("updated")) < 25):
                continue
            connected = True
            completion = d.get("completion")
            if completions is not None and isinstance(completion, dict) and completion.get("id"):
                at = timestamp(completion.get("at"))
                if 0 <= now - at < 60:
                    completions.append({"id": "pi:" + str(completion["id"]), "agent": "Pi",
                                        "label": Path(d.get("cwd") or "Pi 会话").name, "at": at})
            if d.get("state") in {"running", "waiting"}:
                tasks.append({"id": "pi:" + str(d.get("instance", path.stem)), "agent": "Pi",
                              "label": Path(d.get("cwd") or "Pi 会话").name,
                              "state": d["state"], "started": timestamp(d.get("started")),
                              "pid": d.get("pid"), "evidence": "Pi 生命周期扩展",
                              "flow": pi_flow(d, now),
                              "speed": read_speed(d.get("metrics"), now, d["state"], timestamp(d.get("started")))})
        except (OSError, ValueError, TypeError):
            errors = True
    installed = (home / ".pi/agent/extensions/agent-lantern.ts").exists()
    detail = "生命周期扩展已连接" if connected else ("下次启动 Pi 或 /reload 后接入" if installed else "尚未安装状态扩展")
    return tasks, {"agent": "Pi", "status": "ready" if connected else ("pending" if installed else "unavailable"),
                   "detail": "部分状态文件不可读" if errors else detail}


class Collector:
    def __init__(self, home=None, state_dir=None):
        self.home = Path(home or Path.home())
        self.state_dir = Path(state_dir or os.environ.get("AGENT_LANTERN_STATE_DIR") or self.home / "Library/Application Support/AgentLantern")
        self.logs = {}
        self.open = {}
        self.last_discovery = 0
        self.discovery_error = False
        self.previous_hermes = {}
        self.last_snapshot = 0
        self.deepseek = DeepSeekAdapter(self.home)

    def discover(self, processes, now):
        try:
            self.open = open_rollouts(processes)
            self.discovery_error = False
        except (subprocess.SubprocessError, OSError, RuntimeError):
            self.discovery_error = True
            self.open = {p: pid for p, pid in self.open.items() if alive(pid, processes)}
        paths = set(self.open)
        # Read recent threads via SQLite; open_rollouts also finds old resumed sessions.
        codex_home = Path(os.environ.get("CODEX_HOME") or self.home / ".codex")
        databases = sorted(codex_home.glob("state_*.sqlite"))
        if databases:
            try:
                con = sqlite3.connect(databases[-1].as_uri() + "?mode=ro", uri=True, timeout=0.15)
                try:
                    paths.update(Path(r[0]) for r in con.execute(
                        "select rollout_path from threads where archived=0 order by updated_at desc limit 80") if r[0])
                finally:
                    con.close()
            except (sqlite3.Error, OSError):
                self.discovery_error = True
        for path in paths:
            if path.is_file() and path not in self.logs:
                self.logs[path] = CodexLog(path)
        # Keep the long-lived monitor bounded as new chats arrive.
        self.logs = {p: log for p, log in self.logs.items() if p in paths}
        self.last_discovery = now

    def snapshot(self):
        now = time.time()
        processes = process_table()
        if now - self.last_discovery >= 8:
            self.discover(processes, now)
        tasks, completions, uncertain = [], [], 0
        for path, log in self.logs.items():
            try:
                log.poll()
                completions.extend(e for e in log.completions if 0 <= now - e["at"] < 60)
                if log.state in {"running", "waiting"}:
                    pid = self.open.get(path)
                    if pid and alive(pid, processes) and not self.discovery_error:
                        tasks.append(log.task(pid))
                    elif now - log.last_event < 300:
                        uncertain += 1
            except (OSError, ValueError):
                self.discovery_error = True
        codex = {"agent": "Codex", "status": "degraded" if self.discovery_error or uncertain else "ready",
                 "detail": "部分会话状态未确认" if self.discovery_error or uncertain else "读取任务开始与结束事件"}
        pi_tasks, pi = read_pi(self.state_dir, self.home, processes, now, completions)
        hermes_tasks, hermes = read_hermes(self.home, processes, now, self.state_dir)
        current_hermes = {t["id"]: (t, processes[t["pid"]]["start"]) for t in hermes_tasks}
        if hermes["status"] == "ready" and 0 < now - self.last_snapshot < 15:
            for key, (old, identity) in self.previous_hermes.items():
                # Lease removal while its owner lives is an observed turn end. Expiry/death/read errors are not completion.
                if key not in current_hermes and old.get("leaseExpires", 0) > now and alive(old["pid"], processes, identity):
                    completions.append({"id": f"{key}:{old['started']}", "agent": "Hermes", "label": old["label"], "at": now})
        self.previous_hermes = current_hermes
        self.last_snapshot = now
        tasks += pi_tasks + hermes_tasks
        deepseek_tasks, deepseek, deepseek_completions = self.deepseek.snapshot(processes, now)
        tasks += deepseek_tasks
        completions += deepseek_completions
        tasks.sort(key=lambda t: (t["agent"], t["started"], t["id"]))
        return {"schema": 1, "updated": now, "tasks": tasks, "completions": completions, "adapters": [codex, pi, hermes, deepseek]}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    collector = Collector()
    while True:
        try:
            snap = collector.snapshot()
        except Exception:
            snap = {"schema": 1, "updated": time.time(), "tasks": [],
                    "adapters": [{"agent": n, "status": "degraded", "detail": "状态采集暂时不可用"}
                                 for n in ["Codex", "Pi", "Hermes", "DeepSeek"]]}
        try:
            print(json.dumps(snap, ensure_ascii=False), flush=True)
        except BrokenPipeError:
            return
        if args.once:
            return
        # Exit if the GUI is gone even if no next pipe write has happened yet.
        if os.getppid() == 1:
            return
        time.sleep(2)


if __name__ == "__main__":
    main()
