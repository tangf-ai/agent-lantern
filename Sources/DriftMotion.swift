import Foundation
import CoreGraphics

enum DriftArea: String, CaseIterable {
    case edges
    case top
    case bottom
    case middle
    case right

    var title: String {
        switch self {
        case .edges: return "屏幕四周"
        case .top: return "屏幕上部"
        case .bottom: return "屏幕底部"
        case .middle: return "屏幕中部"
        case .right: return "屏幕右侧"
        }
    }
}

/// Routes use Cocoa screen coordinates; the Dock/menu bar are excluded by visibleFrame.
struct DriftRoute {
    static let lightSize: CGFloat = 52
    let bounds: CGRect
    let area: DriftArea
    var perimeter: CGFloat {
        switch area {
        case .edges: return max(1, (bounds.width + bounds.height) * 2)
        case .right: return max(1, bounds.height * 2)
        case .top, .bottom, .middle: return max(1, bounds.width * 2)
        }
    }
    var horizontalY: CGFloat? {
        switch area {
        case .edges: return nil
        case .top: return bounds.maxY
        case .bottom: return bounds.minY
        case .middle: return bounds.midY
        case .right: return nil
        }
    }
    var verticalX: CGFloat? { area == .right ? bounds.maxX : nil }

    init(screen: CGRect, area: DriftArea = .edges) {
        self.area = area
        let inset = Self.lightSize / 2 + 18
        let dx = min(inset, max(0, screen.width / 2))
        let dy = min(inset, max(0, screen.height / 2))
        bounds = screen.insetBy(dx: dx, dy: dy)
    }

    func point(at distance: CGFloat) -> CGPoint {
        var d = (distance.truncatingRemainder(dividingBy: perimeter) + perimeter)
            .truncatingRemainder(dividingBy: perimeter)
        if let y = horizontalY {
            // Retrace the horizontal route so wrapping never teleports to the opposite side.
            let x = d <= bounds.width ? bounds.maxX - d : bounds.minX + d - bounds.width
            return CGPoint(x: min(max(x, bounds.minX), bounds.maxX), y: y)
        }
        if let x = verticalX {
            let y = d <= bounds.height ? bounds.maxY - d : bounds.minY + d - bounds.height
            return CGPoint(x: x, y: min(max(y, bounds.minY), bounds.maxY))
        }
        if d <= bounds.height { return CGPoint(x: bounds.maxX, y: bounds.maxY - d) }
        d -= bounds.height
        if d <= bounds.width { return CGPoint(x: bounds.maxX - d, y: bounds.minY) }
        d -= bounds.width
        if d <= bounds.height { return CGPoint(x: bounds.minX, y: bounds.minY + d) }
        d -= bounds.height
        return CGPoint(x: bounds.minX + min(d, bounds.width), y: bounds.maxY)
    }

    func nearestDistance(to point: CGPoint) -> CGFloat {
        let x = min(max(point.x, bounds.minX), bounds.maxX)
        let y = min(max(point.y, bounds.minY), bounds.maxY)
        if horizontalY != nil { return bounds.maxX - x }
        if verticalX != nil { return bounds.maxY - y }
        let candidates = [bounds.maxY - y, bounds.height + bounds.maxX - x,
                          bounds.height + bounds.width + y - bounds.minY,
                          bounds.height * 2 + bounds.width + x - bounds.minX]
        return candidates.min { a, b in
            let p = self.point(at: a), q = self.point(at: b)
            return hypot(p.x - point.x, p.y - point.y) < hypot(q.x - point.x, q.y - point.y)
        } ?? 0
    }
}

struct DriftMotion {
    private(set) var route: DriftRoute
    private(set) var distance: CGFloat = 0
    private(set) var avoiding = false
    private var lastTime: Double?
    private var escapeRemaining: CGFloat = 0
    private var cooldownUntil: Double = 0
    private var floatTime: Double = 0

    init(screen: CGRect, area: DriftArea = .edges) { route = DriftRoute(screen: screen, area: area) }

    var center: CGPoint { route.point(at: distance) }
    var frame: CGRect {
        let side = DriftRoute.lightSize
        let bob = sin(floatTime * 0.7) * 2
        return CGRect(x: center.x - side / 2, y: center.y - side / 2 + bob, width: side, height: side)
    }

    mutating func setScreen(_ screen: CGRect) {
        let next = DriftRoute(screen: screen, area: route.area)
        guard next.bounds != route.bounds else { return }
        let previous = center
        route = next
        distance = route.nearestDistance(to: previous)
        pause()
    }

    mutating func setArea(_ area: DriftArea, screen: CGRect) {
        guard area != route.area else { setScreen(screen); return }
        let previous = center
        route = DriftRoute(screen: screen, area: area)
        distance = route.nearestDistance(to: previous)
        pause()
    }

    mutating func park(near point: CGPoint) {
        distance = route.nearestDistance(to: point)
        pause()
    }

    mutating func pause() {
        lastTime = nil
        escapeRemaining = 0
        avoiding = false
    }

    mutating func advance(at time: Double, mouse: CGPoint?, working: Bool, enabled: Bool) {
        guard time.isFinite else { return }
        let dt = min(0.1, max(0, time - (lastTime ?? time)))
        lastTime = time
        guard enabled else { escapeRemaining = 0; avoiding = false; return }
        if let mouse, time >= cooldownUntil, abs(escapeRemaining) < 1,
           hypot(mouse.x - center.x, mouse.y - center.y) < 105 {
            let step = min(210, route.perimeter / 3)
            let forward = route.point(at: distance + step)
            let backward = route.point(at: distance - step)
            let a = hypot(forward.x - mouse.x, forward.y - mouse.y)
            let b = hypot(backward.x - mouse.x, backward.y - mouse.y)
            escapeRemaining = a >= b ? step : -step
            cooldownUntil = time + 2.5
        }
        avoiding = abs(escapeRemaining) > 0.01
        if avoiding {
            let step = min(abs(escapeRemaining), 135 * dt) * (escapeRemaining < 0 ? -1 : 1)
            distance += step
            escapeRemaining -= step
        } else if working {
            distance += 6 * dt
            floatTime += dt
        }
        distance = (distance.truncatingRemainder(dividingBy: route.perimeter) + route.perimeter)
            .truncatingRemainder(dividingBy: route.perimeter)
    }
}

enum DriftScreenPolicy {
    static func isFullScreen(window: CGRect, screen: CGRect) -> Bool {
        abs(window.minX - screen.minX) <= 4 && abs(window.minY - screen.minY) <= 4 &&
        abs(window.width - screen.width) <= 4 && abs(window.height - screen.height) <= 4
    }
}
