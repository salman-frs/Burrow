import SwiftUI

enum Module: String, CaseIterable, Identifiable, Hashable {
    case overview, cleanup, optimize
    case uninstaller, slim
    case spaceLens, projects, installers
    case history, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .cleanup: "Cleanup"
        case .optimize: "Optimize"
        case .uninstaller: "Uninstaller"
        case .slim: "App Slimming"
        case .spaceLens: "Space Lens"
        case .projects: "Project Purge"
        case .installers: "Installers"
        case .history: "History"
        case .settings: "Settings"
        }
    }

    var summary: String {
        switch self {
        case .overview: "How your Mac is doing right now."
        case .cleanup: "Caches, logs and leftovers that macOS and your apps rebuild on their own."
        case .optimize: "Refresh caches and services that tend to go stale."
        case .uninstaller: "Remove apps together with the files they leave behind."
        case .slim: "Drop the Intel code from universal apps on Apple Silicon."
        case .spaceLens: "See what takes up your disk, folder by folder."
        case .projects: "Build output and dependencies from projects you haven't touched in a week."
        case .installers: "Disk images, packages and archives you already installed from."
        case .history: "Everything Mole has removed or changed on this Mac."
        case .settings: "Protected paths, scan folders and administrator access."
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .cleanup: "sparkles"
        case .optimize: "bolt.horizontal"
        case .uninstaller: "xmark.app"
        case .slim: "scissors"
        case .spaceLens: "circle.hexagongrid"
        case .projects: "hammer"
        case .installers: "shippingbox"
        case .history: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }

    var accent: Color {
        switch self {
        case .overview: Mineral.quartz
        case .cleanup: Mineral.malachite
        case .optimize: Mineral.citrine
        case .uninstaller: Mineral.azurite
        case .slim: Mineral.topaz
        case .spaceLens: Mineral.amethyst
        case .projects: Mineral.jade
        case .installers: Mineral.garnet
        case .history, .settings: Mineral.hematite
        }
    }

    static let sidebarGroups: [(title: String, modules: [Module])] = [
        ("Maintain", [.overview, .cleanup, .optimize]),
        ("Apps", [.uninstaller, .slim]),
        ("Files", [.spaceLens, .projects, .installers]),
        ("Burrow", [.history, .settings]),
    ]
}

enum Mineral {
    static let quartz = Color(hex: 0x8F9CC0)
    static let malachite = Color(hex: 0x2FA37A)
    static let citrine = Color(hex: 0xD9A82E)
    static let azurite = Color(hex: 0x3D6FD6)
    static let topaz = Color(hex: 0xD4843A)
    static let amethyst = Color(hex: 0x8B6BD9)
    static let jade = Color(hex: 0x3E9C8F)
    static let garnet = Color(hex: 0xB8455A)
    static let hematite = Color(hex: 0x7D838E)

    static func layer(_ base: Color, index: Int, of count: Int) -> Color {
        guard count > 1 else { return base }
        let depth = Double(index) / Double(count - 1)
        return base.opacity(0.95 - depth * 0.62)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

extension Font {
    static func figure(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .serif)
    }
}

private struct ModuleAccentKey: EnvironmentKey {
    static let defaultValue: Color = Mineral.quartz
}

extension EnvironmentValues {
    var moduleAccent: Color {
        get { self[ModuleAccentKey.self] }
        set { self[ModuleAccentKey.self] = newValue }
    }
}

/// The macOS 27 SDK resolves `@State` to a macro whose plugin ships only with Xcode;
/// the alias reaches the property wrapper directly so Command Line Tools can build the app.
typealias ViewState = SwiftUI.State
