import Foundation
import CoreGraphics

/// Keep the panel on a current screen without losing a valid secondary-screen position.
enum WindowPlacement {
    static func visibleFrame(_ proposed: CGRect, screens: [CGRect], fallbackIndex: Int, margin: CGFloat = 8) -> CGRect {
        guard !screens.isEmpty else { return proposed }
        let fallback = screens.indices.contains(fallbackIndex) ? fallbackIndex : 0
        let selected = screens.enumerated().compactMap { index, screen -> (Int, CGFloat)? in
            let overlap = proposed.intersection(screen)
            guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { return nil }
            return (index, overlap.width * overlap.height)
        }.max { $0.1 < $1.1 }?.0 ?? fallback
        let screen = screens[selected]
        let safeMargin = max(0, min(margin, screen.width / 2, screen.height / 2))
        let left = screen.minX + safeMargin
        let bottom = screen.minY + safeMargin
        let right = screen.maxX - safeMargin - proposed.width
        let top = screen.maxY - safeMargin - proposed.height
        let x = right >= left ? min(max(proposed.minX, left), right) : left
        // An oversized panel keeps its top controls visible rather than its footer.
        let y = top >= bottom ? min(max(proposed.minY, bottom), top) : top
        return CGRect(x: x, y: y, width: proposed.width, height: proposed.height)
    }
}
