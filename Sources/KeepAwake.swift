import Foundation
import IOKit.pwr_mgt

enum KeepAwakePolicy {
    static let freshness: TimeInterval = 15

    static func shouldPreventSleep(enabled: Bool, running: Int, monitorHealthy: Bool,
                                   isPreview: Bool, snapshotUpdated: Double?,
                                   lastReceived: Date, now: Date = Date()) -> Bool {
        guard enabled, running > 0, monitorHealthy, !isPreview,
              let updated = snapshotUpdated, updated.isFinite else { return false }
        let age = now.timeIntervalSince(lastReceived)
        // Check both delivery and collection time: replaying an old snapshot must
        // not hold the computer awake, including after wake or leaving preview.
        return age >= 0 && age <= freshness && abs(now.timeIntervalSince1970 - updated) <= freshness
    }
}

protocol SleepAssertionManaging {
    func create() -> (IOReturn, IOPMAssertionID)
    func release(_ id: IOPMAssertionID) -> IOReturn
}

struct SystemSleepAssertionManager: SleepAssertionManaging {
    static let assertionName = "Agent Lantern: running agent tasks"

    func create() -> (IOReturn, IOPMAssertionID) {
        var id: IOPMAssertionID = 0
        // Allow display sleep and screen locking. This assertion only prevents
        // automatic idle system sleep; explicit sleep and lid policy still apply.
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), Self.assertionName as CFString, &id)
        return (result, id)
    }

    func release(_ id: IOPMAssertionID) -> IOReturn {
        IOPMAssertionRelease(id)
    }
}

/// Owned by Model and used on the main thread, independently of window visibility.
final class KeepAwakeController {
    private let manager: SleepAssertionManaging
    private var assertionID: IOPMAssertionID?
    private var retryAfter: TimeInterval = 0
    private(set) var lastError: IOReturn?
    var isActive: Bool { assertionID != nil }

    init(manager: SleepAssertionManaging = SystemSleepAssertionManager()) {
        self.manager = manager
    }

    func update(shouldPreventSleep: Bool, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if !shouldPreventSleep && assertionID == nil {
            lastError = nil
            retryAfter = 0
            return
        }
        guard now >= retryAfter else { return }
        if shouldPreventSleep {
            guard assertionID == nil else {
                lastError = nil
                retryAfter = 0
                return
            }
            let (result, id) = manager.create()
            if result == kIOReturnSuccess {
                assertionID = id
                lastError = nil
                retryAfter = 0
            } else {
                lastError = result
                retryAfter = now + 10
            }
        } else if let id = assertionID {
            let result = manager.release(id)
            if result == kIOReturnSuccess {
                assertionID = nil
                lastError = nil
                retryAfter = 0
            } else {
                lastError = result
                retryAfter = now + 10
            }
        }
    }

    func stop() {
        // Bypass retry throttling on exit. macOS also removes process-owned
        // assertions automatically if the app is killed or crashes.
        retryAfter = 0
        update(shouldPreventSleep: false)
    }

    deinit { stop() }
}
