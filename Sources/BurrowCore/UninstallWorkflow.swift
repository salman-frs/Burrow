import Foundation

public struct UninstallPlan: Sendable, Equatable {
    public struct App: Sendable, Equatable, Identifiable {
        public let name: String
        public let sizeLabel: String
        public let viaHomebrew: Bool
        public let isRunning: Bool
        public var files: [String] = []
        public var systemPaths: [String] = []
        public var reviewOnly: [String] = []
        public var id: String { name }
    }

    public var apps: [App] = []
    public var personalDataRemoved: [String] = []
    public var personalDataKept: [String] = []
    public var notes: [String] = []
}

public enum UninstallPlanParser {
    private enum Block { case none, files, personalRemoved, personalKept }

    public static func parse(_ text: String) -> UninstallPlan {
        var plan = UninstallPlan()
        var block = Block.none
        let headings: [String: Block] = [
            "Files to be removed:": .files,
            "Personal data to remove:": .personalRemoved,
            "Personal data kept:": .personalKept,
        ]

        for rawLine in text.components(separatedBy: CharacterSet(charactersIn: "\r\n")) {
            let line = TerminalText.plain(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if let next = headings[trimmed] {
                block = next
                continue
            }
            if trimmed.hasPrefix("➤") || trimmed.hasPrefix("D choose") || trimmed.hasPrefix("=====") {
                block = .none
                continue
            }
            let indented = line.hasPrefix("  ")
            let marker = trimmed.first
            let body = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)

            switch block {
            case .files where !indented && marker == "◎":
                plan.apps.append(app(fromHeader: body))
            case .files where indented && !plan.apps.isEmpty:
                let last = plan.apps.count - 1
                if body.hasPrefix("System: ") {
                    plan.apps[last].systemPaths.append(Paths.expandingTilde(String(body.dropFirst(8))))
                } else if body.hasPrefix("Review only: ") {
                    plan.apps[last].reviewOnly.append(Paths.expandingTilde(String(body.dropFirst(13))))
                } else if marker == "✓" {
                    plan.apps[last].files.append(Paths.expandingTilde(path(beforeSize: body)))
                } else {
                    plan.notes.append(trimmed)
                }
            case .personalRemoved where indented:
                plan.personalDataRemoved.append(Paths.expandingTilde(path(beforeSize: body)))
            case .personalKept where indented:
                plan.personalDataKept.append(Paths.expandingTilde(path(beforeSize: body)))
            case .files, .personalRemoved, .personalKept:
                plan.notes.append(trimmed)
            case .none:
                if (marker == "◎" || marker == "☻"), !body.hasPrefix("Matched ") { plan.notes.append(body) }
            }
        }
        return plan
    }

    private static func app(fromHeader body: String) -> UninstallPlan.App {
        var name = body
        var size = ""
        if let separator = body.range(of: " , ", options: .backwards) {
            name = String(body[..<separator.lowerBound])
            size = String(body[separator.upperBound...])
        }
        let running = name.contains("[Running]") || size.contains("[Running]")
        let brew = name.contains("[Brew]")
        for tag in ["[Brew]", "[Running]"] {
            name = name.replacingOccurrences(of: tag, with: "")
            size = size.replacingOccurrences(of: tag, with: "")
        }
        return UninstallPlan.App(name: name.trimmingCharacters(in: .whitespaces),
                                 sizeLabel: size.trimmingCharacters(in: .whitespaces),
                                 viaHomebrew: brew, isRunning: running)
    }

    private static func path(beforeSize body: String) -> String {
        guard let separator = body.range(of: " , ", options: .backwards) else { return body }
        return String(body[..<separator.lowerBound])
    }
}

public enum UninstallWorkflow {
    public static func installedApps(with runner: MoleRunner) async throws -> [InstalledApp] {
        let result = try await runner.capture(["uninstall", "--list"])
        return try MoleJSON.decode([InstalledApp].self, from: result.output)
    }

    /// Mole 1.69 lists a Homebrew cask token as `uninstall_name` but matches only display and
    /// `.app` folder names, so Burrow passes the folder name, which Mole matches exactly.
    static func arguments(for apps: [InstalledApp], withData: Bool, dryRun: Bool) -> [String] {
        var arguments = ["uninstall"]
        if dryRun { arguments.append("--dry-run") }
        if withData { arguments.append("--with-data") }
        return arguments + apps.map(matchName)
    }

    static func matchName(for app: InstalledApp) -> String {
        let folder = URL(fileURLWithPath: app.path).lastPathComponent
        return folder.lowercased().hasSuffix(".app") ? String(folder.dropLast(4)) : app.uninstallName
    }

    /// Mole picks the first installed app whose display or folder name equals the name it is
    /// given, so a name another installed app also answers to could reach the wrong one.
    public static func ambiguous(_ selection: [InstalledApp], among installed: [InstalledApp]) -> [InstalledApp] {
        selection.filter { app in
            let name = matchName(for: app).lowercased()
            return installed.filter { other in
                other.name.lowercased() == name || matchName(for: other).lowercased() == name
            }.count > 1
        }
    }

    public static func preview(_ apps: [InstalledApp], withData: Bool, with runner: MoleRunner) async throws -> UninstallPlan {
        let result = try await runner.capture(arguments(for: apps, withData: withData, dryRun: true))
        return UninstallPlanParser.parse(String(decoding: result.output, as: UTF8.self))
    }

    /// Mole's plan lists each app's own bundle path first, so the check ties every planned app
    /// to the exact bundle the user picked, not just to a matching name.
    static func confirmationMatches(_ screen: String, apps: [InstalledApp], withData: Bool) -> Bool {
        guard let promptLine = screen.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
            .last(where: { $0.contains("Enter confirm") })
        else { return false }
        let plan = UninstallPlanParser.parse(screen)
        guard promptLine.contains("Remove \(apps.count) app"),
              withData || !promptLine.contains("including personal data"),
              plan.apps.count == apps.count
        else { return false }
        var unmatched = apps
        for planned in plan.apps {
            guard let index = unmatched.firstIndex(where: { planned.files.contains($0.path) }) else { return false }
            unmatched.remove(at: index)
        }
        return unmatched.isEmpty
    }

    public static func uninstall(_ apps: [InstalledApp], among installed: [InstalledApp], withData: Bool,
                                 with runner: MoleRunner, admin: @escaping AdminPasswordProvider) async throws -> RemovalOutcome {
        let unclear = ambiguous(apps, among: installed)
        guard unclear.isEmpty else {
            throw RunError.planMismatch("another app shares the name of \(unclear.map(\.name).joined(separator: ", ")). Uninstall it from Terminal with mo uninstall.")
        }
        let session = try runner.start(arguments(for: apps, withData: withData, dryRun: false),
                                       options: SessionOptions(interactive: true, admin: admin))
        try await session.beforeConfirmation {
            let confirmation = try await session.waitForScreen(since: 0, timeout: 300, step: "reviewing the apps") {
                $0.contains("Enter confirm")
            }
            guard confirmationMatches(confirmation, apps: apps, withData: withData) else {
                throw RunError.planMismatch("Mole's uninstall plan did not match your selection.")
            }
        }
        return try await session.confirmAndFinish()
    }
}
