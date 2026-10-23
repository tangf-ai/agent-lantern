import SwiftUI

/// A conceptual mechanism illustration. Only observed phases enable animation;
/// layer count, cell brightness and token tiles are never internal model telemetry.
struct MechanismScene {
    enum Layer { case mechanisms, transfers }
    var palette: Palette
    var phase: FlowPhase
    var detailed: Bool
    var elapsed: Double
    var eventAge: Double
    var moving: Bool
    var transfer: TransferPulse? = nil
    var transferAge: Double? = nil
    private let intensity = 1.3

    func draw(_ context: GraphicsContext, size: CGSize, layer: Layer = .mechanisms) {
        let width = Double(size.width)
        let left = width / 6
        let right = width * 5 / 6
        let y = 56.0
        let scale = min(96, width / 3 - 1) / 84
        let reach = 29 * scale
        let outbound: (Double) -> CGPoint = { u in
            CGPoint(x: left + reach + (right - left - reach * 2) * u,
                    y: y - 10 * scale - sin(u * .pi) * 4 * scale)
        }
        let inbound: (Double) -> CGPoint = { u in
            CGPoint(x: right - reach - (right - left - reach * 2) * u,
                    y: y + 18 * scale + sin(u * .pi) * 3 * scale)
        }
        if layer == .transfers {
            if let transfer, phase != .waiting {
                if transfer.kind == "response" {
                    receive(context, x: left, y: y, along: inbound, scale: scale, recordedAge: transferAge ?? 0)
                } else {
                    send(context, x: left, target: right, y: y, along: outbound, scale: scale, recordedAge: transferAge ?? 0)
                }
            } else if phase == .sending {
                send(context, x: left, target: right, y: y, along: outbound, scale: scale)
            } else if phase.showsInboundFlow {
                receive(context, x: left, y: y, along: inbound, scale: scale)
            }
            return
        }
        // Scale the mechanisms themselves, including strokes and labels, while
        // keeping the transfer paths in panel coordinates across the garden.
        var agentContext = context
        agentContext.translateBy(x: left, y: y)
        agentContext.scaleBy(x: scale, y: scale)
        agent(agentContext, x: 0, y: 0)
        var modelContext = context
        modelContext.translateBy(x: right, y: y)
        modelContext.scaleBy(x: scale, y: scale)
        model(modelContext, x: 0, y: 0)
        if detailed {
            text(context, "组织 · 工具 · 回填", left, 128, palette.text(0.65), size: 11)
            text(context, "微风相伴", width / 2, 128, palette.text(0.55), size: 11)
            text(context, "关联 · 计算 · 生成", right, 128, palette.text(0.65), size: 11)
        }
    }

    private func send(_ context: GraphicsContext, x: Double, target: Double, y: Double,
                      along path: (Double) -> CGPoint, scale: Double, recordedAge: Double? = nil) {
        let progress = min(1, max(0, (recordedAge ?? eventAge) / FlowPhase.sendingDuration))
        let color = palette.warning
        if progress < 0.22 {
            let charge = progress / 0.22
            for i in 0..<8 {
                let angle = Double(i) * .pi / 4 + elapsed * 0.2
                let radius = (43.0 - charge * 12) * scale
                let p = CGPoint(x: x + cos(angle) * radius, y: y + sin(angle) * radius)
                glow(context, p, 8 * scale, color, 0.22)
                circle(context, p, 2.8 * scale, color, 0.8, fill: true)
            }
        } else if progress < 0.96 {
            let u = min(1, (progress - 0.22) / 0.68)
            let eased = u < 0.5 ? 2 * u * u : 1 - pow(-2 * u + 2, 2) / 2
            comet(context, path, eased, color, tail: 0.29 * sqrt(2.5), radius: 2.5 * scale * 2.5, highlight: true)
        }
        if progress > 0.77 {
            let p = (progress - 0.77) / 0.23
            circle(context, CGPoint(x: target, y: y - 5), 8 + p * (detailed ? 24 : 17),
                   color, (1 - p) * 0.7, width: 1.3)
        }
    }

    private func receive(_ context: GraphicsContext, x: Double, y: Double,
                         along path: (Double) -> CGPoint, scale: Double, recordedAge: Double? = nil) {
        // A recorded response gets one bounded pulse; a fresh stream can show continuous flow.
        let count = phase == .response || recordedAge != nil ? 1 : 2
        for i in 0..<count {
            let u: Double
            if !moving { u = 0.55 }
            else if phase == .response || recordedAge != nil { u = min(1, (recordedAge ?? eventAge) / 2.5) }
            else { u = (elapsed * 0.43 + Double(i) / 2).truncatingRemainder(dividingBy: 1) }
            comet(context, path, u, palette.accent, tail: 0.29 * sqrt(2.5), radius: 2.2 * scale * 2.5, highlight: true)
            if u > 0.85 {
                let p = (u - 0.85) / 0.15
                circle(context, CGPoint(x: x, y: y + 3), 11 + p * (detailed ? 21 : 12),
                       palette.accent, (1 - p) * 0.5, width: 1.1)
            }
        }
    }

