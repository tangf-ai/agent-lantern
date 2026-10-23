import SwiftUI
import Combine

/// One visible clock for wind gardens and meteors; switching agents preserves motion.
final class WindClock: ObservableObject {
    @Published private(set) var motion = WindMotion()
    @Published private(set) var mood = WindMood.working
    private var requested = false
    private var consumers = Set<UUID>()
    private var timer: Timer?

    func configure(enabled: Bool, phase: ActivityPhase) {
        requested = enabled
        let next: WindMood = phase == .waiting ? .waiting : phase == .completed ? .finished : .working
        if mood != next { mood = next }
        refresh()
    }
    func appear(_ id: UUID) { consumers.insert(id); refresh() }
    func disappear(_ id: UUID) { consumers.remove(id); refresh() }
    func gust() { if timer != nil { motion.gust(at: ProcessInfo.processInfo.systemUptime) } }
    private func refresh() {
        if requested && !consumers.isEmpty {
            guard timer == nil else { return }
            motion.resume(at: ProcessInfo.processInfo.systemUptime)
            let next = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.motion.advance(at: ProcessInfo.processInfo.systemUptime, mood: self.mood)
            }
            timer = next
            RunLoop.main.add(next, forMode: .common)
        } else {
            timer?.invalidate(); timer = nil
            motion.pause()
        }
    }
    deinit { timer?.invalidate() }
}

struct WindGardenView: View {
    @ObservedObject var clock: WindClock
    var palette: Palette
    var side: CGFloat = 96
    @State private var consumer = UUID()

    var body: some View {
        Button { clock.gust() } label: {
            Canvas { context, size in
                var enlarged = context
                enlarged.translateBy(x: size.width / 2, y: size.height / 2)
                enlarged.scaleBy(x: side / 86, y: side / 86)
                WindGardenScene(palette: palette, motion: clock.motion, mood: clock.mood)
                    .draw(enlarged, center: .zero)
            }.frame(width: side, height: 104).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("点风机吹一阵轻风。微风仅作陪伴，转速不代表 TPS 或任务进度；动画关闭或减少动态效果时保持静态。")
        .accessibilityLabel("吹一阵轻风")
        .accessibilityHint("只改变陪伴动效，不影响智能体工作")
        .onAppear { clock.appear(consumer) }
        .onDisappear { clock.disappear(consumer) }
    }
}

private struct WindGardenScene {
    var palette: Palette
    var motion: WindMotion
    var mood: WindMood
    private var green: Color { palette.isDark ? Color(red: 0.51, green: 0.72, blue: 0.59) : Color(red: 0.44, green: 0.66, blue: 0.54) }
    private var tower: Color { palette.isDark ? Color(red: 0.72, green: 0.81, blue: 0.75) : Color(red: 0.86, green: 0.91, blue: 0.88) }
    private var blade: Color { palette.isDark ? Color(red: 0.93, green: 0.96, blue: 0.93) : Color(red: 1, green: 0.995, blue: 0.97) }
    private var edge: Color { palette.isDark ? Color(red: 0.59, green: 0.75, blue: 0.65) : Color(red: 0.36, green: 0.54, blue: 0.43) }

