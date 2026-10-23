import Foundation

/// Per-card pose on a shared, integrated clock. Pausing one task must not inherit
/// the elapsed time of other running tasks when it resumes.
struct MechanismMotion {
    private var enabled = false
    private var saved = 0.0
    private var origin: Double?

    func time(at source: Double) -> Double {
        guard enabled, source.isFinite, let origin else { return saved }
        return saved + max(0, source - origin)
    }
    mutating func configure(source: Double, enabled: Bool) {
        guard source.isFinite else { return }
        saved = time(at: source)
        origin = source
        self.enabled = enabled
    }
}
