"""Hermes observer: retain only numeric response metrics, never requests or responses."""
from __future__ import annotations
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import threading
import time
import uuid


def metric_name(pid, session_id):
    return f"{pid}-{hashlib.sha256(str(session_id).encode()).hexdigest()[:24]}.json"


def register(ctx):
    directory = Path(os.environ.get("AGENT_LANTERN_STATE_DIR") or
                     Path.home() / "Library/Application Support/AgentLantern") / "hermes"
    pid = os.getpid()
    try:
        identity = subprocess.check_output(["/bin/ps", "-p", str(pid), "-o", "lstart="],
            text=True, timeout=1, env={**os.environ, "LC_ALL": "C", "LANG": "C"}).strip()
    except (OSError, subprocess.SubprocessError):
        return
    lock = threading.Lock()

    def after_request(**kwargs):
        sid, usage, duration = kwargs.get("session_id"), kwargs.get("usage"), kwargs.get("api_duration")
        if not isinstance(sid, str) or not sid or not isinstance(usage, dict) or kwargs.get("finish_reason") in ("error", "aborted"):
            return
        count = usage.get("output_tokens")
        if any(isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v) or v <= 0
               for v in [count, duration]):
            return
        if count > 1e9:
            return
        now = time.time()
        data = {"schema": 1, "pid": pid, "processStart": " ".join(identity.split()), "sessionId": str(sid),
                "updated": now, "metrics": {"version": 1, "phase": "waiting", "updated": now,
                "recent": {"outputTokens": count, "durationMs": duration * 1000, "at": now}}}
        temporary = None
        try:
            with lock:
                directory.mkdir(parents=True, exist_ok=True, mode=0o700)
                target = directory / metric_name(pid, sid)
                temporary = target.with_suffix("." + uuid.uuid4().hex + ".tmp")
                with temporary.open("x") as handle:
                    os.chmod(temporary, 0o600)
                    json.dump(data, handle, allow_nan=False)
                temporary.replace(target)
        except (OSError, ValueError):
            if temporary:
                try: temporary.unlink(missing_ok=True)
                except OSError: pass
        # Observer returns nothing and never changes the model call.

    ctx.register_hook("post_api_request", after_request)
