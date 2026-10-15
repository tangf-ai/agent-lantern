#!/usr/bin/env python3
"""Local, read-only adapters. Never emit prompts, responses, credentials or tool input."""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import signal
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


def process_table():
    out = subprocess.run(["/bin/ps", "-axo", "pid=,ppid=,lstart=,comm="],
                         capture_output=True, text=True, timeout=4, check=True).stdout
    result = {}
    for line in out.splitlines():
        parts = line.strip().split(None, 7)
        if len(parts) == 8:
            result[int(parts[0])] = {"parent": int(parts[1]), "start": " ".join(parts[2:7]),
                                     "name": parts[7]}
    return result


def alive(pid, processes, fingerprint=None):
    row = processes.get(int(pid or 0))
    return bool(row and (not fingerprint or row["start"] == fingerprint))


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
            self.last_event = max(at, self.last_event)
        if kind == "response_item" and self.state != "idle":
            typ = payload.get("type")
            name = payload.get("name", "")
            call = payload.get("call_id")
            if typ in {"function_call", "custom_tool_call"} and name.split(".")[-1] == "request_user_input":
                if call:
                    self.pending.add(call)
            elif typ in {"function_call_output", "custom_tool_call_output"}:
                self.pending.discard(call)
            self.state = "waiting" if self.pending else "running"

    def task(self, pid):
        return {"id": "codex:" + self.session, "agent": "Codex", "label": self.project,
                "state": self.state, "started": self.started, "pid": pid,
                "evidence": "任务生命周期事件"}


def read_hermes(home, processes, now):
    tasks, problems, capable = [], [], False
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
                                      "pid": pid, "evidence": "网关实时任务计数"})
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
                              "pid": d.get("pid"), "evidence": "Pi 生命周期扩展"})
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
        hermes_tasks, hermes = read_hermes(self.home, processes, now)
        current_hermes = {t["id"]: (t, processes[t["pid"]]["start"]) for t in hermes_tasks}
        if hermes["status"] == "ready" and 0 < now - self.last_snapshot < 15:
            for key, (old, identity) in self.previous_hermes.items():
                # Lease removal while its owner lives is an observed turn end. Expiry/death/read errors are not completion.
                if key not in current_hermes and old.get("leaseExpires", 0) > now and alive(old["pid"], processes, identity):
                    completions.append({"id": f"{key}:{old['started']}", "agent": "Hermes", "label": old["label"], "at": now})
        self.previous_hermes = current_hermes
        self.last_snapshot = now
        tasks += pi_tasks + hermes_tasks
        tasks.sort(key=lambda t: (t["agent"], t["started"], t["id"]))
        return {"schema": 1, "updated": now, "tasks": tasks, "completions": completions, "adapters": [codex, pi, hermes]}


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
                                 for n in ["Codex", "Pi", "Hermes"]]}
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
