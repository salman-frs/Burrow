import AppKit
import SwiftUI

/// The macOS 27 SDK resolves `@State` to a macro whose plugin ships only with Xcode;
/// the alias reaches the property wrapper directly so Command Line Tools can build the app.
typealias ViewState = SwiftUI.State

enum Metrics {
    static let inset: CGFloat = 8
    static let sidebarWidth: CGFloat = 214
    static let inspectorWidth: CGFloat = 328
    static let panelRadius: CGFloat = 18
    static let contentX: CGFloat = inset + sidebarWidth + 30
    static let heroTop: CGFloat = 34
}

enum Palette {
    static let amber = Color(light: 0xEC9300, dark: 0xFFB547)
    static let amberHot = Color(light: 0xF5AE2E, dark: 0xFFD592)
    static let amberInk = Color(light: 0x241500, dark: 0x2B1900)
    static let amberText = Color(light: 0x9A5800, dark: 0xFFC46A)
    static let ok = Color(light: 0x2E9E57, dark: 0x7FD69A)
    static let danger = Color(light: 0xC2410C, dark: 0xFF8A65)
    static let windowTop = Color(light: 0xFAFAFB, dark: 0x121521)
    static let windowBottom = Color(light: 0xF0F1F3, dark: 0x0B0C11)
    static let hairline = Color.primary.opacity(0.08)
    static let hover = Color.primary.opacity(0.06)
    static let selected = Color.primary.opacity(0.1)
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

enum ByteText {
    static func parts(_ bytes: Int64) -> (value: String, unit: String) {
        let value = Double(max(bytes, 0))
        if value >= 100e9 { return (String(Int((value / 1e9).rounded())), "GB") }
        if value >= 1e9 { return (String(format: "%.1f", value / 1e9), "GB") }
        if value >= 1e6 { return (String(Int((value / 1e6).rounded())), "MB") }
        if value == 0 { return ("0", "KB") }
        return (String(max(1, Int((value / 1e3).rounded()))), "KB")
    }

    static func string(_ bytes: Int64) -> String {
        let (value, unit) = parts(bytes)
        return "\(value) \(unit)"
    }

    /// Memory is sold and reported in binary units: 8 GB of RAM is 8 × 2³⁰ bytes.
    static func memory(_ bytes: Int64) -> String {
        let value = Double(max(bytes, 0))
        guard value >= gibibyte else { return "\(Int((value / 1_048_576).rounded())) MB" }
        let gigabytes = String(format: "%.1f", value / gibibyte)
        return (gigabytes.hasSuffix(".0") ? String(gigabytes.dropLast(2)) : gigabytes) + " GB"
    }

    static let gibibyte = 1_073_741_824.0
}

extension Font {
    static func figure(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold) }
}
