import SwiftUI

/// A conceptual mechanism illustration. Only observed phases enable animation;
/// layer count, cell brightness and token tiles are never internal model telemetry.
struct MechanismScene {
    var palette: Palette
    var phase: FlowPhase
    var detailed: Bool
    var elapsed: Double
    var eventAge: Double
    var moving: Bool
    var transfer: TransferPulse? = nil
    var transferAge: Double? = nil
    private let intensity = 1.3

    func draw(_ context: GraphicsContext, size: CGSize) {
        let width = Double(size.width)
        let left = detailed ? 58.0 : 26.0
        let right = width - left
        let y = detailed ? 62.0 : 31.0
        let reach = detailed ? 20.0 : 13.0
        let outbound: (Double) -> CGPoint = { u in
            CGPoint(x: left + reach + (right - left - reach * 2) * u,
                    y: y - reach * 0.8 - sin(u * .pi) * (detailed ? 17 : 10))
        }
        let inbound: (Double) -> CGPoint = { u in
            CGPoint(x: right - reach - (right - left - reach * 2) * u,
                    y: y + (detailed ? 48 : 24) + sin(u * .pi) * (detailed ? 8 : 4))
        }
        line(context, samples(outbound), palette.ink, 0.7, 0.10)
        line(context, samples(inbound), palette.ink, 0.7, 0.08)
        if let transfer, phase != .waiting {
            if transfer.kind == "response" {
                receive(context, x: left, y: y, along: inbound, recordedAge: transferAge ?? 0)
            } else {
                send(context, x: left, target: right, y: y, along: outbound, recordedAge: transferAge ?? 0)
            }
        } else if phase == .sending {
            send(context, x: left, target: right, y: y, along: outbound)
        } else if phase.showsInboundFlow {
            receive(context, x: left, y: y, along: inbound)
        }
        agent(context, x: left, y: y)
        model(context, x: right, y: y)
        if phase == .waiting {
            context.draw(Text(Image(systemName: "pause.fill")).font(.system(size: 11))
                .foregroundColor(palette.warning), at: CGPoint(x: width / 2, y: y + 3))
        }
        if detailed {
            text(context, "组织 · 工具 · 回填", left, 142, palette.text(0.55), size: 9)
            text(context, "关联 · 计算 · 生成", right, 142, palette.text(0.55), size: 9)
        }
    }

    private func send(_ context: GraphicsContext, x: Double, target: Double, y: Double,
                      along path: (Double) -> CGPoint, recordedAge: Double? = nil) {
        let progress = min(1, max(0, (recordedAge ?? eventAge) / FlowPhase.sendingDuration))
        let color = palette.warning
        if progress < 0.22 {
            let charge = progress / 0.22
            for i in 0..<8 {
                let angle = Double(i) * .pi / 4 + elapsed * 0.2
                let radius = (detailed ? 35.0 : 22.0) - charge * 12
                let p = CGPoint(x: x + cos(angle) * radius, y: y + sin(angle) * radius)
                glow(context, p, 5, color, 0.22)
                circle(context, p, 1.4, color, 0.7, fill: true)
            }
        } else if progress < 0.96 {
            let u = min(1, (progress - 0.22) / 0.68)
            let eased = u < 0.5 ? 2 * u * u : 1 - pow(-2 * u + 2, 2) / 2
            comet(context, path, eased, color, tail: 0.3, radius: detailed ? 3.7 : 3)
        }
        if progress > 0.77 {
            let p = (progress - 0.77) / 0.23
            circle(context, CGPoint(x: target, y: y - 5), 8 + p * (detailed ? 24 : 17),
                   color, (1 - p) * 0.7, width: 1.3)
        }
    }

