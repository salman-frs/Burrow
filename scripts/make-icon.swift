// Draws Burrow's icon: a lowercase b dug as a shaft through the top of a block of earth.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit
import SwiftUI

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

let night = color(0x1F2D4C)
let moon = color(0xEFE6D2)

/// The b on the logo's 256-unit grid, where the block spans 16...240 and y grows downward.
struct Shaft {
    let width: CGFloat
    let bowlRadius: CGFloat
    let bowlCenter: CGPoint
    let chamberRadius: CGFloat

    static let regular = Shaft(width: 28, bowlRadius: 60, bowlCenter: CGPoint(x: 136, y: 136), chamberRadius: 32)
    static let small = Shaft(width: 32, bowlRadius: 64, bowlCenter: CGPoint(x: 128, y: 144), chamberRadius: 32)
}

func render(size: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        .retagging(with: .sRGB)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

    let pixels = CGFloat(size)
    let inset = pixels * 0.1
    let body = NSRect(x: inset, y: inset, width: pixels - inset * 2, height: pixels - inset * 2)
    let unit = body.width / 224
    func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: body.minX + (x - 16) * unit, y: body.maxY - (y - 16) * unit)
    }
    func disc(_ center: CGPoint, _ radius: CGFloat) -> NSBezierPath {
        let middle = point(center.x, center.y)
        let r = radius * unit
        return NSBezierPath(ovalIn: NSRect(x: middle.x - r, y: middle.y - r, width: r * 2, height: r * 2))
    }

    let squircle = RoundedRectangle(cornerRadius: body.width * 0.225, style: .continuous).path(in: body).cgPath
    NSBezierPath(cgPath: squircle).addClip()
    night.setFill()
    body.fill()

    let shaft = size <= 32 ? Shaft.small : Shaft.regular
    let shaftBottom = point(shaft.bowlCenter.x - shaft.bowlRadius, shaft.bowlCenter.y)
    moon.setFill()
    NSRect(x: shaftBottom.x, y: shaftBottom.y, width: shaft.width * unit, height: pixels).fill()
    disc(shaft.bowlCenter, shaft.bowlRadius).fill()
    night.setFill()
    disc(shaft.bowlCenter, shaft.chamberRadius).fill()

    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(size: base).write(to: output.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(size: base * 2).write(to: output.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
