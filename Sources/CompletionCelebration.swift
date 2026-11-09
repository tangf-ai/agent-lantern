import Foundation
import CoreGraphics

struct CelebrationBurst: Equatable {
    var launch: Double
    var x: Double
    var y: Double
    var scale: Double
    var color: Int
}

/// A single bounded show. Further completions update it instead of restarting or queuing shows.
struct CompletionCelebration: Equatable {
    static let singleDuration = 6.0
    static let finaleDuration = 8.0
    static let maximumDuration = 10.0
    static let particleLifetime = 4.8
    let began: Double
    private(set) var duration: Double
    private(set) var bursts: [CelebrationBurst]
    private(set) var completedCount: Int
    private(set) var agent: String
    private(set) var label: String
    private(set) var remaining: Int
    private(set) var waiting: Int
    private(set) var allEnded: Bool
    private var finaleAdded: Bool
    let demo: Bool

    init?(events: [TaskCompletion], remaining: Int, waiting: Int, allEnded: Bool, at time: Double, demo: Bool = false) {
        guard let last = events.last, time.isFinite else { return nil }
        began = time
        duration = allEnded ? Self.finaleDuration : Self.singleDuration
        bursts = Self.opening(allEnded: allEnded)
        completedCount = events.count
        agent = last.agent
        label = last.label
        self.remaining = max(0, remaining)
        self.waiting = min(max(0, waiting), max(0, remaining))
        self.allEnded = allEnded
        finaleAdded = allEnded
        self.demo = demo
    }

    func isActive(at time: Double) -> Bool { time.isFinite && time >= began && time - began < duration }

    mutating func merge(events: [TaskCompletion], remaining: Int, waiting: Int, allEnded: Bool, at time: Double) {
        guard isActive(at: time), let last = events.last else { return }
        completedCount += events.count
        agent = last.agent
        label = last.label
        self.remaining = max(0, remaining)
        self.waiting = min(max(0, waiting), self.remaining)
        if allEnded && !finaleAdded {
            let age = time - began
            // Upgrade once and leave time for the slower embers, within a bounded total show.
            bursts += Self.opening(allEnded: true).dropFirst(2).map {
                var burst = $0; burst.launch = age + 0.1 + (burst.launch - 1.2) * 0.6; return burst
            }
            duration = min(Self.maximumDuration, max(Self.finaleDuration, age + 6.4))
            finaleAdded = true
        }
        self.allEnded = allEnded
    }

    mutating func updateRemaining(_ remaining: Int, waiting: Int, allEnded: Bool) {
        self.remaining = max(0, remaining)
        self.waiting = min(max(0, waiting), self.remaining)
        // Only a fresh completion can declare the finale; disappearance alone cannot promote it.
        self.allEnded = self.allEnded && allEnded
    }

    var title: String {
        let prefix = demo ? "示例 · " : ""
        if allEnded { return prefix + "本轮任务已结束" }
        return prefix + (completedCount == 1 ? "\(agent) · 本次运行已结束" : "\(completedCount) 个任务已结束")
    }
    var subtitle: String {
        if allEnded { return "可以去看看它们的成果了" }
        if remaining == 0 { return "其他接入状态尚未确认" }
        if waiting > 0 { return "还有 \(remaining) 个任务 · \(waiting) 个等你确认" }
        return "还有 \(remaining) 个任务进行中"
    }
    private static func opening(allEnded: Bool) -> [CelebrationBurst] {
        if !allEnded {
            return [CelebrationBurst(launch: 0.28, x: 0.69, y: 0.39, scale: 0.70, color: 0),
                    CelebrationBurst(launch: 0.76, x: 0.44, y: 0.31, scale: 0.75, color: 1)]
        }
        return [CelebrationBurst(launch: 0.30, x: 0.30, y: 0.27, scale: 1.00, color: 0),
                CelebrationBurst(launch: 0.80, x: 0.63, y: 0.22, scale: 0.80, color: 1),
                CelebrationBurst(launch: 1.20, x: 0.46, y: 0.42, scale: 0.90, color: 2),
                CelebrationBurst(launch: 1.65, x: 0.78, y: 0.31, scale: 0.70, color: 3),
                CelebrationBurst(launch: 2.05, x: 0.21, y: 0.47, scale: 0.65, color: 0),
                CelebrationBurst(launch: 2.60, x: 0.53, y: 0.25, scale: 1.05, color: 0)]
    }

    static func source(lightCenter: CGPoint, screen: CGRect) -> CGPoint {
        CGPoint(x: min(max(0, lightCenter.x - screen.minX), screen.width),
                y: min(max(0, screen.maxY - lightCenter.y), screen.height))
    }
    static func toastCenter(source: CGPoint, size: CGSize, width: CGFloat) -> CGPoint {
        let half = min(width, max(0, size.width - 24)) / 2
        let x = min(max(half + 12, source.x), max(half + 12, size.width - half - 12))
        let y = source.y > 145 ? source.y - 85 : source.y + 85
        return CGPoint(x: x, y: min(max(52, y), max(52, size.height - 52)))
    }
}