    private func agent(_ context: GraphicsContext, x: Double, y: Double) {
        let orbit = 36.0
        let color = phase == .sending ? palette.warning : palette.accent
        let active = phase.showsAgentCycle || phase == .sending || phase == .receiving
        let nodes = [CGPoint(x: x, y: y - orbit), CGPoint(x: x + orbit, y: y),
                     CGPoint(x: x, y: y + orbit), CGPoint(x: x - orbit, y: y)]
        // Highlight the observed tool phase; the traversing light is a closed-loop illustration.
        let selected = phase.showsAgentCycle ? 2 : phase == .sending ? 0 : 3
        glow(context, CGPoint(x: x, y: y), 42, color, active ? 0.16 : 0.025)
        for i in 0..<4 {
            line(context, [nodes[i], nodes[(i + 1) % 4]], palette.ink, 0.8, 0.24)
            circle(context, nodes[i], 5, color, active && i == selected ? 0.8 : 0.45, width: 1)
            circle(context, nodes[i], 1.7, color, active && i == selected ? 0.9 : 0.18, fill: true)
        }
        if phase.showsAgentCycle {
            let progress = elapsed * 0.8
            let index = Int(progress) % 4
            let u = progress.truncatingRemainder(dividingBy: 1)
            let a = nodes[index], b = nodes[(index + 1) % 4]
            comet(context, { p in CGPoint(x: a.x + (b.x - a.x) * p, y: a.y + (b.y - a.y) * p) },
                  u, color, tail: 0.35, radius: 1.7)
        }
        for i in stride(from: 2, through: 0, by: -1) {
            let size = 18.0
            let shift = Double(i) * 2
            let dx = active ? sin(elapsed * 1.4 + Double(i)) * 0.7 : 0
            let rect = CGRect(x: x - size / 2 + shift + dx, y: y - size / 2 - shift, width: size, height: 23)
            let path = Path(roundedRect: rect, cornerRadius: 1.8)
            context.fill(path, with: .color(palette.background))
            context.stroke(path, with: .color(color.opacity(active ? 0.7 : 0.38)), lineWidth: 0.8)
            line(context, [CGPoint(x: rect.minX + 2, y: rect.midY), CGPoint(x: rect.maxX - 2, y: rect.midY)],
                 color, 0.6, active ? 0.5 : 0.15)
        }
    }

    private func model(_ context: GraphicsContext, x: Double, y: Double) {
        let active = phase.showsModelPrinciple
        let color = phase == .sending ? palette.warning : palette.accent
        let pitch = 9.0
        let depth = 2.6
        let offset = 17.0
        let top = y - 40
        let cycle = elapsed.truncatingRemainder(dividingBy: 4) / 4 * 3
        glow(context, CGPoint(x: x, y: y), 42, color, active ? 0.19 : 0.025)
        for layer in stride(from: 2, through: 0, by: -1) {
            let origin = top + Double(layer) * offset
            let energy = active ? max(0.12, 1 - abs(cycle - Double(layer)) / 1.2) : 0.02
            let plane = [CGPoint(x: x, y: origin), CGPoint(x: x + pitch * 4.2, y: origin + depth * 4.2),
                         CGPoint(x: x, y: origin + depth * 8.4), CGPoint(x: x - pitch * 4.2, y: origin + depth * 4.2)]
            var path = Path()
            path.addLines(plane)
            path.closeSubpath()
            context.fill(path, with: .color(palette.background))
            context.stroke(path, with: .color(color.opacity(0.30 + energy * 0.5)), lineWidth: 0.9)
            for row in 0..<4 {
                for col in 0..<4 {
                    let px = x + Double(col - row) * pitch
                    let py = origin + 2 + Double(col + row) * depth
                    let strength = col <= row ? 0.18 + 0.58 * (0.5 + 0.5 * sin(elapsed * 2.6 + Double(row) * 0.9 - Double(col) * 0.7 - Double(layer))) : 0.035
                    let opacity = active ? strength * (0.38 + energy * 0.6) : 0.14
                    var tile = Path()
                    tile.addLines([CGPoint(x: px, y: py), CGPoint(x: px + pitch * 0.8, y: py + depth * 0.8),
                                   CGPoint(x: px, y: py + depth * 1.6), CGPoint(x: px - pitch * 0.8, y: py + depth * 0.8)])
                    tile.closeSubpath()
                    context.fill(tile, with: .color(color.opacity(min(1, opacity * intensity))))
                }
            }
            if active {
                let u = (elapsed * 0.65 + Double(layer) * 0.27).truncatingRemainder(dividingBy: 1)
                comet(context, { p in CGPoint(x: x - pitch * 4.2 + p * pitch * 8.4,
                                             y: origin + depth * 4.2 + sin(p * .pi) * depth * 4.2) },
                      u, color, tail: 0.2, radius: 1.1)
            }
        }
        let tokenY = y + 37.0
        let tokenWidth = 14.0
        let gap = 19.0
        let chosen = Int(elapsed * 1.5) % 4
        for i in 0..<4 {
            let px = x - gap * 1.5 + Double(i) * gap - tokenWidth / 2
            let lit = phase == .receiving && i <= chosen
            let rect = CGRect(x: px, y: tokenY - 4, width: tokenWidth, height: 8)
            let tile = Path(roundedRect: rect, cornerRadius: 2)
            context.fill(tile, with: .color(color.opacity(lit ? 0.25 : 0.10)))
            if lit && i == chosen { context.stroke(tile, with: .color(color.opacity(0.7)), lineWidth: 0.7) }
        }
    }

