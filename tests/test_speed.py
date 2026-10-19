import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).parents[1]
spec = importlib.util.spec_from_file_location("speed_collector", ROOT / "Resources/collector.py")
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)
plugin_spec = importlib.util.spec_from_file_location("hermes_metrics", ROOT / "Resources/hermes-metrics/__init__.py")
plugin = importlib.util.module_from_spec(plugin_spec)
plugin_spec.loader.exec_module(plugin)


class SpeedTests(unittest.TestCase):
    def metrics(self):
        return {"version": 1, "phase": "generating",
                "live": {"startCount": 10, "endCount": 70, "elapsedMs": 2000, "at": 1000},
                "recent": {"outputTokens": 600, "durationMs": 20000, "at": 990}}

    def test_live_uses_delta_counter_and_sampling_duration(self):
        result = c.read_speed(self.metrics(), 1001)
        self.assertEqual(result["status"], "live")
        self.assertEqual(result["value"], 30)

    def test_stalled_stream_falls_back_to_labeled_recent_mean(self):
        result = c.read_speed(self.metrics(), 1004)
        self.assertEqual(result["status"], "recent")
        self.assertEqual(result["value"], 30)
        self.assertEqual(result["durationMs"], 20000)

    def test_tools_and_waiting_never_display_old_counter_as_live(self):
        data = self.metrics()
        data["phase"] = "tools"
        self.assertEqual(c.read_speed(data, 1001)["status"], "recent")
        self.assertEqual(c.read_speed(self.metrics(), 1001, "waiting")["status"], "recent")

    def test_new_task_rejects_previous_task_mean(self):
        data = self.metrics(); data.pop("live")
        self.assertEqual(c.read_speed(data, 1001, not_before=995)["status"], "sampling")

    def test_missing_extension_and_missing_usage_are_distinct(self):
        self.assertEqual(c.read_speed(None, 1001)["status"], "reload")
        self.assertEqual(c.read_speed({"version": 1, "phase": "generating"}, 1001)["status"], "sampling")

    def test_bad_samples_cannot_produce_speed(self):
        for value in [float("nan"), float("inf"), -1, True, "120"]:
            data = {"version": 1, "recent": {"outputTokens": value, "durationMs": 1000, "at": 1000}}
            self.assertNotIn("value", c.read_speed(data, 1001))
        for duration in [0, float("nan"), -1]:
            data = {"version": 1, "recent": {"outputTokens": 10, "durationMs": duration, "at": 1000}}
            self.assertNotIn("value", c.read_speed(data, 1001))

    def test_future_and_expired_samples_are_not_current(self):
        data = self.metrics(); data.pop("live")
        self.assertNotIn("value", c.read_speed(data, 980))
        self.assertNotIn("value", c.read_speed(data, 1300))

    def test_codex_does_not_guess_speed_from_whole_task_time(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "codex.jsonl"; path.touch()
            log = c.CodexLog(path)
            log.consume({"type": "token_usage_record", "timestamp": "2026-10-15T00:00:00Z",
                         "payload": {"usage": {"output_tokens": 1000}}})
            self.assertEqual(log.task(1)["speed"]["status"], "unavailable")
            self.assertNotIn("value", log.task(1)["speed"])


class HermesMetricsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name)
        self.hooks = {}
        class Context:
            def register_hook(inner, name, handler): self.hooks[name] = handler
        self.env = patch.dict(plugin.os.environ, {"AGENT_LANTERN_STATE_DIR": str(self.path)})
        self.env.start()
        with patch.object(plugin.subprocess, "check_output", return_value="Thu Oct 15 19:00:00 2026"):
            plugin.register(Context())

    def tearDown(self):
        self.env.stop()
        self.temp.cleanup()

    def test_actual_hook_fields_become_response_mean_without_private_content(self):
        with patch.object(plugin.time, "time", return_value=1000):
            result = self.hooks["post_api_request"](session_id="session-a", usage={"output_tokens": 200, "reasoning_tokens": 80},
                api_duration=4, assistant_message="DO_NOT_STORE", response={"secret": "DO_NOT_STORE"}, finish_reason="tool_calls")
        self.assertIsNone(result)
        files = list((self.path / "hermes").glob("*.json"))
        self.assertEqual(len(files), 1)
        self.assertNotIn("DO_NOT_STORE", files[0].read_text())
        data = json.loads(files[0].read_text()); pid = data["pid"]
        processes = {pid: {"start": "Thu 15 Oct 19:00:00 2026"}}
        speed = c.hermes_speed(self.path, pid, "session-a", 900, processes, 1001)
        self.assertEqual(speed["status"], "recent")
        self.assertEqual(speed["value"], 50)
        self.assertEqual(c.hermes_speed(self.path, pid, "session-b", 900, processes, 1001)["status"], "unavailable")
        processes[pid]["start"] = "Thu Oct 15 19:00:01 2026"
        self.assertEqual(c.hermes_speed(self.path, pid, "session-a", 900, processes, 1001)["status"], "unavailable")

    def test_missing_usage_duration_or_failed_request_produces_no_measurement(self):
        for values in [{"usage": {}}, {"usage": {"output_tokens": 10}, "api_duration": 0},
                       {"usage": {"output_tokens": 10}, "api_duration": 1, "finish_reason": "error"}]:
            self.hooks["post_api_request"](session_id="session-a", **values)
        self.assertEqual(list((self.path / "hermes").glob("*.json")), [])


if __name__ == "__main__":
    unittest.main()
