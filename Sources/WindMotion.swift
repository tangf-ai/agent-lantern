import Foundation

enum WindMood {
    case working, waiting, finished
    var speed: Double {
        switch self {
        case .working: return 0.82
        case .waiting: return 0.34
        case .finished: return 0.52
        }
    }
}

/// Decorative motion only; no token counts, task progress or model timings enter this integrator.
struct WindMotion {
    private(set) var angle = -0.25
    private(set) var speed = 0.82
    private(set) var breeze = 0.0
    private(set) var gustAge: Double? = nil
    private var last: Double? = nil
    private var gustStarted: Double? = nil

    mutating func resume(at now: Double) { if now.isFinite { last = now } }
    mutating func pause() { last = nil; gustStarted = nil; gustAge = nil }
    mutating func gust(at now: Double) {
        guard last != nil, now.isFinite else { return }
        gustStarted = now
        gustAge = 0
    }
    mutating func advance(at now: Double, mood: WindMood) {
        guard now.isFinite, let previous = last else { return }
        last = now
        guard now >= previous else { return }
        // Resume and delayed frames never fast-forward the rotor through an invisible interval.
        let dt = min(0.05, now - previous)
        if let started = gustStarted {
            let age = max(0, now - started)
            gustAge = age < 2.8 ? age : nil
            if age >= 2.8 { gustStarted = nil }
        }
        let gust = gustAge.map { sin($0 / 2.8 * .pi) * 0.7 } ?? 0
        let target = mood.speed + gust
        speed += (target - speed) * (1 - exp(-dt * 2))
        angle = (angle + speed * dt).truncatingRemainder(dividingBy: .pi * 2)
        breeze += dt * (mood == .waiting ? 0.6 : 1)
    }
}
