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
    static let accent = AccentStyle(role: .fill)
    static let accentBright = AccentStyle(role: .bright)
    static let onAccent = AccentStyle(role: .ink)
    static let accentText = AccentStyle(role: .text)
    static let done = AccentStyle(role: .done)
    static let danger = Color(light: 0xC2410C, dark: 0xFF8A65)
    static let windowTop = Color(light: 0xE9E6E0, dark: 0x121521)
    static let windowBottom = Color(light: 0xE0DCD6, dark: 0x0B0C11)
    static let hairline = Color.primary.opacity(0.08)
    static let hover = Color.primary.opacity(0.06)
    static let selected = Color.primary.opacity(0.1)
}

enum AccentPalette: String, CaseIterable, Identifiable {
    case moonlight, ember, lagoon, iris

    static let storageKey = "palette"

    var id: Self { self }

    var name: String { rawValue.capitalized }

    var accent: Accent {
        switch self {
        case .moonlight:
            Accent(fill: Tone(light: 0x1F2D4C, dark: 0xEFE6D2), bright: Tone(light: 0x0F1A33, dark: 0xFFFFFF),
                   ink: Tone(light: 0xF4F1EC, dark: 0x1A1914), text: Tone(light: 0x1F2D4C, dark: 0xF1E8D6),
                   done: Tone(light: 0x3B6186, dark: 0x9CCEDA), spark: Tone(light: 0xFFFFFF, dark: 0xFFFFFF), glow: 0.045)
        case .ember:
            Accent(fill: Tone(light: 0xA7391E, dark: 0xF69370), bright: Tone(light: 0x8B2000, dark: 0xFFC0AA),
                   ink: Tone(light: 0xFFF6F2, dark: 0x3A1407), text: Tone(light: 0x962F16, dark: 0xF8A88B),
                   done: Tone(light: 0x2E6F80, dark: 0x9CCEDA), spark: Tone(light: 0xFFF1EA, dark: 0xFFF1EA), glow: 0.1)
        case .lagoon:
            Accent(fill: Tone(light: 0x006A77, dark: 0x7DD5DA), bright: Tone(light: 0x00515C, dark: 0xAFF3F6),
                   ink: Tone(light: 0xF0FBFC, dark: 0x06292C), text: Tone(light: 0x005A66, dark: 0x92DEE2),
                   done: Tone(light: 0x4E5A92, dark: 0xB9C3E8), spark: Tone(light: 0xEFFDFE, dark: 0xEFFDFE), glow: 0.1)
        case .iris:
            Accent(fill: Tone(light: 0x4449AF, dark: 0xA7B0FD), bright: Tone(light: 0x313095, dark: 0xCED4FF),
                   ink: Tone(light: 0xF6F6FF, dark: 0x12163A), text: Tone(light: 0x383D9C, dark: 0xB9C1FF),
                   done: Tone(light: 0x2E6F80, dark: 0x9CCEDA), spark: Tone(light: 0xF1F3FF, dark: 0xF1F3FF), glow: 0.1)
        }
    }
}

struct Tone: Equatable {
    let light: UInt32
    let dark: UInt32

    var color: Color { Color(light: light, dark: dark) }

    func hex(for scheme: ColorScheme) -> UInt32 { scheme == .dark ? dark : light }
}

struct Accent: Equatable {
    let fill: Tone
    let bright: Tone
    let ink: Tone
    let text: Tone
    let done: Tone
    let spark: Tone
    let glow: Double
}

/// Resolves against the palette in the environment, so a view picks up a new palette without reading it itself.
struct AccentStyle: ShapeStyle {
    enum Role { case fill, bright, ink, text, done }

    let role: Role

    func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        let accent = environment.accent
        let tone = switch role {
        case .fill: accent.fill
        case .bright: accent.bright
        case .ink: accent.ink
        case .text: accent.text
        case .done: accent.done
        }
        let hex = tone.hex(for: environment.colorScheme)
        return Color.Resolved(red: Float((hex >> 16) & 0xFF) / 255, green: Float((hex >> 8) & 0xFF) / 255,
                              blue: Float(hex & 0xFF) / 255)
    }
}

private struct AccentKey: EnvironmentKey {
    static let defaultValue = AccentPalette.moonlight.accent
}

extension EnvironmentValues {
    var accent: Accent {
        get { self[AccentKey.self] }
        set { self[AccentKey.self] = newValue }
    }
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
