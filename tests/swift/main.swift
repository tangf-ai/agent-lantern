import Foundation
import CoreGraphics

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

check(AnimationTempo.resolve(running: 0, recentActivities: 100) == .calm, "Waiting/ended tasks cannot speed up the scene")
check(AnimationTempo.resolve(running: 2, recentActivities: 0) == .active, "Two running tasks should gently raise tempo")
check(AnimationTempo.resolve(running: 3, recentActivities: 0) == .busy, "Several running tasks should look busier")
check(AnimationTempo.resolve(running: 6, recentActivities: 0) == .intense, "Many running tasks must use the bounded top level")
var activity = AnimationActivityWindow()
let a = AnimationActivity(task: "a", event: "response-a")
let b = AnimationActivity(task: "b", event: "response-a")
check(activity.update(running: ["a", "b"], observed: [a], at: 100) == 0, "Startup history must not manufacture a burst")
check(activity.update(running: ["a", "b"], observed: [a, b], at: 101) == 1, "Distinct task identity must be retained")
check(activity.update(running: ["a", "b"], observed: [a, b], at: 102) == 1, "Repeated snapshots must not increase activity")
let waitingEvent = AnimationActivity(task: "waiting", event: "old")
check(activity.update(running: ["a", "b"], observed: [waitingEvent], at: 103) == 1, "Waiting events must be excluded")
check(activity.update(running: ["a", "b", "waiting"], observed: [waitingEvent], at: 104) == 1, "Resuming must not replay waiting history")
check(activity.update(running: ["a"], observed: [], at: 105) == 0, "Finished task activity must be removed")
let burst = Set((0..<10).map { AnimationActivity(task: "a", event: "fresh-\($0)") })
check(activity.update(running: ["a"], observed: burst, at: 106) == 10, "New activity should survive same-batch bursts")
check(AnimationTempo.resolve(running: 1, recentActivities: 10) == .intense, "A single busy task can raise the visual tempo")
check(activity.update(running: ["a"], observed: [], at: 117) == 0, "Quiet time must decay the activity window")
check(activity.update(running: ["a"], observed: burst, at: 140) == 0, "Reconnect history must seed silently")
check(activity.update(running: ["a"], observed: [], at: .nan) == 0, "Invalid timing cannot create activity")
let rawBurst = (0..<10).map { FlowTransfer(id: "raw-\($0)", kind: "response", at: 101 + Double($0) / 5) }
let untrustedBurst = rawBurst + [FlowTransfer(id: "heartbeat", kind: "heartbeat", at: 103), FlowTransfer(id: "future", kind: "response", at: 200)]
let validBurst = untrustedBurst.filter { $0.isRecent(started: 90, now: 103) }
var burstActivity = AnimationActivityWindow(), burstPlayback = TransferPlaybackGate()
_ = burstActivity.update(running: ["a"], observed: [], at: 100)
_ = burstPlayback.consume([TransferBatch(task: "a", started: 90, events: [])], at: 100)
let visibleBurst = burstPlayback.consume([TransferBatch(task: "a", started: 90, events: untrustedBurst)], at: 103)
check(visibleBurst["a"]?.count == 1, "Visual playback should still coalesce a burst")
check(burstActivity.update(running: ["a"], observed: Set(validBurst.map { AnimationActivity(task: "a", event: $0.id) }), at: 103) == 10,
      "Busy detection must count valid observations before playback coalescing and reject fake/future activity")
var normal = WindMotion(), loaded = WindMotion()
normal.resume(at: 0); loaded.resume(at: 0)
for i in 1...240 {
    normal.advance(at: Double(i) / 30, mood: .working)
    loaded.advance(at: Double(i) / 30, mood: .working, tempo: .intense)
}
check(loaded.speed > normal.speed * 2 && loaded.tempoRate <= 2.2, "Busy rotation should accelerate within its ceiling")
check(loaded.meteorTime > normal.meteorTime * 1.4 && loaded.meteorTime <= normal.meteorTime * 1.65, "Meteor movement must use a smaller bounded acceleration")
check(loaded.auroraTime > normal.auroraTime && loaded.auroraTime <= normal.auroraTime * 1.18, "Aurora must stay gentle")
check(loaded.breeze == normal.breeze, "More activity must not increase the base render cadence")
let beforeTempoChange = loaded
loaded.advance(at: 8, mood: .working, tempo: .calm)
check(loaded.angle == beforeTempoChange.angle && loaded.meteorTime == beforeTempoChange.meteorTime && loaded.auroraTime == beforeTempoChange.auroraTime, "Changing level must not teleport any scene")
loaded.pause();let pausedMeteor = loaded.meteorTime
loaded.advance(at: 200, mood: .working, tempo: .intense)
check(loaded.meteorTime == pausedMeteor, "Paused busy scenes must remain static")
loaded.resume(at: 300);loaded.advance(at: 300, mood: .working, tempo: .intense)
check(loaded.meteorTime == pausedMeteor, "Resume must preserve accumulated animation position")
for i in 1...240 { loaded.advance(at: 300 + Double(i) / 30, mood: .waiting, tempo: .intense) }
check(loaded.tempoRate < 1.003 && loaded.speed < 0.35, "Waiting must override a previous busy level and ease down")
print("Adaptive tempo: startup/reconnect silence, deduplication, waiting exclusion, bursts, decay, bounded rates, fixed cadence and continuous pause/resume: PASS")

check(FlowPhase.unknown.allowsMechanismMotion && !FlowPhase.unknown.showsModelPrinciple,
      "An unconfirmed running task may show standby motion but not model computation")
