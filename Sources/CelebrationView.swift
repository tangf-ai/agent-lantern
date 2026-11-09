import SwiftUI
import AppKit

final class CelebrationDisplay: ObservableObject {
    @Published var show: CompletionCelebration?
    @Published var source = CGPoint.zero
    @Published var palette = Palette.dark
    @Published var moving = true
    // Only set by isolated native previews; production always uses monotonic time.
    @Published var previewAge: Double?
}

struct CelebrationView: View {
    @ObservedObject var display: CelebrationDisplay

    var body: some View {
        GeometryReader { geometry in
            if let show = display.show {
                let width = min(310.0, max(0, geometry.size.width - 24))
                let center = CompletionCelebration.toastCenter(source: display.source, size: geometry.size, width: width)
                ZStack(alignment: .topLeading) {
                    if display.moving {
                        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: display.previewAge != nil)) { _ in
                            Canvas { context, size in
                                let age = display.previewAge ?? max(0, ProcessInfo.processInfo.systemUptime - show.began)
                                draw(context, size: size, show: show, age: age)
                            }
                        }.accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Label(show.title, systemImage: "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .medium)).lineLimit(1)
                            .foregroundStyle(display.palette.accent)
                        Text(show.subtitle).font(.system(size: 12)).foregroundStyle(display.palette.text(0.8)).lineLimit(2)
                    }
                    .padding(.horizontal, 17).padding(.vertical, 13)
                    .frame(width: width, alignment: .leading)
                    .background(display.palette.background, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(display.palette.border, lineWidth: 0.8))
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                    .position(center)
                    .accessibilityElement(children: .combine)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .environment(\.colorScheme, display.palette.isDark ? .dark : .light)
        .allowsHitTesting(false)
    }

    private func draw(_ context: GraphicsContext, size: CGSize, show: CompletionCelebration, age: Double) {
        let dark = display.palette.isDark
        let colors: [Color] = dark
            ? [Color(red: 1, green: 0.81, blue: 0.47), Color(red: 0.51, green: 0.90, blue: 0.71),
               Color(red: 0.96, green: 0.70, blue: 0.82), Color(red: 0.79, green: 0.75, blue: 1)]
            : [Color(red: 0.78, green: 0.51, blue: 0.09), Color(red: 0.15, green: 0.53, blue: 0.36),
               Color(red: 0.82, green: 0.36, blue: 0.56), Color(red: 0.53, green: 0.42, blue: 0.74)]
        let exit = min(1, max(0, (show.duration - age) / 0.5))
        func noise(_ n: Int) -> Double {
            let v = sin(Double(n) * 127.1 + 311.7) * 43758.5453
            return v - floor(v)
        }
        func dot(_ point: CGPoint, radius: Double, color: Color, alpha: Double) {
            let a = max(0, min(1, alpha * exit))
            let glow = CGRect(x: point.x - radius * 3, y: point.y - radius * 3, width: radius * 6, height: radius * 6)
            context.fill(Path(ellipseIn: glow), with: .radialGradient(Gradient(colors: [color.opacity(a * 0.38), color.opacity(0)]),
                center: point, startRadius: 0, endRadius: radius * 3))
            context.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)),
                         with: .color(color.opacity(a)))
        }
        func line(_ a: CGPoint, _ b: CGPoint, color: Color, alpha: Double, width: Double = 1.4) {
            var path = Path(); path.move(to: a); path.addLine(to: b)
            context.stroke(path, with: .color(color.opacity(max(0, min(1, alpha * exit)))),
                           style: StrokeStyle(lineWidth: width, lineCap: .round))
        }
        // The source glow belongs to the little lamp; no opaque fullscreen layer or camera flash.
        if age < 0.7 {
            let strength = sin(min(1, age / 0.7) * .pi)
            dot(display.source, radius: 10 + 15 * strength, color: colors[0], alpha: 0.45 * strength)
        }
        for (index, burst) in show.bursts.enumerated() {
            let target = CGPoint(x: size.width * burst.x, y: size.height * burst.y)
            let color = colors[burst.color % colors.count]
            let flight = 0.6, launched = age - burst.launch
            if launched >= 0 && launched < flight {
                let u = launched / flight
                func flightPoint(_ t: Double) -> CGPoint {
                    CGPoint(x: display.source.x + (target.x - display.source.x) * t,
                            y: display.source.y + (target.y - display.source.y) * (1 - pow(1 - t, 1.5)))
                }
                let head = flightPoint(u)
                line(head, flightPoint(max(0, u - 0.06)), color: color, alpha: 0.85, width: 2.2)
                dot(head, radius: 2.4, color: color, alpha: 1)
            }
            let t = launched - flight
            guard t >= 0 && t < 2.65 else { continue }
            let radius = min(size.width * 0.25, size.height * 0.42) * burst.scale
            if t < 0.16 { dot(target, radius: 16 * (1 - t / 0.16), color: color, alpha: 0.5 * (1 - t / 0.16)) }
            for particle in 0..<110 {
                let seed = particle + index * 200
                let angle = 2 * Double.pi * Double(particle) / 110 + noise(seed) * 0.1
                let speed = radius * (0.65 + noise(seed + 41) * 0.5)
                func position(_ at: Double) -> CGPoint {
                    let t = max(0, at), distance = (1 - exp(-1.65 * t)) / 1.65
                    return CGPoint(x: target.x + cos(angle) * speed * distance,
                                   y: target.y + sin(angle) * speed * distance + 16 * t * t)
                }
                let point = position(t), fade = pow(max(0, 1 - t / 2.65), 1.1)
                line(point, position(t - 0.055), color: color, alpha: fade * 0.75)
                dot(point, radius: 1 + noise(seed + 88), color: color,
                    alpha: fade * (0.65 + 0.35 * sin(t * 20 + Double(seed))))
                if particle % 8 == 0 && t > 0.5 {
                    dot(CGPoint(x: point.x - 2, y: point.y - 7), radius: 0.9, color: colors[0], alpha: fade * 0.55)
                }
            }
        }
    }
}
