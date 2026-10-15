import Foundation

func event(_ id: String, _ at: Double) -> TaskCompletion {
    TaskCompletion(id: id, agent: "Codex", label: "example", at: at)
}
func check(_ condition: Bool, _ label: String) {
    guard condition else { fatalError(label) }
}
var gate = CompletionGate()
check(!gate.consume([event("history", 99)], at: 100, allowSound: true), "Startup must be silent")
check(gate.consume([event("new", 101)], at: 102, allowSound: true), "A fresh individual completion must ring")
check(!gate.consume([event("new", 101)], at: 104, allowSound: true), "Duplicate must be silent")
check(!gate.consume([event("muted", 105)], at: 106, allowSound: false), "Mute must silence completion")
check(!gate.consume([event("muted", 105)], at: 108, allowSound: true), "Unmuting must not replay")
check(!gate.consume([event("preview", 109)], at: 110, allowSound: false), "Preview must be silent")
check(!gate.consume([event("preview", 109)], at: 112, allowSound: true), "Leaving preview must not replay")
check(!gate.consume([event("disconnected", 140)], at: 150, allowSound: true), "Reconnect must seed silently")
check(gate.consume([event("afterReconnect", 151)], at: 152, allowSound: true), "Fresh event after reconnect must ring")
check(!gate.consume([event("lateHistory", 90)], at: 154, allowSound: true), "Old discovered log must not ring")
check(!gate.consume([event("future", 200)], at: 156, allowSound: true), "Bad future clock must not ring")
check(gate.consume([event("a", 157), event("b", 157.5)], at: 158, allowSound: true), "Batch should produce one sound")
print("Completion sound: startup, individual completion, deduplication, mute, preview, reconnect, late history and batching: PASS")
