import Foundation

struct TaskCompletion: Codable, Equatable {
    var id: String
    var agent: String
    var label: String
    var at: Double
}

/// Sound and visuals share one freshness decision, independent of either preference.
struct CompletionGate {
    private var previousUpdate: Double?
    private var seen: [String: Double] = [:]

    mutating func consume(_ events: [TaskCompletion], at update: Double, allowSound: Bool) -> Bool {
        !consumeFresh(events, at: update, enabled: allowSound).isEmpty
    }

    mutating func consumeFresh(_ events: [TaskCompletion], at update: Double, enabled: Bool) -> [TaskCompletion] {
        guard update.isFinite else { previousUpdate = nil; return [] }
        let previous = previousUpdate
        previousUpdate = update
        let connected = previous.map { update >= $0 && update - $0 <= 15 } ?? false
        var fresh: [TaskCompletion] = []
        for event in events where event.at.isFinite {
            if seen[event.id] == nil && connected && enabled,
               let previous, event.at > previous, event.at <= update + 1, update - event.at < 15 {
                fresh.append(event)
            }
            seen[event.id] = event.at
        }
        seen = seen.filter { update - $0.value < 120 }
        return fresh
    }
}
