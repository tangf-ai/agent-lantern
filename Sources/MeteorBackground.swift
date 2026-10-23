import SwiftUI

/// Decorative sky only. Uses the visible wind clock, never task or token timings.
struct MeteorBackgroundView: View {
    @ObservedObject var clock: WindClock
    var palette: Palette
    var moving: Bool
    var strength: Double
    @State private var consumer = UUID()

    var body: some View {
        Canvas { context, size in
            let opacity = min(1, max(0.65, 0.5 + strength))
            for (x, y, warm) in [(0.18, 0.18, false), (0.79, 0.27, false),
                                  (0.12, 0.65, true), (0.87, 0.79, false)] {
                let point = CGPoint(x: size.width * x, y: size.height * y)
                let star = Path(ellipseIn: CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2))
                context.fill(star, with: .color((warm ? palette.warning : palette.accent).opacity(0.35 * opacity)))
            }
            if moving {
                let time = clock.motion.breeze
                let specs = [(-15.0, -62.0, 110.0, 2.5, 6.8, 1.8),
                             (-88.0, 40.0, 92.0, 2.0, 8.8, 4.5),
                             (-90.0, 160.0, 125.0, 2.0, 10.8, 8.0)]
                for (x, y, tail, width, period, offset) in specs {
                    let u = ((time + offset) / period).truncatingRemainder(dividingBy: 1)
                    let fade = min(1, u / 0.09, (1 - u) / 0.22) * 0.9 * opacity
                    let head = CGPoint(x: x + (size.width + 226) * u, y: y + 298 * u)
                    let end = CGPoint(x: head.x - tail * cos(.pi * 28 / 180),
                                      y: head.y - tail * sin(.pi * 28 / 180))
                    var path = Path()
                    path.move(to: end); path.addLine(to: head)
                    context.stroke(path, with: .linearGradient(Gradient(colors: [palette.accent.opacity(0),
                        palette.accent.opacity(fade * 0.55), palette.accent.opacity(fade)]),
                        startPoint: end, endPoint: head), style: StrokeStyle(lineWidth: width, lineCap: .round))
                    let halo = Path(ellipseIn: CGRect(x: head.x - 12, y: head.y - 12, width: 24, height: 24))
                    context.fill(halo, with: .radialGradient(Gradient(colors: [palette.accent.opacity(fade * 0.32),
                        palette.accent.opacity(0)]), center: head, startRadius: 0, endRadius: 12))
                    let core = Path(ellipseIn: CGRect(x: head.x - 2.3, y: head.y - 2.3, width: 4.6, height: 4.6))
                    context.fill(core, with: .color(Color.white.opacity(fade)))
                    context.stroke(core, with: .color(palette.accent.opacity(fade)), lineWidth: 1)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { clock.appear(consumer) }
        .onDisappear { clock.disappear(consumer) }
    }
}