    private func receive(_ context: GraphicsContext, x: Double, y: Double,
                         along path: (Double) -> CGPoint, recordedAge: Double? = nil) {
        // A recorded response gets one bounded pulse; a fresh stream can show continuous flow.
        let count = phase == .response || recordedAge != nil ? 1 : 3
        for i in 0..<count {
            let u: Double
            if !moving { u = 0.55 }
            else if phase == .response || recordedAge != nil { u = min(1, (recordedAge ?? eventAge) / 2.5) }
            else { u = (elapsed * 0.43 + Double(i) / 3).truncatingRemainder(dividingBy: 1) }
            comet(context, path, u, palette.accent, tail: 0.27, radius: detailed ? 2.8 : 2.5)
            if u > 0.85 {
                let p = (u - 0.85) / 0.15
                circle(context, CGPoint(x: x, y: y + 3), 11 + p * (detailed ? 21 : 12),
                       palette.accent, (1 - p) * 0.5, width: 1.1)
            }
        }
    }

    private func agent(_ context: GraphicsContext, x: Double, y: Double) {
        let orbit = detailed ? 22.0 : 12.0
        let color = phase == .sending ? palette.warning : palette.accent
        let active = phase.showsAgentCycle || phase == .sending || phase == .receiving
        let nodes = [CGPoint(x: x, y: y - orbit), CGPoint(x: x + orbit, y: y),
                     CGPoint(x: x, y: y + orbit), CGPoint(x: x - orbit, y: y)]
        // Highlight the observed tool phase; the traversing light is a closed-loop illustration.
        let selected = phase.showsAgentCycle ? 2 : phase == .sending ? 0 : 3
        glow(context, CGPoint(x: x, y: y), detailed ? 39 : 25, color, active ? 0.16 : 0.025)
        let labels = ["组织", "调度", "工具", "回填"]
        for i in 0..<4 {
            line(context, [nodes[i], nodes[(i + 1) % 4]], palette.ink, 0.7, 0.12)
            circle(context, nodes[i], detailed ? 4.3 : 2.8, color, active && i == selected ? 0.8 : 0.22, width: 0.8)
            circle(context, nodes[i], detailed ? 2.1 : 1.3, color, active && i == selected ? 0.9 : 0.08, fill: true)
            if detailed {
                let dx = [0.0, 10, 0, -10][i]
                let dy = [-12.0, 0, 12, 0][i]
                text(context, labels[i], Double(nodes[i].x) + dx, Double(nodes[i].y) + dy,
                     active && i == selected ? color : palette.text(0.4), size: 9,
                     anchor: i == 1 ? .leading : i == 3 ? .trailing : .center)
            }
        }
        if phase.showsAgentCycle {
            let progress = elapsed * 0.8
            let index = Int(progress) % 4
            let u = progress.truncatingRemainder(dividingBy: 1)
            let a = nodes[index], b = nodes[(index + 1) % 4]
            comet(context, { p in CGPoint(x: a.x + (b.x - a.x) * p, y: a.y + (b.y - a.y) * p) },
                  u, color, tail: 0.35, radius: detailed ? 1.8 : 1.3)
        }
        for i in stride(from: 2, through: 0, by: -1) {
            let size = detailed ? 11.0 : 7.0
            let shift = Double(i) * (detailed ? 1.8 : 1.3)
            let dx = active ? sin(elapsed * 1.4 + Double(i)) * 0.7 : 0
            let rect = CGRect(x: x - size / 2 + shift + dx, y: y - size / 2 - shift, width: size, height: size + 2)
            let path = Path(roundedRect: rect, cornerRadius: 1.8)
            context.fill(path, with: .color(palette.background))
            context.stroke(path, with: .color(color.opacity(active ? 0.55 : 0.2)), lineWidth: 0.7)
            line(context, [CGPoint(x: rect.minX + 2, y: rect.midY), CGPoint(x: rect.maxX - 2, y: rect.midY)],
                 color, 0.6, active ? 0.5 : 0.15)
        }
    }