    private func text(_ context: GraphicsContext, _ value: String, _ x: Double, _ y: Double,
                      _ color: Color, size: CGFloat, anchor: UnitPoint = .center) {
        context.draw(Text(value).font(.system(size: size)).foregroundColor(color), at: CGPoint(x: x, y: y), anchor: anchor)
    }

    private func line(_ context: GraphicsContext, _ points: [CGPoint], _ color: Color, _ width: CGFloat, _ opacity: Double) {
        var path = Path()
        path.addLines(points)
        context.stroke(path, with: .color(color.opacity(opacity)), style: StrokeStyle(lineWidth: width, lineCap: .round))
    }

    private func circle(_ context: GraphicsContext, _ point: CGPoint, _ radius: Double, _ color: Color,
                        _ opacity: Double, width: CGFloat = 1, fill: Bool = false) {
        let path = Path(ellipseIn: CGRect(x: Double(point.x) - radius, y: Double(point.y) - radius, width: radius * 2, height: radius * 2))
        if fill { context.fill(path, with: .color(color.opacity(opacity))) }
        else { context.stroke(path, with: .color(color.opacity(opacity)), lineWidth: width) }
    }

    private func glow(_ context: GraphicsContext, _ point: CGPoint, _ radius: Double, _ color: Color, _ opacity: Double) {
        let path = Path(ellipseIn: CGRect(x: Double(point.x) - radius, y: Double(point.y) - radius, width: radius * 2, height: radius * 2))
        context.fill(path, with: .radialGradient(Gradient(colors: [color.opacity(opacity), color.opacity(0)]),
                                               center: point, startRadius: 0, endRadius: radius))
    }

    private func comet(_ context: GraphicsContext, _ fn: (Double) -> CGPoint, _ progress: Double,
                       _ color: Color, tail: Double, radius: Double, highlight: Bool = false) {
        let start = max(0, progress - tail)
        var upper: [CGPoint] = [], lower: [CGPoint] = []
        for i in 0...20 {
            let fraction = Double(i) / 20
            let u = start + (progress - start) * fraction
            let p = fn(u), before = fn(max(0, u - 0.001)), after = fn(min(1, u + 0.001))
            let dx = Double(after.x - before.x), dy = Double(after.y - before.y)
            let length = max(0.001, hypot(dx, dy))
            let width = radius * (highlight ? 1 : intensity) * pow(fraction, 1.4) * 0.86
            upper.append(CGPoint(x: Double(p.x) - dy / length * width, y: Double(p.y) + dx / length * width))
            lower.append(CGPoint(x: Double(p.x) + dy / length * width, y: Double(p.y) - dx / length * width))
        }
        var trail = Path()
        trail.addLines(upper + lower.reversed())
        trail.closeSubpath()
        context.fill(trail, with: .linearGradient(Gradient(colors: [color.opacity(0), color.opacity(0.8)]),
                                                startPoint: fn(start), endPoint: fn(progress)))
        let point = fn(progress)
        glow(context, point, radius * 5, color, 0.32)
        circle(context, point, radius + 1, color, 0.18, fill: true)
        circle(context, point, radius, color, 1, fill: true)
        if highlight { circle(context, point, radius * 0.34, .white, 0.98, fill: true) }
    }
}
