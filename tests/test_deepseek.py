import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("deepseek_collector", Path(__file__).parents[1] / "Resources/collector.py")
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)
ZSTD = shutil.which("zstd") or next((p for p in ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd"] if Path(p).is_file()), None)


def header():
    return {"type": "session", "version": 4, "id": "session-fixture", "cwd": "/tmp/sample-project"}


def event(kind, turn=1, at=1792404000000, **data):
    return {"type": kind, "seq": 1, "time": at, "data": {"turn": turn, **data}}


def rows(*events):
    return b"".join((json.dumps(e) + "\n").encode() for e in events)


class DeepSeekTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        self.folder = self.home / ".dsh/sessions/project/session-fixture"
        self.folder.mkdir(parents=True)
        self.path = self.folder / "session.v4.jsonl"
        self.path.write_bytes(rows(header()))
        self.log = c.DeepSeekLog(self.path)
        self.pid = 51
        self.processes = {51: {"name": "/Applications/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness",
                               "start": "Mon Oct 19 01:00:00 2026", "parent": 1}}
        self.now = 1792404001

    def tearDown(self): self.temp.cleanup()

    def append(self, *events):
        with self.path.open("ab") as f: f.write(rows(*events))

    def adapter(self):
        result = c.DeepSeekAdapter(self.home)
        with patch.object(c, "deepseek_owners", return_value={self.folder: self.pid}):
            result.snapshot(self.processes, self.now)
        return result

    def test_idle_open_session_is_not_a_task(self):
        self.assertEqual(self.adapter().snapshot(self.processes, self.now)[0], [])

    def test_active_turn_is_reported_until_its_matching_end(self):
        self.append(event("turn/start"))
        adapter = self.adapter()
        self.assertEqual(adapter.snapshot(self.processes, self.now)[0][0]["agent"], "DeepSeek")
        self.append(event("turn/end", turn=0, reason={"kind": "completed"}))
        self.assertEqual(len(adapter.snapshot(self.processes, self.now)[0]), 1)
        self.append(event("turn/end", reason={"kind": "completed"}))
        tasks, _, done = adapter.snapshot(self.processes, self.now)
        self.assertEqual(tasks, [])
        self.assertEqual(len(done), 1)

    def test_approval_waits_only_for_unanswered_request(self):
        self.append(event("turn/start"), event("approval/asked", id="question-a", reason="private"))
        self.log.poll(None)
        self.assertEqual(self.log.state, "waiting")
        self.append(event("approval/decided", id="another-question")); self.log.poll(None)
        self.assertEqual(self.log.state, "waiting")
        self.append(event("approval/decided", id="question-a")); self.log.poll(None)
        self.assertEqual(self.log.state, "running")

    def test_aborted_and_interrupted_turns_do_not_emit_completion_sound(self):
        for reason in ["aborted", "interrupted", "error", "blocked"]:
            log = c.DeepSeekLog(self.path)
            for e in [header(), event("turn/start"), event("turn/end", reason={"kind": reason})]: log.consume(e)
            self.assertEqual(log.state, "idle")
            self.assertEqual(log.completions, [])

    def test_dead_owner_is_not_a_running_task(self):
        self.append(event("turn/start")); adapter = self.adapter()
        self.assertEqual(adapter.snapshot({}, self.now)[0], [])

    def test_old_orphaned_turn_is_not_reused_by_new_process(self):
        self.append(event("turn/start", at=1000))
        tasks, status, _ = self.adapter().snapshot(self.processes, self.now)
        self.assertEqual(tasks, [])
        self.assertEqual(status["status"], "degraded")

    def test_unterminated_plain_row_is_consumed_after_newline(self):
        line = json.dumps(event("turn/start")).encode()
        with self.path.open("ab") as f: f.write(line)
        self.log.poll(None); self.assertEqual(self.log.state, "idle")
        with self.path.open("ab") as f: f.write(b"\n")
        self.log.poll(None); self.assertEqual(self.log.state, "running")

    def test_unsupported_new_generation_never_falls_back_to_old_active_file(self):
        self.append(event("turn/start")); adapter = self.adapter()
        (self.folder / "session.v5.jsonl").write_bytes(rows(header()))
        tasks, status, _ = adapter.snapshot(self.processes, self.now)
        self.assertEqual(tasks, [])
        self.assertEqual(status["status"], "degraded")

    def test_only_metadata_is_exposed_and_files_are_read_only(self):
        self.append(event("turn/start"), event("tool/call", arguments={"secret": "DO_NOT_STORE"}))
        before = self.path.read_bytes(); self.log.poll(None)
        self.assertEqual(self.path.read_bytes(), before)
        self.assertNotIn("DO_NOT_STORE", json.dumps(self.log.task(self.pid)))

    @unittest.skipUnless(ZSTD, "zstd decoder unavailable")
    def test_compressed_append_is_incremental_and_partial_frame_is_not_committed(self):
        compressed = self.folder / "session.v4.jsonl.zstd"
        compressed.write_bytes(subprocess.check_output([ZSTD, "-q", "-c"], input=rows(header(), event("turn/start"))))
        log = c.DeepSeekLog(compressed); log.poll(ZSTD)
        self.assertEqual(log.offset, compressed.stat().st_size)
        frame = subprocess.check_output([ZSTD, "-q", "-c"], input=rows(event("turn/end", reason={"kind": "completed"})))
        cut = len(frame) // 2
        with compressed.open("ab") as f: f.write(frame[:cut])
        with self.assertRaises(ValueError): log.poll(ZSTD)
        self.assertEqual(log.state, "running")
        with compressed.open("ab") as f: f.write(frame[cut:])
        log.poll(ZSTD)
        self.assertEqual(log.state, "idle")
        self.assertEqual(len(log.completions), 1)
        offset = log.offset; log.poll(ZSTD); self.assertEqual(log.offset, offset)

    def test_missing_decoder_is_an_explicit_error(self):
        path = self.folder / "session.v4.jsonl.zstd"; path.write_bytes(b"compressed")
        with self.assertRaisesRegex(ValueError, "zstd"): c.DeepSeekLog(path).poll(None)

    @unittest.skipUnless(shutil.which("node"), "Node is needed for owner-discovery fixture")
    def test_real_process_holding_a_session_is_discovered_without_starting_an_agent(self):
        script = "const fs=require('fs');fs.openSync(process.argv[1]+'/session.lock','w');console.log('ready');setInterval(()=>{},1000);"
        process = subprocess.Popen(["node", "-e", script, str(self.folder)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            self.assertEqual(process.stdout.readline().strip(), "ready")
            self.append(event("turn/start", at=int(time.time() * 1000)))
            adapter = c.DeepSeekAdapter(self.home)
            processes = c.process_table()
            tasks, status, _ = adapter.snapshot({process.pid: processes[process.pid]}, time.time())
            self.assertEqual(len(tasks), 1)
            self.assertEqual(tasks[0]["label"], "sample-project")
            self.assertEqual(status["status"], "ready")
        finally:
            process.terminate(); process.communicate(timeout=5)


if __name__ == "__main__": unittest.main()
