import Foundation

struct TaskCompletion: Codable, Equatable {
    var id: String
    var agent: String
    var label: String
    var at: Double
}

struct CompletionDecision {
    var agent: String
    var age: Double
    var reason: String
}

/// Sound and visuals share one freshness decision, independent of either preference.
struct CompletionGate {
    private var previousUpdate: Double?
    private var connectionBegan: Double?
    private var seen: [String: Double] = [:]
    private(set) var decisions: [CompletionDecision] = []

    mutating func consume(_ events: [TaskCompletion], at update: Double, allowSound: Bool) -> Bool {
        !consumeFresh(events, at: update, enabled: allowSound).isEmpty
    }

    mutating func consumeFresh(_ events: [TaskCompletion], at update: Double, enabled: Bool) -> [TaskCompletion] {
        decisions = []
        guard update.isFinite else { previousUpdate = nil; connectionBegan = nil; return [] }
        let previous = previousUpdate
        previousUpdate = update
        let connected = previous.map { update >= $0 && update - $0 <= 15 } ?? false
        if !connected { connectionBegan = update }
        var fresh: [TaskCompletion] = []
        for event in events where event.at.isFinite {
            if seen[event.id] == nil {
                let reason: String
                if !connected { reason = "startup-or-reconnect" }
                else if !enabled { reason = "preview-or-disabled" }
                else if event.at <= (connectionBegan ?? update) { reason = "before-connection" }
                else if event.at > update + 1 { reason = "future-clock" }
                else if update - event.at >= 15 { reason = "expired" }
                else { reason = "fresh"; fresh.append(event) }
                decisions.append(CompletionDecision(agent: event.agent, age: update - event.at, reason: reason))
            }
            seen[event.id] = event.at
        }
        seen = seen.filter { update - $0.value < 120 }
        return fresh
    }
}
