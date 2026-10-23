import SwiftUI

/// Work phases highlight conceptual activity; standby only breathes and floats.
/// Layer count, cell brightness and token tiles are never internal model telemetry.
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
    var sideElapsed: Double? = nil
    private let intensity = 1.3
    private let sidePower = 1.5
    private var sideTime: Double { sideElapsed ?? elapsed }

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
        let t = sideTime
        let orbit = 36.0
        let color = phase == .sending ? palette.warning : palette.accent
        let active = phase.allowsMechanismMotion && (phase.showsAgentPrinciple || transfer != nil)
        let nodes = [CGPoint(x: x, y: y - orbit), CGPoint(x: x + orbit, y: y),
                     CGPoint(x: x, y: y + orbit), CGPoint(x: x - orbit, y: y)]
        let breathe = 0.5 + 0.5 * sin(t * 1.5)
        glow(context, CGPoint(x: x, y: y), 43, color, active ? 0.12 + 0.07 * breathe : 0.045 + 0.015 * breathe)
        circle(context, CGPoint(x: x, y: y), 39.5, palette.accent, 0.18)
        let spin = t * (active ? 0.8 : 0.12)
        arc(context, CGPoint(x: x, y: y), 39.5, spin, 1.15, color, active ? 0.8 : 0.32, 1.2)
        arc(context, CGPoint(x: x, y: y), 39.5, spin + .pi, 0.6, color, active ? 0.42 : 0.2, 0.8)
        let selected = Int(t * 0.7) % 4
        for i in 0..<4 {
            let lit = active && (i == selected || i == (selected + 1) % 4)
            let a = nodes[i], b = nodes[(i + 1) % 4]
            line(context, [a, b], palette.ink, 0.9, 0.24)
            if lit { glow(context, a, 10, color, 0.2) }
            circle(context, a, 4.7, color, lit ? 0.95 : 0.4, width: 1.1)
            circle(context, a, lit ? 2.3 : 1.2, color, lit ? 0.9 : 0.18, fill: true)
            if active {
                let u = (t * 0.48 + Double(i) * 0.25).truncatingRemainder(dividingBy: 1)
                comet(context, { p in CGPoint(x: a.x + (b.x - a.x) * p, y: a.y + (b.y - a.y) * p) },
                      u, color, tail: 0.20, radius: 1.25 * sidePower)
            }
        }
        // Cards gather and scan; these lines are symbolic context, not message content.
        for i in stride(from: 2, through: 0, by: -1) {
            let index = Double(i)
            let fan = active ? sin(t * 1.25 + index * 0.7) * 2.4 : sin(t * 0.45 + index) * 0.45
            var card = context
            card.translateBy(x: x + index * 2 + fan, y: y - index * 2 + sin(t * 0.8 + index) * 0.55)
            card.rotate(by: .radians(active ? (index - 1) * 0.055 * sin(t * 0.8) : 0))
            let shape = Path(roundedRect: CGRect(x: -10, y: -11, width: 19, height: 25), cornerRadius: 3)
            card.fill(shape, with: .color(palette.background))
            card.stroke(shape, with: .color(color.opacity(active ? 0.95 : 0.6)), lineWidth: 1)
            for row in 0..<3 {
                let fill = active ? 0.35 + 0.65 * (0.5 + 0.5 * sin(t * 2.5 - Double(row) * 0.9 + index)) : 0.65
                let length = (row == 2 ? 8.0 : 11.0) * fill
                line(card, [CGPoint(x: -6, y: -5 + Double(row) * 5),
                            CGPoint(x: -6 + length, y: -5 + Double(row) * 5)], color, 0.9, active ? 0.8 : 0.35)
            }
            if active {
                let scan = -8 + (t * 0.42 + index * 0.2).truncatingRemainder(dividingBy: 1) * 18
                line(card, [CGPoint(x: -8, y: scan), CGPoint(x: 7, y: scan)], color, 1, 0.32)
            }
        }
        if active {
            for i in 0..<3 {
                let u = (t * 0.52 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                let startX = phase == .receiving || phase == .response ? 27.0 : -27.0
                let px = x + startX * (1 - u)
                let py = y + (-24 + Double(i) * 7) * (1 - u) + sin(u * .pi) * 4
                let tile = Path(roundedRect: CGRect(x: px - 2.5, y: py - 1.8, width: 5, height: 3.6), cornerRadius: 1)
                context.fill(tile, with: .color(color.opacity(0.25 + 0.65 * u)))
            }
            if phase == .tools {
                let node = nodes[2], u = (t * 0.65).truncatingRemainder(dividingBy: 1)
                comet(context, { p in CGPoint(x: node.x + (x - node.x) * p, y: node.y + (y + 9 - node.y) * p) },
                      u, palette.accent, tail: 0.20, radius: 1.6 * sidePower)
            }
        }
    }

    private func model(_ context: GraphicsContext, x: Double, y: Double) {
        let t = sideTime
        let active = phase.showsModelPrinciple
        let color = palette.accent
        let pulse = 0.5 + 0.5 * sin(t * 1.7)
        glow(context, CGPoint(x: x, y: y), 44, color, active ? 0.14 + 0.09 * pulse : 0.04 + 0.012 * pulse)
        var tops = [Double](repeating: 0, count: 3)
        for layer in stride(from: 2, through: 0, by: -1) {
            let top = y - 38 + Double(layer) * 16.5 + sin(t * (active ? 1.3 : 0.45) + Double(layer) * 0.8) * (active ? 2.2 : 0.65)
            tops[layer] = top
            var grid = context
            grid.translateBy(x: x, y: top)
            let plane = [CGPoint(x: 0, y: 0), CGPoint(x: 37, y: 11), CGPoint(x: 0, y: 22), CGPoint(x: -37, y: 11)]
            var path = Path()
            path.addLines(plane)
            path.closeSubpath()
            grid.fill(path, with: .color(palette.background))
            grid.stroke(path, with: .color(color.opacity(active ? 0.65 : 0.35)), lineWidth: 1.1)
            let wave = (t * 0.72).truncatingRemainder(dividingBy: 3)
            let layerEnergy = active ? max(0.18, 1 - abs(wave - Double(layer)) / 1.4) : 0.16
            for row in 0..<4 {
                for col in 0..<4 {
                    let px = Double(col - row) * 8.6
                    let py = 2 + Double(col + row) * 2.5
                    let attention = col <= row ? 1.0 : 0.2
                    let energy = active ? (0.16 + 0.68 * (0.5 + 0.5 * sin(t * 3.2 + Double(row) * 0.9 - Double(col) * 0.7 - Double(layer)))) * layerEnergy * attention : 0.15
                    var tile = Path()
                    tile.addLines([CGPoint(x: px, y: py), CGPoint(x: px + 6.7, y: py + 2),
                                   CGPoint(x: px, y: py + 4), CGPoint(x: px - 6.7, y: py + 2)])
                    tile.closeSubpath()
                    grid.fill(tile, with: .color(color.opacity(min(0.9, energy * sidePower))))
                    if active && energy > 0.6 { grid.stroke(tile, with: .color(Color.white.opacity(0.55)), lineWidth: 0.7) }
                }
            }
            if active {
                let u = (t * 0.55 + Double(layer) * 0.21).truncatingRemainder(dividingBy: 1)
                comet(grid, { p in CGPoint(x: -30 + 60 * p, y: 11 + sin(p * .pi) * 8) },
                      u, color, tail: 0.2, radius: 1.15 * sidePower)
            }
        }
        if active {
            for layer in 0..<2 {
                for col in 0..<3 {
                    let u = (t * 0.6 + Double(col) * 0.28 + Double(layer) * 0.18).truncatingRemainder(dividingBy: 1)
                    let point = CGPoint(x: x + Double(col - 1) * 17,
                                        y: tops[layer] + 12 + (tops[layer + 1] - tops[layer]) * u)
                    glow(context, point, 4.5, color, 0.16)
                    circle(context, point, 1.2, color, 0.85, fill: true)
                }
            }
        }
        let generating = phase == .receiving
        let chosen = Int(t * 1.5) % 4
        for i in 0..<4 {
            let lit = generating && i <= chosen
            let bounce = generating && i == chosen ? -sin((t * 1.5).truncatingRemainder(dividingBy: 1) * .pi) * 1.8 : 0
            let px = x - 35 + Double(i) * 19
            let rect = CGRect(x: px, y: y + 33 + bounce, width: 14, height: 8)
            let tile = Path(roundedRect: rect, cornerRadius: 2)
            context.fill(tile, with: .color(color.opacity(lit ? 0.55 : 0.14)))
            if lit { context.stroke(tile, with: .color(color.opacity(0.55)), lineWidth: 1) }
            if generating && i == chosen { glow(context, CGPoint(x: px + 7, y: y + 37 + bounce), 9, color, 0.22) }
        }
        if generating {
            let u = (t * 0.8).truncatingRemainder(dividingBy: 1), target = x - 28 + Double(Int(t * 0.8) % 4) * 19
            comet(context, { p in CGPoint(x: x + (target - x) * p, y: y + 20 + 17 * p - sin(p * .pi) * 3) },
                  u, color, tail: 0.2, radius: 1.35 * sidePower)
        }
    }

    private func arc(_ context: GraphicsContext, _ point: CGPoint, _ radius: Double, _ start: Double,
                     _ length: Double, _ color: Color, _ opacity: Double, _ width: CGFloat) {
        var path = Path()
        path.addArc(center: point, radius: radius, startAngle: .radians(start), endAngle: .radians(start + length), clockwise: false)
        context.stroke(path, with: .color(color.opacity(opacity)), style: StrokeStyle(lineWidth: width, lineCap: .round))
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
