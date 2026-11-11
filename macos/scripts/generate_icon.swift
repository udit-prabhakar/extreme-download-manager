import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)!
        let s = Double(pixels)
        let bounds = NSRect(x: s * 0.08, y: s * 0.08, width: s * 0.84, height: s * 0.84)
        let background = NSBezierPath(roundedRect: bounds, xRadius: s * 0.19, yRadius: s * 0.19)
        NSGradient(starting: NSColor(calibratedRed: 0.13, green: 0.70, blue: 0.60, alpha: 1), ending: NSColor(calibratedRed: 0.02, green: 0.36, blue: 0.34, alpha: 1))!.draw(in: background, angle: -55)
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: s * 0.5, y: s * 0.73))
        arrow.line(to: NSPoint(x: s * 0.5, y: s * 0.38))
        arrow.move(to: NSPoint(x: s * 0.35, y: s * 0.52))
        arrow.line(to: NSPoint(x: s * 0.5, y: s * 0.37))
        arrow.line(to: NSPoint(x: s * 0.65, y: s * 0.52))
        arrow.move(to: NSPoint(x: s * 0.31, y: s * 0.29))
        arrow.line(to: NSPoint(x: s * 0.69, y: s * 0.29))
        arrow.lineWidth = s * 0.055
        arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
        NSColor.white.setStroke(); arrow.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
    }
}