    func draw(_ original: GraphicsContext, center: CGPoint) {
        var context = original
        context.translateBy(x: center.x, y: center.y + 4)
        let t = motion.breeze
        let sway = sin(t * 0.8) * 1.2
        ellipse(context, 0, 36, 19, 2, palette.ink, 0.045)
        glow(context, 0, -15, 39, palette.warning, mood == .finished ? 0.10 : 0.045)
        var hill = Path()
        hill.move(to: CGPoint(x: -40, y: 35))
        hill.addCurve(to: CGPoint(x: 2, y: 32), control1: CGPoint(x: -23, y: 25), control2: CGPoint(x: -13, y: 27))
        hill.addCurve(to: CGPoint(x: 40, y: 35), control1: CGPoint(x: 18, y: 27), control2: CGPoint(x: 29, y: 29))
        hill.addQuadCurve(to: CGPoint(x: -40, y: 35), control: CGPoint(x: 1, y: 43))
        context.fill(hill, with: .color(green.opacity(0.32)))
        for x in [-31.0, -24, 22, 32] {
            var grass = Path()
            grass.move(to: CGPoint(x: x, y: 35))
            grass.addQuadCurve(to: CGPoint(x: x + 2 + sway, y: 26), control: CGPoint(x: x - 1 + sway, y: 29))
            context.stroke(grass, with: .color(green.opacity(0.85)), style: StrokeStyle(lineWidth: 0.9, lineCap: .round))
        }
        for (x, y, scale) in [(-34.0, -29.0, 0.8), (34.0, -22.0, 0.65)] {
            let drift = sin(t * 0.17 + x) * 2
            ellipse(context, x + drift, y, 9 * scale, 2.2 * scale, palette.ink, 0.035)
            ellipse(context, x - 3 * scale + drift, y - 1.7 * scale, 4.5 * scale, 3 * scale, palette.ink, 0.03)
            ellipse(context, x + 2 * scale + drift, y - 2.4 * scale, 3.5 * scale, 3.5 * scale, palette.ink, 0.03)
        }
        for i in 0..<2 {
            let u = (t * 0.11 + Double(i) * 0.45).truncatingRemainder(dividingBy: 1)
            let x = -45 + u * 28, y = -8 + Double(i) * 14
            var breeze = Path()
            breeze.move(to: CGPoint(x: x, y: y))
            breeze.addQuadCurve(to: CGPoint(x: x + 10, y: y), control: CGPoint(x: x + 6, y: y - 0.8))
            context.stroke(breeze, with: .color(green.opacity(sin(u * .pi) * 0.18)), lineWidth: 0.65)
        }
        var mast = Path()
        mast.move(to: CGPoint(x: -1.6, y: -18))
        mast.addLine(to: CGPoint(x: 3.8, y: 34))
        mast.addQuadCurve(to: CGPoint(x: -3.8, y: 34), control: CGPoint(x: 0, y: 36))
        mast.closeSubpath()
        context.fill(mast, with: .color(tower))
        context.stroke(mast, with: .color(edge.opacity(0.85)), lineWidth: 0.8)
        var highlight = Path()
        highlight.addLines([CGPoint(x: -1, y: -18), CGPoint(x: 0, y: 34), CGPoint(x: 2.2, y: 34), CGPoint(x: 0.7, y: -18)])
        highlight.closeSubpath()
        context.fill(highlight, with: .color(blade.opacity(0.75)))
        let nacelle = Path(roundedRect: CGRect(x: -2.5, y: -22, width: 11, height: 7), cornerRadius: 3)
        context.fill(nacelle, with: .color(tower))
        context.stroke(nacelle, with: .color(edge.opacity(0.75)), lineWidth: 0.8)
        for i in 0..<3 {
            var rotor = context
            rotor.translateBy(x: 0, y: -18)
            rotor.rotate(by: .radians(motion.angle + Double(i) * .pi * 2 / 3))
            rotor.scaleBy(x: 1.25, y: 1.28)
            var shape = Path()
            shape.move(to: CGPoint(x: -0.8, y: 1))
            shape.addCurve(to: CGPoint(x: -1.5, y: -18.5), control1: CGPoint(x: -3.2, y: -3), control2: CGPoint(x: -3.1, y: -10))
            shape.addQuadCurve(to: CGPoint(x: 0.2, y: -22.5), control: CGPoint(x: -0.8, y: -22.5))
            shape.addQuadCurve(to: CGPoint(x: 1.45, y: -19), control: CGPoint(x: 1.5, y: -22))
            shape.addCurve(to: CGPoint(x: 1.1, y: 1), control1: CGPoint(x: 1.1, y: -11), control2: CGPoint(x: 3, y: -3))
            shape.closeSubpath()
            rotor.fill(shape, with: .linearGradient(Gradient(colors: [tower, blade, blade]),
                startPoint: CGPoint(x: -3, y: 0), endPoint: CGPoint(x: 3, y: 0)))
            rotor.stroke(shape, with: .color(edge.opacity(0.85)), lineWidth: 0.75)
        }
        ellipse(context, 0, -18, 3.2, 3.2, blade, 1)
        ellipse(context, 0, -18, 1.2, 1.2, edge, 0.75)
        context.fill(Path(roundedRect: CGRect(x: 7, y: 29, width: 8, height: 6), cornerRadius: 1.4), with: .color(tower))
        glow(context, 11, 31.8, 6, palette.warning, 0.12)
        ellipse(context, 11, 31.8, 1, 1, palette.warning, 0.65 + (mood == .working ? sin(t * 1.3) * 0.18 : 0))
        if mood == .working {
            let u = (t * 0.22).truncatingRemainder(dividingBy: 1)
            ellipse(context, 0.1, -13 + u * 43, 0.7, 1.1, palette.warning, sin(u * .pi) * 0.45)
        }
        if let age = motion.gustAge {
            let u = age / 2.8
            for i in 0..<3 {
                let x = -37 + u * 51, y = -4 + Double(i) * 9
                var gust = Path()
                gust.move(to: CGPoint(x: x, y: y))
                gust.addQuadCurve(to: CGPoint(x: x + 20, y: y), control: CGPoint(x: x + 12, y: y - 2.5))
                context.stroke(gust, with: .color(green.opacity(sin(u * .pi) * 0.42 * (1 - Double(i) * 0.12))), lineWidth: 0.8)
            }
        }
    }

    private func ellipse(_ context: GraphicsContext, _ x: Double, _ y: Double, _ rx: Double, _ ry: Double, _ color: Color, _ opacity: Double) {
        context.fill(Path(ellipseIn: CGRect(x: x - rx, y: y - ry, width: rx * 2, height: ry * 2)), with: .color(color.opacity(opacity)))
    }
    private func glow(_ context: GraphicsContext, _ x: Double, _ y: Double, _ radius: Double, _ color: Color, _ opacity: Double) {
        context.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                     with: .radialGradient(Gradient(colors: [color.opacity(opacity), color.opacity(0)]),
                         center: CGPoint(x: x, y: y), startRadius: 0, endRadius: radius))
    }
}
