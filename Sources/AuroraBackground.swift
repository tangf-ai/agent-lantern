import SwiftUI

/// Natural-looking decorative light curtains. No model or meteor events enter the scene.
struct AuroraBackgroundView: View {
    @ObservedObject var clock: WindClock
    var palette: Palette
    var strength: Double
    var landscape: Bool
    @State private var consumer = UUID()

    var body: some View {
        // Keep the 30 fps shared clock; only repaint the slow light curtains at 12 fps.
        // Pause the existing phase, rather than replacing it with a different static scene.
        AuroraFrame(palette: palette, time: floor(clock.motion.breeze * 12) / 12,
                    strength: strength, landscape: landscape)
            .equatable()
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0),
                                        .init(color: .black, location: 0.14),
                                        .init(color: .black, location: 1)], startPoint: .top, endPoint: .bottom))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear { clock.appear(consumer) }
            .onDisappear { clock.disappear(consumer) }
    }
}

private struct AuroraFrame: View, Equatable {
    var palette: Palette
    var time: Double
    var strength: Double
    var landscape: Bool

    var body: some View {
        Canvas { context, size in
            AuroraScene(palette: palette, time: time, strength: strength, landscape: landscape)
                .draw(context, size: size)
        }
    }
}

private struct AuroraScene {
    var palette: Palette
    var time: Double
    var strength: Double
    var landscape: Bool
    private var green: Color { palette.isDark ? Color(red: 0.545, green: 0.875, blue: 0.651) : Color(red: 0.388, green: 0.714, blue: 0.573) }
    private var cyan: Color { palette.isDark ? Color(red: 0.475, green: 0.733, blue: 0.800) : Color(red: 0.416, green: 0.616, blue: 0.706) }
    private var purple: Color { palette.isDark ? Color(red: 0.663, green: 0.518, blue: 0.686) : Color(red: 0.627, green: 0.537, blue: 0.694) }

    func draw(_ context: GraphicsContext, size: CGSize) {
        let w = Double(size.width), h = Double(size.height)
        let power = sqrt(min(0.7, max(0.15, strength))) * (palette.isDark ? 0.95 : 0.55)
        if palette.isDark {
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                Gradient(colors: [Color(red: 0.06, green: 0.10, blue: 0.16), palette.background]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
        }
        for i in 0..<27 {
            let x = w * hash(Double(i + 1)), y = h * (0.05 + 0.72 * hash(Double(i + 71)))
            let r = 0.35 + 0.7 * hash(Double(i + 131))
            let star = Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            context.fill(star, with: .color((palette.isDark ? Color.white : palette.accent)
                .opacity((palette.isDark ? 0.18 : 0.09) + 0.2 * hash(Double(i + 191)))))
        }
        for layer in 0..<2 {
            let base = h * (0.43 + Double(layer) * 0.22)
            func point(_ u: Double) -> (x: Double, y: Double, height: Double, lean: Double) {
                let field = naturalField(u, time, Double(layer) * 2.4)
                return (w * (-0.08 + 1.16 * u + 0.045 * sin(u * 16 + time * 0.06 + Double(layer))),
                        base + h * 0.095 * sin(u * 5.3 + time * 0.08 + Double(layer) * 2) + h * 0.033 * field,
                        h * 0.23 * (0.72 + 0.28 * sin(.pi * u)) * (1 + 0.18 * naturalField(u, time + 4, Double(layer + 3))),
                        w * 0.045 * sin(u * 6.3 + time * 0.035 + Double(layer)))
            }
            var upper: [CGPoint] = [], lower: [CGPoint] = []
            for i in 0...90 {
                let p = point(Double(i) / 90)
                upper.append(CGPoint(x: p.x + p.lean, y: p.y - p.height))
                lower.append(CGPoint(x: p.x, y: p.y + 6))
            }
            var wash = context
            wash.opacity = power * 0.35
            wash.addFilter(.blur(radius: 4))
            wash.fill(polygon(upper + lower.reversed()), with: .linearGradient(Gradient(stops: [
                .init(color: .clear, location: 0), .init(color: purple, location: 0.28),
                .init(color: green, location: 0.70), .init(color: .clear, location: 1)]),
                startPoint: CGPoint(x: 0, y: base - h * 0.35), endPoint: CGPoint(x: 0, y: base + h * 0.12)))
            for i in 0..<180 {
                let u = (Double(i) + 0.5) / 180, p = point(u)
                let folded = 0.5 + 0.5 * sin(u * 37 + sin(u * 9 + time * 0.1) * 2.8 + time * 0.13 + Double(layer))
                let rayWidth = w / 180 * (0.5 + folded * 1.1), top = p.y - p.height
                let ray = polygon([CGPoint(x: p.x + p.lean, y: top),
                    CGPoint(x: p.x + p.lean + rayWidth * 0.35, y: top),
                    CGPoint(x: p.x + rayWidth, y: p.y + 6), CGPoint(x: p.x, y: p.y + 6)])
                var beam = context
                beam.opacity = power * (0.2 + 0.6 * pow(folded, 2.2))
                beam.fill(ray, with: .linearGradient(Gradient(stops: [
                    .init(color: .clear, location: 0), .init(color: purple, location: 0.25),
                    .init(color: cyan, location: 0.56), .init(color: green, location: 0.84),
                    .init(color: green, location: 0.95), .init(color: .clear, location: 1)]),
                    startPoint: CGPoint(x: p.x + p.lean, y: top), endPoint: CGPoint(x: p.x, y: p.y + 6)))
            }
        }
        if landscape {
            let far = palette.isDark ? Color(red: 0.149, green: 0.231, blue: 0.278) : Color(red: 0.820, green: 0.878, blue: 0.863)
            let near = palette.isDark ? Color(red: 0.078, green: 0.145, blue: 0.192) : Color(red: 0.757, green: 0.831, blue: 0.808)
            context.fill(polygon([(0.0, 0.91), (0.10, 0.87), (0.20, 0.89), (0.31, 0.82),
                (0.43, 0.88), (0.52, 0.84), (0.65, 0.90), (0.79, 0.83), (0.90, 0.88),
                (1, 0.85), (1, 1), (0, 1)].map { CGPoint(x: $0.0 * w, y: $0.1 * h) }), with: .color(far.opacity(0.72)))
            context.fill(polygon([(0.0, 0.95), (0.13, 0.93), (0.26, 0.96), (0.40, 0.90),
                (0.55, 0.94), (0.71, 0.91), (0.86, 0.95), (1, 0.92), (1, 1), (0, 1)]
                .map { CGPoint(x: $0.0 * w, y: $0.1 * h) }), with: .color(near.opacity(0.88)))
        }
    }
    private func naturalField(_ u: Double, _ t: Double, _ seed: Double) -> Double {
        0.55 * sin(u * 7.3 + t * 0.11 + seed) + 0.28 * sin(u * 17.1 - t * 0.07 + seed * 2) +
        0.17 * sin(u * 41.2 + t * 0.10 + seed * 3)
    }
    private func hash(_ n: Double) -> Double {
        let value = sin(n * 127.1 + 43.7) * 43758.5453
        return value - floor(value)
    }
    private func polygon(_ points: [CGPoint]) -> Path {
        var path = Path(); path.addLines(points); path.closeSubpath(); return path
    }
}
