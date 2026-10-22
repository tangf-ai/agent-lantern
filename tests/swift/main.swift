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

let stream = MessageFlow(phase: "receiving", at: 100, detail: "test")
check(stream.display(at: 102, waiting: false) == .receiving, "Fresh content can animate inbound")
check(stream.display(at: 104, waiting: false) == .awaiting, "Stalled stream must stop inbound movement")
check(stream.display(at: 102, waiting: true) == .waiting, "Approval always overrides old model activity")
let request = MessageFlow(phase: "request", at: 100, detail: "test")
check(request.display(at: 100.5, waiting: false) == .sending, "Request event shows outbound briefly")
check(request.display(at: 103, waiting: false) == .awaiting, "A pending request must not loop sends")
check(request.display(at: 98, waiting: false) == .unknown, "Future observations cannot imply traffic")
let response = MessageFlow(phase: "response", at: 100, detail: "test")
check(response.display(at: 103, waiting: false) == .recorded, "Historical responses cannot loop inbound")
print("Message flow: stale streams, pending requests, approval, future clocks and historical responses: PASS")

check(FlowPhase.awaiting.showsModelPrinciple, "An outstanding request can show the conceptual model illustration")
check(FlowPhase.receiving.showsModelPrinciple, "Fresh streamed output can show conceptual token generation")
check(!FlowPhase.response.showsModelPrinciple, "A completed response must never imply ongoing model computation")
check(FlowPhase.response.showsInboundFlow, "A recorded response can briefly acknowledge arrival")
for phase in [FlowPhase.unknown, .processing, .waiting, .recorded, .tools] {
    check(!phase.showsModelPrinciple, "Unknown, local, approval and historical phases cannot imply model computation")
}
check(FlowPhase.tools.showsAgentCycle, "Observed tools can animate the local conceptual loop")
check(!FlowPhase.awaiting.showsAgentCycle, "Waiting for a model must not animate a local tool cycle")
check(request.display(at: 102.7, waiting: false) == .sending, "The bounded send effect must fit the collector cadence")
check(request.display(at: 102.8, waiting: false) == .awaiting, "The same request cannot repeat outbound pulses")
print("Mechanism animation: observed phases, completed responses, tools, approval, unknown states and bounded sending: PASS")

var transfers = TransferPlaybackGate()
func batch(_ events: [FlowTransfer], task: String = "codex:example") -> [TransferBatch] {
    [TransferBatch(task: task, started: 100, events: events)]
}
let history = FlowTransfer(id: "history", kind: "response", at: 100)
check(transfers.consume(batch([history]), at: 100).isEmpty, "Startup must not replay transfer history")
let inbound = FlowTransfer(id: "inbound", kind: "response", at: 101)
let context = FlowTransfer(id: "context", kind: "context", at: 101)
let queued = transfers.consume(batch([history, inbound, context]), at: 102)["codex:example"] ?? []
check(queued.map { $0.kind } == ["response", "context"], "A response immediately followed by tools/result must preserve both directions")
check(queued.first?.active(at: 102) == true, "Arrival playback starts when observed, not before collector delivery")
check(queued.last?.began == 104.5, "The context handoff must remain visible after response arrival")
let repeated = transfers.consume(batch([history, inbound, context]), at: 103)["codex:example"] ?? []
check(repeated == queued, "Repeated snapshots or view switches must not replay or reset transfers")
check(transfers.consume(batch([history, inbound, context]), at: 110)["codex:example"]?.isEmpty != false, "Expired transfers must stop")
let stale = FlowTransfer(id: "late-history", kind: "request", at: 101)
check(transfers.consume(batch([stale]), at: 111)["codex:example"]?.isEmpty != false, "Late historical logs must not cause animation")
var newGate = TransferPlaybackGate()
_ = newGate.consume([], at: 100)
let newRequest = FlowTransfer(id: "request", kind: "request", at: 102)
let actual = newGate.consume(batch([FlowTransfer(id: "context2", kind: "context", at: 101), newRequest]), at: 102)["codex:example"] ?? []
check(actual.count == 1 && actual.first?.kind == "request", "A confirmed request supersedes an immediately preceding context illustration")
check(newGate.consume([], at: 104).isEmpty, "Finished tasks must not leave ghost animations")
print("Transfer replay: same-poll overwrite, collector latency, two directions, deduplication, expiry, startup, task removal and request provenance: PASS")

var wind = WindMotion()
let initialAngle = wind.angle
wind.advance(at: 100, mood: .working)
check(wind.angle == initialAngle, "A paused wind scene must not animate")
wind.resume(at: 100)
for i in 1...60 { wind.advance(at: 100 + Double(i) / 30, mood: .working) }
check(wind.angle != initialAngle, "The companion must move even when no communication events arrive")
let beforeWaiting = wind.angle
wind.advance(at: 102, mood: .waiting)
check(wind.angle == beforeWaiting, "Changing mood must not reset or jump the rotor")
for i in 1...90 { wind.advance(at: 102 + Double(i) / 30, mood: .waiting) }
check(wind.speed < 0.36 && wind.speed > 0.33, "Waiting must smoothly slow the turbine")
wind.gust(at: 105)
for i in 1...35 { wind.advance(at: 105 + Double(i) / 30, mood: .waiting) }
check(wind.speed > 0.6, "Clicking the garden should create a temporary gust")
for i in 36...240 { wind.advance(at: 105 + Double(i) / 30, mood: .waiting) }
check(wind.gustAge == nil && wind.speed < 0.36, "A gust must end and return to the waiting rhythm")
wind.pause()
let pausedAngle = wind.angle
wind.gust(at: 300)
wind.advance(at: 301, mood: .working)
check(wind.angle == pausedAngle && wind.gustAge == nil, "Disabled/reduced-motion views must remain static even when clicked")
wind.resume(at: 400)
wind.advance(at: 400, mood: .working)
check(wind.angle == pausedAngle, "Resume must preserve the rotor position")
wind.advance(at: 10000, mood: .working)
check(abs(wind.angle - pausedAngle) < 0.1, "Long gaps must not fast-forward decorative motion")
let finiteAngle = wind.angle
wind.advance(at: .nan, mood: .working)
check(wind.angle == finiteAngle, "Invalid timing must not corrupt geometry")
check(!FlowPhase.ended.showsModelPrinciple && !FlowPhase.ended.showsInboundFlow, "The ended display must not simulate live model traffic")
print("Wind companion: idle communication, smooth waiting, temporary gust, pause, reduced motion, resume and bounded frame gaps: PASS")
