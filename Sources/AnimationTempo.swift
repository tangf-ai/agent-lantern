import Foundation

/// A visual workload cue, never an estimate of CPU load, tokens or completion.
enum AnimationTempo: Int, CaseIterable {
    case calm, active, busy, intense
    static func resolve(running: Int, recentActivities: Int) -> AnimationTempo {
        guard running > 0 else { return .calm }
        if running >= 6 || recentActivities >= 10 { return .intense }
        if running >= 3 || recentActivities >= 5 { return .busy }
        if running >= 2 || recentActivities >= 2 { return .active }
        return .calm
    }
    var title: String { ["平稳", "活跃", "繁忙", "很忙"][rawValue] }
    var wind: Double { [1, 1.3, 1.7, 2.2][rawValue] }
    var meteor: Double { [1, 1.2, 1.4, 1.65][rawValue] }
    var aurora: Double { [1, 1.04, 1.10, 1.18][rawValue] }
    var mechanism: Double { [1, 1.15, 1.35, 1.6][rawValue] }
}

struct AnimationActivity: Hashable {
    var task: String
    var event: String
}

/// Counts first observations in a short window. Repeated snapshots, startup and
/// reconnect history are silent; waiting/ended tasks never contribute activity.
struct AnimationActivityWindow {
    private var seen: [AnimationActivity: Double] = [:]
    private var hits: [AnimationActivity: Double] = [:]
    private var last: Double?

    mutating func update(running: Set<String>, observed: Set<AnimationActivity>, at now: Double) -> Int {
        guard now.isFinite else { return 0 }
        let seed = last.map { now < $0 || now - $0 > 15 } ?? true
        last = now
        if seed { seen.removeAll(); hits.removeAll() }
        seen = seen.filter { now - $0.value <= 60 }
        hits = hits.filter { running.contains($0.key.task) && now >= $0.value && now - $0.value <= 10 }
        for activity in observed where !activity.event.isEmpty && activity.event.count <= 200 {
            if !seed && seen[activity] == nil && running.contains(activity.task) { hits[activity] = now }
            seen[activity] = now
        }
        if seen.count > 1024 {
            seen = Dictionary(uniqueKeysWithValues: seen.sorted { $0.value > $1.value }.prefix(1024).map { ($0.key, $0.value) })
        }
        if hits.count > 1024 {
            hits = Dictionary(uniqueKeysWithValues: hits.sorted { $0.value > $1.value }.prefix(1024).map { ($0.key, $0.value) })
        }
        return hits.count
    }
}
