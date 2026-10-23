import Foundation

struct FlowTransfer: Codable, Equatable {
    var id: String
    var kind: String
    var at: Double

    func isRecent(started: Double, now: Double) -> Bool {
        !id.isEmpty && id.count <= 200 && ["request", "response", "context"].contains(kind) &&
            at.isFinite && at >= started && at <= now && now - at <= 8
    }
}

struct TransferPulse: Codable, Equatable {
    var id: String
    var kind: String
    var began: Double
    var duration: Double { kind == "response" ? 2.5 : FlowPhase.sendingDuration }
    var title: String {
        switch kind {
        case "request": return "近期请求发起"
        case "response": return "近期响应到达"
        default: return "结果回填示意 · 非网络发送遥测"
        }
    }
    func active(at now: Double) -> Bool { began <= now && now < began + duration }
}

struct TransferBatch {
    var task: String
    var started: Double
    var events: [FlowTransfer]
}

/// A shared, bounded queue keeps short transfers visible across collector batches
/// and view switches. Startup/reconnect seeds history silently, just like completion sounds.
struct TransferPlaybackGate {
    private var seeded = false
    private var seen: [String: Double] = [:]
    private var queues: [String: [TransferPulse]] = [:]

    mutating func consume(_ batches: [TransferBatch], at now: Double) -> [String: [TransferPulse]] {
        guard now.isFinite else { return [:] }
        func ordered(_ lhs: FlowTransfer, _ rhs: FlowTransfer) -> Bool {
            if lhs.at != rhs.at { return lhs.at < rhs.at }
            let rank = ["request": 0, "response": 1, "context": 2]
            if rank[lhs.kind] != rank[rhs.kind] { return rank[lhs.kind, default: 3] < rank[rhs.kind, default: 3] }
            return lhs.id < rhs.id
        }
        let activeTasks = Set(batches.map { $0.task })
        queues = queues.filter { activeTasks.contains($0.key) }
        for key in Array(queues.keys) {
            queues[key] = queues[key]?.filter { now < $0.began + $0.duration }
        }
        seen = seen.filter { now - $0.value <= 60 }
        for batch in batches {
            let fresh = batch.events.filter { $0.isRecent(started: batch.started, now: now) }.sorted(by: ordered)
            var latest: [String: FlowTransfer] = [:]
            for event in fresh {
                let key = batch.task + ":" + event.id
                if seen[key] == nil { latest[event.kind] = event }
                seen[key] = now
            }
            guard seeded else { continue }
            if let request = latest["request"], let context = latest["context"],
               request.at >= context.at, request.at - context.at < 2.5 {
                latest["context"] = nil
            }
            for event in latest.values.sorted(by: ordered) {
                let queue = queues[batch.task] ?? []
                let began = max(now, queue.last.map { $0.began + $0.duration } ?? now)
                guard queue.count < 4, began - now <= 3.6 else { continue }
                queues[batch.task, default: []].append(TransferPulse(id: event.id, kind: event.kind, began: began))
            }
        }
        seeded = true
        if seen.count > 1024 {
            seen = Dictionary(uniqueKeysWithValues: seen.sorted { $0.value > $1.value }.prefix(1024).map { ($0.key, $0.value) })
        }
        return queues
    }
}
