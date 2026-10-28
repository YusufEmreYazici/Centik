// Draws the app icon and writes Resources/AppIcon.icns. Usage: swift tools/make-icon.swift <Resources dir>
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Squircle background with a deep indigo gradient.
    let inset = s * 0.1
    let body = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let bg = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    NSGradient(colors: [NSColor(red: 0.16, green: 0.12, blue: 0.36, alpha: 1), NSColor(red: 0.04, green: 0.04, blue: 0.1, alpha: 1)])!
        .draw(in: bg, angle: -90)

    // The island hanging from the top edge.
    let w = body.width * 0.62, h = body.height * 0.2
    let island = NSRect(x: body.midX - w / 2, y: body.maxY - h - body.height * 0.16, width: w, height: h)
    NSColor.black.setFill()
    NSBezierPath(roundedRect: island, xRadius: h / 2, yRadius: h / 2).fill()

    // Glowing activity dot and bars inside the island.
    let dot = h * 0.42
    NSColor(red: 0.45, green: 0.95, blue: 0.6, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: island.minX + h * 0.35, y: island.midY - dot / 2, width: dot, height: dot)).fill()
    NSColor(red: 0.7, green: 0.6, blue: 1, alpha: 1).setFill()
    for (i, f) in [0.45, 0.8, 0.6, 0.35].enumerated() {
        let bw = h * 0.12, bh = h * 0.62 * f
        let x = island.maxX - h * 0.4 - CGFloat(4 - i) * bw * 1.9
        NSBezierPath(roundedRect: NSRect(x: x, y: island.midY - bh / 2, width: bw, height: bh), xRadius: bw / 2, yRadius: bw / 2).fill()
    }

    // Soft light from the island.
    let glow = NSRect(x: body.midX - w * 0.6, y: body.minY + body.height * 0.12, width: w * 1.2, height: body.height * 0.42)
    NSGradient(colors: [NSColor(red: 0.55, green: 0.45, blue: 1, alpha: 0.35), .clear])!
        .draw(in: NSBezierPath(ovalIn: glow), relativeCenterPosition: .zero)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try draw(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try draw(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", outDir.appendingPathComponent("AppIcon.icns").path]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "AppIcon.icns written" : "iconutil failed")
