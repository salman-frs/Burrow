// Draws Burrow's icon: earth strata in the module minerals under a night sky.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

let minerals: [UInt32] = [0x2FA37A, 0x3E9C8F, 0x3D6FD6, 0x8B6BD9, 0xD9A82E, 0xB8455A]

func render(size: Int) -> Data {
    let pixels = CGFloat(size)
    let image = NSImage(size: NSSize(width: pixels, height: pixels))
    image.lockFocus()
    let inset = pixels * 0.1
    let body = NSRect(x: inset, y: inset, width: pixels - inset * 2, height: pixels - inset * 2)
    let shape = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    NSGraphicsContext.current?.saveGraphicsState()
    shape.addClip()

    NSGradient(starting: color(0x1E2433), ending: color(0x2C3550))?.draw(in: body, angle: 90)

    let bandHeight = body.height * 0.095
    for (index, hex) in minerals.enumerated() {
        let top = body.minY + body.height * 0.58 - CGFloat(index) * bandHeight
        let path = NSBezierPath()
        path.move(to: NSPoint(x: body.minX, y: top))
        path.curve(to: NSPoint(x: body.maxX, y: top - bandHeight * 0.35),
                   controlPoint1: NSPoint(x: body.minX + body.width * 0.35, y: top + bandHeight * 0.55),
                   controlPoint2: NSPoint(x: body.minX + body.width * 0.62, y: top - bandHeight * 0.9))
        path.line(to: NSPoint(x: body.maxX, y: body.minY))
        path.line(to: NSPoint(x: body.minX, y: body.minY))
        path.close()
        color(hex).withAlphaComponent(1 - CGFloat(index) * 0.06).setFill()
        path.fill()
    }

    let hole = NSRect(x: body.midX - body.width * 0.09, y: body.minY + body.height * 0.56,
                      width: body.width * 0.18, height: body.width * 0.11)
    color(0x141824).setFill()
    NSBezierPath(ovalIn: hole).fill()

    NSGraphicsContext.current?.restoreGraphicsState()
    image.unlockFocus()

    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    return bitmap.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(size: base).write(to: output.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(size: base * 2).write(to: output.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