    private func model(_ context: GraphicsContext, x: Double, y: Double) {
        let active = phase.showsModelPrinciple
        let color = phase == .sending ? palette.warning : palette.accent
        let pitch = detailed ? 4.8 : 3.1
        let depth = detailed ? 2.3 : 1.5
        let offset = detailed ? 13.0 : 8.0
        let top = y - (detailed ? 28 : 17)
        let cycle = elapsed.truncatingRemainder(dividingBy: 4) / 4 * 3
        glow(context, CGPoint(x: x, y: y), detailed ? 42 : 28, color, active ? 0.19 : 0.025)
        if detailed { text(context, "上下文关联", x, y - 41, palette.text(0.5), size: 9) }
        for layer in stride(from: 2, through: 0, by: -1) {
            let origin = top + Double(layer) * offset
            let energy = active ? max(0.12, 1 - abs(cycle - Double(layer)) / 1.2) : 0.02
            let plane = [CGPoint(x: x, y: origin), CGPoint(x: x + pitch * 4.2, y: origin + depth * 4.2),
                         CGPoint(x: x, y: origin + depth * 8.4), CGPoint(x: x - pitch * 4.2, y: origin + depth * 4.2)]
            var path = Path()
            path.addLines(plane)
            path.closeSubpath()
            context.fill(path, with: .color(palette.background))
            context.stroke(path, with: .color(color.opacity(0.17 + energy * 0.5)), lineWidth: 0.8)
            for row in 0..<4 {
                for col in 0..<4 {
                    let px = x + Double(col - row) * pitch
                    let py = origin + 2 + Double(col + row) * depth
                    let strength = col <= row ? 0.18 + 0.58 * (0.5 + 0.5 * sin(elapsed * 2.6 + Double(row) * 0.9 - Double(col) * 0.7 - Double(layer))) : 0.035
                    let opacity = active ? strength * (0.28 + energy * 0.7) : 0.06
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
                      u, color, tail: 0.2, radius: detailed ? 1.2 : 0.9)
            }
        }
        let tokenY = y + (detailed ? 40.0 : 25.0)
        let tokenWidth = detailed ? 13.0 : 5.0
        let gap = detailed ? 16.0 : 8.0
        let chosen = Int(elapsed * 1.5) % 4
        for i in 0..<4 {
            let px = x - gap * 1.5 + Double(i) * gap - tokenWidth / 2
            let lit = phase == .receiving && i <= chosen
            let rect = CGRect(x: px, y: tokenY - 5, width: tokenWidth, height: detailed ? 11 : 5)
            let tile = Path(roundedRect: rect, cornerRadius: 2)
            context.fill(tile, with: .color(color.opacity(lit ? 0.18 : 0.04)))
            if lit && i == chosen { context.stroke(tile, with: .color(color.opacity(0.7)), lineWidth: 0.7) }
            if detailed { text(context, "t\(i + 1)", Double(rect.midX), Double(rect.midY), lit ? color : palette.text(0.4), size: 8) }
        }
    }

    private func text(_ context: GraphicsContext, _ value: String, _ x: Double, _ y: Double,
                      _ color: Color, size: CGFloat, anchor: UnitPoint = .center) {
        context.draw(Text(value).font(.system(size: size)).foregroundColor(color), at: CGPoint(x: x, y: y), anchor: anchor)
    }

    private func samples(_ fn: (Double) -> CGPoint) -> [CGPoint] { (0...40).map { fn(Double($0) / 40) } }

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
                       _ color: Color, tail: Double, radius: Double) {
        let start = max(0, progress - tail)
        var upper: [CGPoint] = [], lower: [CGPoint] = []
        for i in 0...20 {
            let fraction = Double(i) / 20
            let u = start + (progress - start) * fraction
            let p = fn(u), before = fn(max(0, u - 0.001)), after = fn(min(1, u + 0.001))
            let dx = Double(after.x - before.x), dy = Double(after.y - before.y)
            let length = max(0.001, hypot(dx, dy))
            let width = radius * intensity * pow(fraction, 1.4) * 0.75
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
    }
}
