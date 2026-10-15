import Foundation

struct TaskCompletion: Codable, Equatable {
    var id: String
    var agent: String
    var label: String
    var at: Double
}

/// Only fresh completion events can ring. Startup, reconnection, preview and muted events are consumed silently.
struct CompletionGate {
    private var previousUpdate: Double?
    private var seen: [String: Double] = [:]

    mutating func consume(_ events: [TaskCompletion], at update: Double, allowSound: Bool) -> Bool {
        let previous = previousUpdate
        previousUpdate = update
        let connected = previous.map { update >= $0 && update - $0 <= 15 } ?? false
        var shouldRing = false
        for event in events {
            if seen[event.id] == nil && connected && allowSound,
               let previous, event.at > previous, event.at <= update + 1, update - event.at < 15 {
                shouldRing = true
            }
            seen[event.id] = event.at
        }
        seen = seen.filter { update - $0.value < 120 }
        return shouldRing
    }
}
