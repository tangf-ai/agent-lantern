"""Protect event fidelity: no model traffic inferred from tools, old turns or TPS."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("flow_collector", Path(__file__).parents[1] / "Resources/collector.py")
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)

class FlowTests(unittest.TestCase):
    def codex_event(self, log, typ, **fields):
        log.consume({"type": "response_item", "timestamp": 1001, "payload": {"type": typ, **fields}})

    def test_parallel_tools_do_not_turn_into_fabricated_model_send(self):
        log = c.CodexLog("unused")
        log.consume({"type": "event_msg", "timestamp": 1000, "payload": {"type": "task_started", "turn_id": "a"}})
        self.assertEqual(log.task(1)["flow"]["phase"], "unknown")
        for call in ["a", "b"]:
            self.codex_event(log, "function_call", call_id=call, name="exec", arguments="DO_NOT_STORE")
        self.codex_event(log, "function_call_output", call_id="a", output="DO_NOT_STORE")
        self.assertEqual(log.task(1)["flow"]["phase"], "tools")
        self.codex_event(log, "function_call_output", call_id="b")
        self.assertEqual(log.task(1)["flow"]["phase"], "processing")
        self.assertEqual({e["kind"] for e in log.task(1)["flow"]["transfers"]}, {"response", "context"},
                         "later tool states must not erase response or context transfers from the same poll")
        self.codex_event(log, "message", role="assistant", content="DO_NOT_STORE")
        self.assertEqual(log.task(1)["flow"]["phase"], "response")
        self.assertNotIn("DO_NOT_STORE", str(log.__dict__))
        log.consume({"type": "event_msg", "timestamp": 1002, "payload": {"type": "task_started", "turn_id": "b"}})
        self.assertEqual(log.task(1)["flow"]["phase"], "unknown")
        self.assertEqual(log.task(1)["flow"]["transfers"], [],
                         "new turns must not inherit old transfer history")

    def test_deepseek_ignores_other_turn_and_unconfirmed_request_header(self):
        log = c.DeepSeekLog("unused")
        log.consume({"type": "session", "version": 4, "id": "example"})
        def event(kind, **data): log.consume({"type": kind, "time": 1000, "data": data})
        event("turn/start", turn=2)
        event("request/header", turn=2)
        self.assertEqual(log.task(1)["flow"]["phase"], "unknown")
        event("tool/call", turn=1, callId="old")
        self.assertEqual(log.task(1)["flow"]["phase"], "unknown")
        event("tool/call", turn=2, callId="a")
        event("tool/call", turn=2, callId="b")
        event("tool/result", turn=2, callId="a")
        self.assertEqual(log.task(1)["flow"]["phase"], "tools")
        event("tool/result", turn=2, callId="b")
        self.assertEqual(log.task(1)["flow"]["phase"], "processing")
        event("assistant/message", turn=2, content="DO_NOT_STORE")
        self.assertEqual(log.task(1)["flow"]["phase"], "response")
        self.assertNotIn("DO_NOT_STORE", str(log.__dict__))

    def test_reasoning_and_immediate_tool_return_preserve_both_directions(self):
        log = c.CodexLog("unused")
        log.consume({"type": "event_msg", "timestamp": 1000, "payload": {"type": "task_started", "turn_id": "a"}})
        self.codex_event(log, "reasoning", summary="DO_NOT_STORE")
        self.codex_event(log, "function_call", call_id="a", name="exec", arguments="DO_NOT_STORE")
        self.codex_event(log, "function_call_output", call_id="a", output="DO_NOT_STORE")
        result = log.task(1)["flow"]
        self.assertEqual(result["phase"], "processing")
        self.assertEqual([e["kind"] for e in result["transfers"]][-2:], ["response", "context"])
        self.assertNotIn("DO_NOT_STORE", str(result))

    def test_transfer_history_is_bounded_and_untrusted_fields_are_filtered(self):
        events = []
        for i in range(100): c.record_transfer(events, "response", 1000 + i, "DO_NOT_STORE")
        self.assertEqual(len(events), 12)
        self.assertNotIn("DO_NOT_STORE", str(events))
        data = [{"id": "ok", "kind": "response", "at": 1001, "detail": "DO_NOT_STORE"},
                {"id": "old", "kind": "response", "at": 999},
                {"id": "future", "kind": "request", "at": 1003},
                {"id": "bad", "kind": "invented", "at": 1001}]
        filtered = c.clean_transfers(data, 1000, 1002)
        self.assertEqual(len(filtered), 1)
        self.assertNotIn("DO_NOT_STORE", str(filtered))

    def test_pi_rejects_previous_turn_future_and_arbitrary_text(self):
        for at in [999, 1002, float("nan")]:
            self.assertEqual(c.pi_flow({"started": 1000, "flow": {"phase": "receiving", "at": at}}, 1001)["phase"], "unknown")
        data = {"started": 1000, "flow": {"phase": "request", "at": 1001, "detail": "DO_NOT_STORE"}}
        self.assertEqual(c.pi_flow(data, 1001)["phase"], "request")
        self.assertNotIn("DO_NOT_STORE", str(c.pi_flow(data, 1001)))
        self.assertEqual(c.pi_flow({"metrics": {"phase": "generating"}}, 1001)["phase"], "unknown")