check(!FlowPhase.waiting.allowsMechanismMotion && !FlowPhase.ended.allowsMechanismMotion,
      "Waiting and ended cards must freeze both side mechanisms")
check(FlowPhase.response.showsAgentPrinciple && !FlowPhase.response.showsModelPrinciple,
      "A completed response may be organized, but must not simulate more model generation")
var pose = MechanismMotion()
check(pose.time(at: 100) == 0, "An unconfigured scene must remain static")
pose.configure(source: 100, enabled: true)
check(pose.time(at: 102) == 2, "Side poses should follow the shared integrated clock")
pose.configure(source: 102, enabled: false)
check(pose.time(at: 202) == 2, "A waiting task must freeze even when other tasks keep the shared clock moving")
pose.configure(source: 202, enabled: true)
check(pose.time(at: 202) == 2 && pose.time(at: 203) == 3,
      "Resuming must preserve the card pose without replaying time spent waiting")
pose.configure(source: 203, enabled: true)
check(pose.time(at: 204) == 4, "Repeated configuration must not restart the cycle")
pose.configure(source: .nan, enabled: false)
check(pose.time(at: 204) == 4, "Invalid clock input must not corrupt the pose")
var sideNormal = WindMotion(), sideBusy = WindMotion()
sideNormal.resume(at: 0); sideBusy.resume(at: 0)
for i in 1...240 {
    sideNormal.advance(at: Double(i) / 30, mood: .working)
    sideBusy.advance(at: Double(i) / 30, mood: .working, tempo: .intense)
}
check(sideBusy.mechanismTime > sideNormal.mechanismTime * 1.3 && sideBusy.mechanismTime <= sideNormal.mechanismTime * 1.6,
      "Side mechanisms must accelerate smoothly within their own ceiling")
sideBusy.pause(); let frozenSide = sideBusy.mechanismTime
sideBusy.advance(at: 500, mood: .working, tempo: .intense)
check(sideBusy.mechanismTime == frozenSide, "Hidden/reduced-motion scenes must not advance")
sideBusy.resume(at: 600); sideBusy.advance(at: 600, mood: .working, tempo: .intense)
check(sideBusy.mechanismTime == frozenSide, "Resuming must preserve the integrated side clock")
print("Side mechanisms: observed role guards, standby, per-task waiting, pause/resume, repeated configuration and bounded adaptive motion: PASS")

var backdrop = WindMotion()
backdrop.resume(at: 0)
var foregroundWraps = 0, backgroundWraps = 0
for i in 1...1800 {
    let old = backdrop.angle, oldBackdrop = backdrop.backdropAngle
    backdrop.advance(at: Double(i) / 30, mood: .working, tempo: .intense)
    if backdrop.angle < old { foregroundWraps += 1 }
    if backdrop.backdropAngle < oldBackdrop { backgroundWraps += 1 }
    let delta = (backdrop.backdropAngle - oldBackdrop + .pi * 2).truncatingRemainder(dividingBy: .pi * 2)
    check(abs(delta - backdrop.speed / 60) < 0.000001,
          "Background rotation must remain continuous through foreground and background wrap boundaries")
}
check(foregroundWraps > backgroundWraps && backgroundWraps > 2,
      "A large background rotor must turn at half the foreground speed without jumping")
backdrop.pause(); let backgroundPause = backdrop.backdropAngle
backdrop.advance(at: 300, mood: .working)
backdrop.resume(at: 400); backdrop.advance(at: 400, mood: .working)
check(backdrop.backdropAngle == backgroundPause, "Background hide/reduce-motion and resume must preserve its angle")
print("Background rotor: gentle speed, continuous independent wraps, pause and no resume fast-forward: PASS")

let primaryScreen = CGRect(x: 0, y: 81, width: 1920, height: 969)
let secondaryScreen = CGRect(x: -1080, y: -401, width: 1080, height: 1920)
let savedSecondary = CGRect(x: -389, y: 1340, width: 334, height: 149)
check(WindowPlacement.visibleFrame(savedSecondary, screens: [primaryScreen, secondaryScreen], fallbackIndex: 0) == savedSecondary,
      "A saved position on a connected secondary screen must remain unchanged")
let lostAbove = CGRect(x: 8, y: 2147, width: 334, height: 377)
let restored = WindowPlacement.visibleFrame(lostAbove, screens: [primaryScreen, secondaryScreen], fallbackIndex: 0)
check(restored.maxY == primaryScreen.maxY - 8 && restored.minX == 8,
      "An off-screen window above all displays must return inside the primary screen")
let disconnected = WindowPlacement.visibleFrame(savedSecondary, screens: [primaryScreen], fallbackIndex: 0)
check(disconnected.minX == 8 && disconnected.maxY == primaryScreen.maxY - 8,
      "Disconnecting a secondary display must recover both horizontal and vertical position")
let partial = CGRect(x: 1900, y: 900, width: 334, height: 377)
let clamped = WindowPlacement.visibleFrame(partial, screens: [primaryScreen], fallbackIndex: 0)
check(clamped.maxX == primaryScreen.maxX - 8 && clamped.maxY == primaryScreen.maxY - 8,
      "A partially visible window must fit within all screen edges")
let tooTall = WindowPlacement.visibleFrame(CGRect(x: 100, y: 100, width: 334, height: 1200),
                                           screens: [primaryScreen], fallbackIndex: 0)
check(tooTall.maxY == primaryScreen.maxY - 8, "An oversized window must keep its top controls visible")
check(WindowPlacement.visibleFrame(lostAbove, screens: [], fallbackIndex: 0) == lostAbove,
      "A temporary absence of screens must not invent a new position")
print("Window placement: off-screen recovery, secondary display, disconnected display, edge clamping and tall panel: PASS")
