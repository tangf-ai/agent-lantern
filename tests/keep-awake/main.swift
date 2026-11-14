import Foundation
import IOKit.pwr_mgt

var checks = 0
func check(_ condition: Bool, _ label: String) {
    guard condition else { fatalError(label) }
    checks += 1
}

let base = Date(timeIntervalSince1970: 1000)
func wantsAwake(enabled: Bool = true, running: Int = 1, healthy: Bool = true,
                preview: Bool = false, updated: Double? = 1000, received: Date = base,
                now: Date = base) -> Bool {
    KeepAwakePolicy.shouldPreventSleep(enabled: enabled, running: running, monitorHealthy: healthy,
        isPreview: preview, snapshotUpdated: updated, lastReceived: received, now: now)
}
check(wantsAwake(), "A real running task must prevent idle sleep")
check(wantsAwake(running: 4), "Multiple running tasks share the same protection")
check(!wantsAwake(running: 0), "Idle, all-waiting and completed tasks must allow sleep")
check(!wantsAwake(enabled: false), "The saved off switch must override running tasks")
check(!wantsAwake(healthy: false), "Collector failure must allow sleep even with old tasks")
check(!wantsAwake(preview: true), "Preview and demo tasks must never hold the system awake")
check(!wantsAwake(updated: nil), "No snapshot must allow sleep")
check(!wantsAwake(updated: .nan), "Invalid timestamps must allow sleep")
check(!wantsAwake(updated: .infinity), "Infinite timestamps must allow sleep")
check(!wantsAwake(updated: 984), "A newly delivered stale snapshot must allow sleep")
check(!wantsAwake(updated: 1016), "A future-dated snapshot must allow sleep")
check(!wantsAwake(updated: 1016, now: base.addingTimeInterval(16)), "Stale delivery must expire even if collection time looks fresh")
check(!wantsAwake(received: base.addingTimeInterval(1)), "A clock moving backwards must not hold sleep")
check(wantsAwake(now: base.addingTimeInterval(15)), "The documented freshness boundary is inclusive")
check(!wantsAwake(now: base.addingTimeInterval(15.01)), "A stalled collector must not keep the system awake forever")

final class FakeAssertions: SleepAssertionManaging {
    var creates = 0
    var releases: [IOPMAssertionID] = []
    var createResult = kIOReturnSuccess
    var releaseResult = kIOReturnSuccess
    func create() -> (IOReturn, IOPMAssertionID) {
        creates += 1
        return (createResult, IOPMAssertionID(creates))
    }
    func release(_ id: IOPMAssertionID) -> IOReturn {
        releases.append(id)
        return releaseResult
    }
}
let fake = FakeAssertions()
let controller = KeepAwakeController(manager: fake)
controller.update(shouldPreventSleep: false, now: 0)
check(fake.creates == 0 && fake.releases.isEmpty, "Idle startup must not touch power assertions")
controller.update(shouldPreventSleep: true, now: 1)
check(controller.isActive && fake.creates == 1, "Starting work must acquire one assertion")
for tick in 2...20 { controller.update(shouldPreventSleep: true, now: Double(tick)) }
check(fake.creates == 1, "Polling and task count changes must not leak duplicate assertions")
controller.update(shouldPreventSleep: false, now: 21)
check(!controller.isActive && fake.releases == [1], "The final running task ending must release the assertion")
controller.update(shouldPreventSleep: true, now: 22)
controller.stop()
check(!controller.isActive && fake.releases == [1, 2], "Exiting during work must release protection")
controller.stop()
check(fake.releases == [1, 2], "Stopping twice must not release an assertion twice")
do {
    let disposable = KeepAwakeController(manager: fake)
    disposable.update(shouldPreventSleep: true, now: 23)
}
check(fake.releases == [1, 2, 3], "Deinitialization must clean up the assertion")

let failing = FakeAssertions()
let recovery = KeepAwakeController(manager: failing)
failing.createResult = kIOReturnError
recovery.update(shouldPreventSleep: true, now: 100)
check(!recovery.isActive && recovery.lastError == kIOReturnError, "An OS refusal must never appear as active")
recovery.update(shouldPreventSleep: true, now: 101)
check(failing.creates == 1, "OS failures must have a retry cooldown")
failing.createResult = kIOReturnSuccess
recovery.update(shouldPreventSleep: true, now: 110)
check(recovery.isActive && recovery.lastError == nil, "Protection must recover after an OS failure")
failing.releaseResult = kIOReturnError
recovery.update(shouldPreventSleep: false, now: 111)
check(recovery.isActive && recovery.lastError != nil, "A failed release must retain ownership for retry")
failing.releaseResult = kIOReturnSuccess
recovery.stop()
check(!recovery.isActive && recovery.lastError == nil, "Exit must bypass the release retry cooldown")
failing.createResult = kIOReturnError
recovery.update(shouldPreventSleep: true, now: 200)
recovery.update(shouldPreventSleep: false, now: 201)
check(recovery.lastError == nil, "Switching off must clear a failed acquisition")
failing.createResult = kIOReturnSuccess
recovery.update(shouldPreventSleep: true, now: 202)
check(recovery.isActive, "Turning back on must be able to acquire immediately")
recovery.stop()

// Check the real macOS assertion registry, not just controller bookkeeping.
func ownAssertions() -> [[String: Any]] {
    var assertions: Unmanaged<CFDictionary>?
    let result = IOPMCopyAssertionsByProcess(&assertions)
    check(result == kIOReturnSuccess, "The native assertion registry must be readable")
    let all = assertions?.takeRetainedValue() as? [NSNumber: [[String: Any]]] ?? [:]
    return (all[NSNumber(value: ProcessInfo.processInfo.processIdentifier)] ?? []).filter {
        $0[kIOPMAssertionNameKey] as? String == SystemSleepAssertionManager.assertionName
    }
}
let native = KeepAwakeController()
check(ownAssertions().isEmpty, "No native assertion may exist before work starts")
native.update(shouldPreventSleep: true)
check(native.isActive && native.lastError == nil, "The real OS must accept the idle-sleep assertion")
let active = ownAssertions()
check(active.count == 1, "macOS must record exactly one process-owned assertion")
check(active.first?[kIOPMAssertionTypeKey] as? String == kIOPMAssertionTypePreventUserIdleSystemSleep,
      "Only system idle sleep may be prevented; display sleep must remain allowed")
native.update(shouldPreventSleep: true)
check(ownAssertions().count == 1, "Native polling must not create extra assertions")
native.update(shouldPreventSleep: false)
check(ownAssertions().isEmpty, "macOS must remove the assertion when work ends")
native.update(shouldPreventSleep: true)
native.stop()
check(ownAssertions().isEmpty, "macOS must remove the assertion when the controller stops")
print("Keep awake: \(checks) policy, lifecycle, recovery and real macOS assertion checks: PASS")
