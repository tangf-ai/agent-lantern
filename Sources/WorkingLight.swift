import SwiftUI
import Foundation

enum ActivityPhase: String {
    case working, waiting, completed, idle, connecting
}

/// A small native vector animation. The timeline stops when hidden, disabled, idle or reduced-motion is requested.
struct WorkingLight: View {
    var color: Color
    var warning: Color
    var phase: ActivityPhase
    var hasWaiting: Bool
    var animationsEnabled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phaseStarted = Date()
    @State private var completionLive = false

    private var moving: Bool {
        animationsEnabled && !reduceMotion &&
            (phase == .working || phase == .waiting || (phase == .completed && completionLive))
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !moving)) { timeline in
            Canvas { context, size in
                let elapsed = max(0, timeline.date.timeIntervalSince(phaseStarted))
                draw(context, size: size, elapsed: moving ? elapsed : 0,
                     completionAge: phase == .completed && !moving ? 2 : elapsed)
            }
        }
        .frame(width: 48, height: 48)
        .task(id: phase) {
            phaseStarted = Date()
            completionLive = phase == .completed
            if completionLive {
                try? await Task.sleep(for: .seconds(1.2))
                if !Task.isCancelled { completionLive = false }
            }
        }
        .accessibilityHidden(true)
    }

    private func draw(_ context: GraphicsContext, size: CGSize, elapsed t: Double, completionAge: Double) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let pulse = (sin(t * 2.7) + 1) / 2
        func circle(_ radius: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        }
        func point(_ angle: Double, _ radius: Double) -> CGPoint {
            let radians = angle * .pi / 180
            return CGPoint(x: center.x + cos(radians) * radius, y: center.y + sin(radians) * radius)
        }
        func arc(_ radius: CGFloat, _ start: Double, _ length: Double) -> Path {
            var path = Path()
            path.addArc(center: center, radius: radius, startAngle: .degrees(start),
                        endAngle: .degrees(start + length), clockwise: false)
            return path
        }

        context.fill(circle(23), with: .radialGradient(Gradient(colors: [color.opacity(0.12), color.opacity(0.015)]),
            center: center, startRadius: 2, endRadius: 24))
        context.stroke(circle(20), with: .color(color.opacity(0.14)), lineWidth: 0.7)

        if phase == .working {
            let rotation = t * 65 - 90
            context.stroke(arc(20, rotation, 110), with: .conicGradient(
                Gradient(colors: [color.opacity(0.08), color.opacity(0.95), color.opacity(0.08)]),
                center: center, angle: .degrees(rotation)), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            context.stroke(arc(14.5, -t * 43 + 95, 76), with: .color(color.opacity(0.48)),
                style: StrokeStyle(lineWidth: 1, lineCap: .round))
            context.stroke(arc(14.5, -t * 43 + 245, 35), with: .color(color.opacity(0.25)),
                style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
            for (angle, radius, opacity) in [(rotation + 110, 1.9, 1.0), (rotation + 265, 1.25, 0.55)] {
                let dot = point(angle, 20)
                var glow = context
                glow.addFilter(.shadow(color: color.opacity(0.55), radius: 3))
                glow.fill(Path(ellipseIn: CGRect(x: dot.x - radius, y: dot.y - radius,
                    width: radius * 2, height: radius * 2)), with: .color(color.opacity(opacity)))
            }
        } else if phase == .waiting {
            context.stroke(circle(17), with: .color(color.opacity(0.3 + pulse * 0.35)),
                style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [1, 4.4]))
            context.stroke(circle(12 + pulse * 7), with: .color(color.opacity(0.22 * (1 - pulse))), lineWidth: 1)
        } else if phase == .completed {
            let progress = min(1, completionAge / 1.1)
            context.stroke(circle(12 + progress * 11), with: .color(color.opacity(0.7 * (1 - progress))), lineWidth: 1.3)
            for i in 0..<6 where progress < 1 {
                let p = point(Double(i) * 60 - 90, 15 + progress * 9)
                context.fill(Path(ellipseIn: CGRect(x: p.x - 1, y: p.y - 1, width: 2, height: 2)),
                    with: .color(color.opacity(1 - progress)))
            }
        } else if phase == .connecting {
            context.stroke(circle(17), with: .color(color.opacity(0.28)),
                style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1, 5]))
        }

        let symbol: String
        switch phase {
        case .working: symbol = "sparkle"
        case .waiting: symbol = "hourglass"
        case .completed: symbol = "checkmark"
        case .idle: symbol = "moon"
        case .connecting: symbol = "questionmark"
        }
        var core = context
        core.translateBy(x: center.x, y: center.y)
        let scale = phase == .working ? 0.94 + pulse * 0.12 : 1
        core.scaleBy(x: scale, y: scale)
        if phase == .working {
            core.addFilter(.shadow(color: color.opacity(0.18 + pulse * 0.20), radius: 3 + pulse * 2))
        }
        core.draw(Text(Image(systemName: symbol)).font(.system(size: 18, weight: .medium))
            .foregroundColor(color), at: .zero, anchor: .center)
        if hasWaiting && phase == .working {
            let p = point(42, 20)
            context.fill(Path(ellipseIn: CGRect(x: p.x - 3.2, y: p.y - 3.2, width: 6.4, height: 6.4)),
                         with: .color(warning))
        }
    }
}

struct WorkingSignal: View {
    var color: Color
    var animationsEnabled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let moving = animationsEnabled && !reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: !moving)) { timeline in
            Canvas { context, size in
                let t = moving ? timeline.date.timeIntervalSinceReferenceDate : 0
                for index in 0..<3 {
                    let level = moving ? (sin(t * 4.2 - Double(index) * 1.35) + 1) / 2 : 0.5
                    let height = 3 + level * 8
                    let rect = CGRect(x: Double(index) * 5.5, y: (size.height - height) / 2,
                                      width: 2.3, height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: 1.2), with: .color(color.opacity(0.55 + level * 0.4)))
                }
            }
        }.frame(width: 14, height: 13).accessibilityHidden(true)
    }
}
