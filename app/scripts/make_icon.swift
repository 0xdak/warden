// Generates an original placeholder app icon (AppIcon.icns) with CoreGraphics: a shield with a keyhole
// on a teal → deep-blue squircle. Usage: swift scripts/make_icon.swift <output.icns>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("GuardIcon-\(getpid()).iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.09
    let body = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let r = body.width * 0.225
    NSGradient(colors: [NSColor(calibratedRed: 0.10, green: 0.62, blue: 0.60, alpha: 1),
                        NSColor(calibratedRed: 0.06, green: 0.20, blue: 0.38, alpha: 1)])!
        .draw(in: NSBezierPath(roundedRect: body, xRadius: r, yRadius: r), angle: -90)

    // Shield
    let w = body.width * 0.54, h = body.height * 0.62
    let x0 = body.midX - w / 2, top = body.minY + body.height * 0.80
    let shield = NSBezierPath()
    shield.move(to: NSPoint(x: body.midX, y: top + s * 0.02))
    shield.curve(to: NSPoint(x: x0 + w, y: top - h * 0.12), controlPoint1: NSPoint(x: body.midX + w * 0.25, y: top - h * 0.02),
                 controlPoint2: NSPoint(x: x0 + w, y: top - h * 0.06))
    shield.curve(to: NSPoint(x: body.midX, y: top - h), controlPoint1: NSPoint(x: x0 + w, y: top - h * 0.62),
                 controlPoint2: NSPoint(x: body.midX + w * 0.2, y: top - h * 0.86))
    shield.curve(to: NSPoint(x: x0, y: top - h * 0.12), controlPoint1: NSPoint(x: body.midX - w * 0.2, y: top - h * 0.86),
                 controlPoint2: NSPoint(x: x0, y: top - h * 0.62))
    shield.curve(to: NSPoint(x: body.midX, y: top + s * 0.02), controlPoint1: NSPoint(x: x0, y: top - h * 0.06),
                 controlPoint2: NSPoint(x: body.midX - w * 0.25, y: top - h * 0.02))
    shield.close()
    NSColor(white: 1, alpha: 0.95).setFill()
    shield.fill()

    // Keyhole
    let kc = NSPoint(x: body.midX, y: top - h * 0.40)
    let kr = w * 0.12
    NSColor(calibratedRed: 0.07, green: 0.30, blue: 0.42, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: kc.x - kr, y: kc.y - kr, width: kr * 2, height: kr * 2)).fill()
    let slot = NSBezierPath()
    slot.move(to: NSPoint(x: kc.x - kr * 0.45, y: kc.y))
    slot.line(to: NSPoint(x: kc.x + kr * 0.45, y: kc.y))
    slot.line(to: NSPoint(x: kc.x + kr * 0.75, y: kc.y - kr * 2.6))
    slot.line(to: NSPoint(x: kc.x - kr * 0.75, y: kc.y - kr * 2.6))
    slot.close()
    slot.fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! draw(px).write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out]
try! p.run(); p.waitUntilExit()
try? fm.removeItem(at: iconset)
