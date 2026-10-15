import AppKit

let dir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let w = CGFloat(pixels)
        let rect = NSRect(x: w * 0.05, y: w * 0.05, width: w * 0.9, height: w * 0.9)
        NSColor(calibratedRed: 0.075, green: 0.12, blue: 0.10, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: w * 0.22, yRadius: w * 0.22).fill()
        NSColor(calibratedRed: 0.63, green: 0.9, blue: 0.75, alpha: 0.12).setFill()
        NSBezierPath(ovalIn: NSRect(x: w * 0.19, y: w * 0.19, width: w * 0.62, height: w * 0.62)).fill()
        NSColor(calibratedRed: 0.63, green: 0.9, blue: 0.75, alpha: 1).setFill()
        let p = NSBezierPath()
        p.move(to: NSPoint(x: w * 0.5, y: w * 0.79))
        p.curve(to: NSPoint(x: w * 0.79, y: w * 0.5), controlPoint1: NSPoint(x: w * 0.55, y: w * 0.56), controlPoint2: NSPoint(x: w * 0.56, y: w * 0.55))
        p.curve(to: NSPoint(x: w * 0.5, y: w * 0.21), controlPoint1: NSPoint(x: w * 0.56, y: w * 0.45), controlPoint2: NSPoint(x: w * 0.55, y: w * 0.44))
        p.curve(to: NSPoint(x: w * 0.21, y: w * 0.5), controlPoint1: NSPoint(x: w * 0.45, y: w * 0.44), controlPoint2: NSPoint(x: w * 0.44, y: w * 0.45))
        p.curve(to: NSPoint(x: w * 0.5, y: w * 0.79), controlPoint1: NSPoint(x: w * 0.44, y: w * 0.55), controlPoint2: NSPoint(x: w * 0.45, y: w * 0.56))
        p.close(); p.fill()
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name))
    }
}
