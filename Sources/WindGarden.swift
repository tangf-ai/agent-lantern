import SwiftUI
import Combine

/// One visible clock for the wind backdrop and ambient scenes; switching agents preserves motion.
final class WindClock: ObservableObject {
    @Published private(set) var motion = WindMotion()
    @Published private(set) var mood = WindMood.working
    private var requested = false
    private var tempo = AnimationTempo.calm
    private var consumers = Set<UUID>()
    private var timer: Timer?

    func configure(enabled: Bool, phase: ActivityPhase, tempo: AnimationTempo = .calm) {
        requested = enabled
        self.tempo = tempo
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
                self.motion.advance(at: ProcessInfo.processInfo.systemUptime, mood: self.mood, tempo: self.tempo)
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

/// Keep the existing center interaction, without putting another small turbine
/// in front of the window-wide background. The rest of the panel remains draggable.
struct WindGustButton: View {
    var clock: WindClock
    var side: CGFloat = 96

    var body: some View {
        Button { clock.gust() } label: {
            Color.clear.frame(width: side, height: 104).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("点中间吹一阵轻风。风车是背景陪伴，随忙碌程度平滑加速，不代表 TPS 或任务进度；关闭动画或减少动态效果时保持静态。")
        .accessibilityLabel("吹一阵轻风")
        .accessibilityHint("只改变背景风车的陪伴动效，不影响智能体工作")
    }
}

/// The selected centered composition: 1.05x size and 58% clarity.
/// This view alone observes the 30 fps clock; text and layout stay event-driven.
struct WindBackdropView: View {
    @ObservedObject var clock: WindClock
    var palette: Palette
    @State private var consumer = UUID()

    var body: some View {
        Canvas { context, size in
            WindBackdropScene(palette: palette, motion: clock.motion).draw(context, size: size)
        }
        .mask(LinearGradient(stops: [
            .init(color: .clear, location: 0.02),
            .init(color: .black.opacity(0.2), location: 0.17),
            .init(color: .black.opacity(0.73), location: 0.29),
            .init(color: .black, location: 0.4),
            .init(color: .black, location: 0.72),
            .init(color: .black.opacity(0.4), location: 0.85),
            .init(color: .clear, location: 0.98)
        ], startPoint: .top, endPoint: .bottom))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { clock.appear(consumer) }
        .onDisappear { clock.disappear(consumer) }
    }
}

private struct WindBackdropScene {
    var palette: Palette
    var motion: WindMotion
    private let clarity = 0.58
    private var tower: Color {
        palette.isDark ? Color(red: 0.45, green: 0.60, blue: 0.50) : Color(red: 0.86, green: 0.91, blue: 0.88)
    }
    private var blade: Color {
        palette.isDark ? Color(red: 0.90, green: 0.95, blue: 0.91) : Color(red: 1, green: 0.995, blue: 0.97)
    }

    func draw(_ context: GraphicsContext, size: CGSize) {
        let w = Double(size.width), h = Double(size.height)
        guard w > 0, h > 0 else { return }
        let x = w * 0.5, hub = h * 0.47
        let radius = w * 0.435 * 1.05
        // Keep expanded windows from stretching the tower through the entire task list.
        let base = min(h * 0.94, hub + w * 0.65)
        let edge = palette.accent
        var mast = Path()
        mast.addLines([CGPoint(x: x - radius * 0.023, y: hub),
                       CGPoint(x: x + radius * 0.058, y: base),
                       CGPoint(x: x - radius * 0.058, y: base)])
        mast.closeSubpath()
        context.fill(mast, with: .color(tower.opacity(clarity)))
        context.stroke(mast, with: .color(edge.opacity(clarity * 0.6)), lineWidth: 0.9)
        var highlight = Path()
        highlight.move(to: CGPoint(x: x, y: hub + 8))
        highlight.addLine(to: CGPoint(x: x - radius * 0.015, y: base - 3))
        context.stroke(highlight, with: .color(blade.opacity(clarity * 0.9)),
                       style: StrokeStyle(lineWidth: radius * 0.024, lineCap: .round))
        let nacelle = Path(roundedRect: CGRect(x: x - radius * 0.02, y: hub - radius * 0.031,
                           width: radius * 0.14, height: radius * 0.061), cornerRadius: radius * 0.022)
        context.fill(nacelle, with: .color(tower.opacity(clarity * 0.7)))
        context.stroke(nacelle, with: .color(edge.opacity(clarity * 0.7)), lineWidth: 0.8)
        for i in 0..<3 {
            var rotor = context
            rotor.translateBy(x: x, y: hub)
            rotor.rotate(by: .radians(motion.backdropAngle + 0.4 + Double(i) * .pi * 2 / 3))
            rotor.scaleBy(x: radius, y: radius)
            var shape = Path()
            shape.move(to: CGPoint(x: -0.013, y: 0.025))
            shape.addCurve(to: CGPoint(x: -0.014, y: -0.95),
                           control1: CGPoint(x: -0.085, y: -0.19), control2: CGPoint(x: -0.055, y: -0.7))
            shape.addQuadCurve(to: CGPoint(x: 0.032, y: -0.95), control: CGPoint(x: 0.011, y: -1.06))
            shape.addCurve(to: CGPoint(x: 0.017, y: 0.024),
                           control1: CGPoint(x: 0.072, y: -0.55), control2: CGPoint(x: 0.044, y: -0.15))
            shape.closeSubpath()
            rotor.fill(shape, with: .color(blade.opacity(clarity)))
            rotor.stroke(shape, with: .color(edge.opacity(clarity * 0.85)), lineWidth: 1.1 / radius)
            var seam = Path()
            seam.move(to: CGPoint(x: 0, y: -0.08))
            seam.addQuadCurve(to: CGPoint(x: 0.009, y: -0.91), control: CGPoint(x: -0.01, y: -0.5))
            rotor.stroke(seam, with: .color(tower.opacity(clarity * 0.7)),
                         style: StrokeStyle(lineWidth: 0.025, lineCap: .round))
        }
        let hubShape = Path(ellipseIn: CGRect(x: x - radius * 0.042, y: hub - radius * 0.042,
                                            width: radius * 0.084, height: radius * 0.084))
        context.fill(hubShape, with: .color(blade.opacity(clarity)))
        context.stroke(hubShape, with: .color(edge.opacity(clarity * 0.85)), lineWidth: 1)
        ellipse(context, x, hub, radius * 0.016, radius * 0.016, edge, clarity)
        ellipse(context, x, base + 3, radius * 0.22, 3, tower, clarity * 0.22)

        for i in 0..<5 {
            let u = (motion.breeze * 0.025 + Double(i) * 0.23).truncatingRemainder(dividingBy: 1)
            let px = w * u, py = h * (0.43 + Double(i) * 0.045) + sin(u * 6 + Double(i)) * 4
            var breeze = Path()
            breeze.move(to: CGPoint(x: px - 25, y: py))
            breeze.addQuadCurve(to: CGPoint(x: px + 12, y: py), control: CGPoint(x: px - 12, y: py - 3))
            context.stroke(breeze, with: .color(edge.opacity(0.1 * clarity * sin(u * .pi))), lineWidth: 0.8)
        }
        if let age = motion.gustAge {
            let u = age / 2.8
            for i in 0..<3 {
                let px = w * (0.15 + u * 0.55), py = hub + 24 + Double(i) * 12
                var gust = Path()
                gust.move(to: CGPoint(x: px, y: py))
                gust.addQuadCurve(to: CGPoint(x: px + 30, y: py), control: CGPoint(x: px + 16, y: py - 3))
                context.stroke(gust, with: .color(edge.opacity(sin(u * .pi) * 0.2)), lineWidth: 0.9)
            }
        }
    }

    private func ellipse(_ context: GraphicsContext, _ x: Double, _ y: Double, _ rx: Double, _ ry: Double,
                         _ color: Color, _ opacity: Double) {
        context.fill(Path(ellipseIn: CGRect(x: x - rx, y: y - ry, width: rx * 2, height: ry * 2)),
                     with: .color(color.opacity(opacity)))
    }
}
