import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("collector", Path(__file__).parents[1] / "Resources/collector.py")
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)


class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)
        self.path = self.home / "rollout-example.jsonl"
        self.path.touch()
        self.log = c.CodexLog(self.path)

    def tearDown(self):
        self.tmp.cleanup()

    def event(self, typ, turn="a", at="2026-10-15T01:00:00Z"):
        return {"type": "event_msg", "timestamp": at, "payload": {"type": typ, "turn_id": turn}}

    def test_completion_of_old_turn_cannot_end_new_turn(self):
        for e in [self.event("task_started", "a"), self.event("task_started", "b"), self.event("task_complete", "a")]:
            self.log.consume(e)
        self.assertEqual(self.log.state, "running")
        self.log.consume(self.event("task_complete", "b"))
        self.assertEqual(self.log.state, "idle")

    def test_long_silent_run_is_not_expired(self):
        self.path.write_text(json.dumps(self.event("task_started")) + "\n")
        self.log.poll()
        self.log.poll()
        self.assertEqual(self.log.state, "running")

    def test_partial_line_is_consumed_only_after_newline(self):
        line = json.dumps(self.event("task_started")).encode()
        self.path.write_bytes(line[:30])
        self.log.poll()
        self.assertEqual(self.log.offset, 0)
        with self.path.open("ab") as f: f.write(line[30:] + b"\n")
        self.log.poll()
        self.assertEqual(self.log.state, "running")

    def test_abort_stops_task(self):
        self.log.consume(self.event("task_started"))
        self.log.consume(self.event("turn_aborted"))
        self.assertEqual(self.log.state, "idle")
        self.assertEqual(self.log.completions, [])

    def test_completion_retains_unique_turn_and_no_conversation_content(self):
        self.log.consume(self.event("task_started"))
        done = self.event("task_complete")
        done["payload"]["last_agent_message"] = "private answer must never be emitted"
        self.log.consume(done)
        self.assertEqual(len(self.log.completions), 1)
        self.assertTrue(self.log.completions[0]["id"].endswith(":a"))
        self.assertNotIn("private answer", json.dumps(self.log.completions))
        self.log.consume(self.event("task_started", "b"))
        self.log.consume(self.event("task_complete", "b"))
        self.assertNotEqual(self.log.completions[0]["id"], self.log.completions[1]["id"])

    def test_explicit_question_waits_until_matching_answer(self):
        self.log.consume(self.event("task_started"))
        self.log.consume({"type": "response_item", "payload": {
            "type": "custom_tool_call", "name": "functions.request_user_input", "call_id": "input1"}})
        self.assertEqual(self.log.state, "waiting")
        self.log.consume({"type": "response_item", "payload": {
            "type": "custom_tool_call_output", "call_id": "other"}})
        self.assertEqual(self.log.state, "waiting")
        self.log.consume({"type": "response_item", "payload": {
            "type": "custom_tool_call_output", "call_id": "input1"}})
        self.assertEqual(self.log.state, "running")

    def test_log_truncation_drops_old_active_state(self):
        self.path.write_text(json.dumps(self.event("task_started")) + "\n")
        self.log.poll()
        self.path.write_text("")
        self.log.poll()
        self.assertEqual(self.log.state, "idle")


class AdaptersTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)
        self.root = self.home / ".hermes"
        self.root.mkdir()
        self.db = sqlite3.connect(self.root / "state.db")
        self.db.execute("create table session_turn_leases (conversation_id text, holder text, acquired_at real, expires_at real)")
        self.db.commit()
        self.processes = {44: {"name": "/test/hermes/python3", "start": "same", "parent": 1}}

    def tearDown(self):
        self.db.close()
        self.tmp.cleanup()

    def lease(self, sid="s", pid=44, expires=1200):
        self.db.execute("insert into session_turn_leases values (?, ?, ?, ?)",
                        (sid, f"pid={pid}:turn=abc:platform=desktop", 900, expires))
        self.db.commit()

    def test_idle_open_hermes_surface_is_not_work(self):
        runtime = self.root / "runtime"
        runtime.mkdir()
        (runtime / "active_sessions.json").write_text(json.dumps({"entries": [{"pid": 44}]}))
        tasks, _ = c.read_hermes(self.home, self.processes, 1000)
        self.assertEqual(tasks, [])

    def test_hermes_live_lease_is_work(self):
        self.lease()
        tasks, _ = c.read_hermes(self.home, self.processes, 1000)
        self.assertEqual(len(tasks), 1)
        self.assertEqual(tasks[0]["started"], 900)

    def test_expired_and_dead_owner_are_not_work(self):
        self.lease("expired", expires=999)
        self.lease("dead", pid=55)
        tasks, _ = c.read_hermes(self.home, self.processes, 1000)
        self.assertEqual(tasks, [])

    def test_gateway_count_does_not_double_count_leases(self):
        self.lease()
        (self.root / "gateway_state.json").write_text(json.dumps({
            "pid": 44, "gateway_state": "running", "active_agents": 2, "updated_at": 1000}))
        tasks, _ = c.read_hermes(self.home, self.processes, 1000)
        self.assertEqual(len(tasks), 2)

    def test_pi_pid_reuse_and_missing_heartbeat_are_rejected(self):
        state = self.home / "state"
        (state / "pi").mkdir(parents=True)
        file = state / "pi/44.json"
        record = {"schema": 1, "pid": 44, "processStart": "different", "state": "running", "updated": 1000}
        file.write_text(json.dumps(record))
        self.assertEqual(c.read_pi(state, self.home, self.processes, 1000)[0], [])
        record.update(processStart="same", updated=970)
        file.write_text(json.dumps(record))
        self.assertEqual(c.read_pi(state, self.home, self.processes, 1000)[0], [])
        record.update(updated=1000)
        file.write_text(json.dumps(record))
        self.assertEqual(len(c.read_pi(state, self.home, self.processes, 1000)[0]), 1)

    def test_read_only_monitor_does_not_change_database(self):
        self.lease()
        before = (self.root / "state.db").read_bytes()
        c.read_hermes(self.home, self.processes, 1000)
        self.assertEqual(before, (self.root / "state.db").read_bytes())

    def test_hermes_lease_release_emits_one_completion(self):
        self.lease()
        monitor = c.Collector(self.home, self.home / "state")
        with patch.object(c, "process_table", return_value=self.processes), patch.object(c, "open_rollouts", return_value={}):
            with patch.object(c.time, "time", return_value=1000):
                self.assertEqual(monitor.snapshot()["completions"], [])
            self.db.execute("delete from session_turn_leases")
            self.db.commit()
            with patch.object(c.time, "time", return_value=1002):
                self.assertEqual(len(monitor.snapshot()["completions"]), 1)
            with patch.object(c.time, "time", return_value=1004):
                self.assertEqual(monitor.snapshot()["completions"], [])

    def test_hermes_expiry_or_process_death_does_not_ring(self):
        for reason in ["expiry", "death"]:
            self.db.execute("delete from session_turn_leases")
            self.lease(expires=1001 if reason == "expiry" else 1200)
            monitor = c.Collector(self.home, self.home / "state")
            with patch.object(c, "process_table", return_value=self.processes), patch.object(c, "open_rollouts", return_value={}):
                with patch.object(c.time, "time", return_value=1000): monitor.snapshot()
                current = {} if reason == "death" else self.processes
                with patch.object(c, "process_table", return_value=current), patch.object(c.time, "time", return_value=1002):
                    self.assertEqual(monitor.snapshot()["completions"], [], reason)


if __name__ == "__main__":
    unittest.main()
