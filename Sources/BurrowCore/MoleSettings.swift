import Foundation

public struct PatternFile: Sendable {
    public let url: URL
    public let header: String

    public static let cleanWhitelist = PatternFile(
        url: configDirectory.appendingPathComponent("whitelist"),
        header: """
            # Mole Whitelist - Protected paths won't be deleted
            # Saved selections replace optional defaults; built-in safety protections still apply.
            # Add one pattern per line to keep items safe.
            """
    )

    public static let purgePaths = PatternFile(
        url: configDirectory.appendingPathComponent("purge_paths"),
        header: """
            # Mole Purge Paths - Directories to scan for project artifacts
            # Add one path per line (supports ~ for home directory)
            # Delete all paths or this file to use defaults
            """
    )

    static var configDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/mole")
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    public func read() throws -> [String]? {
        guard exists else { return nil }
        return Self.patterns(in: try String(contentsOf: url, encoding: .utf8))
    }

    public func write(_ patterns: [String]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let body = ([header, ""] + patterns).joined(separator: "\n") + "\n"
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    static func patterns(in text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}

public enum PatternRules {
    private static let systemRoots = ["/", "/System", "/bin", "/sbin", "/usr/bin", "/usr/sbin", "/etc", "/var/db"]

    /// The same checks, in the same order, as Mole's whitelist loader in `lib/core/base.sh`, which
    /// skips a failing line with only a warning: a path saved here must never be silently dropped there.
    public static func problem(with pattern: String) -> String? {
        if pattern.contains("..") { return "Patterns cannot contain “..”." }
        if pattern == "FINDER_METADATA" { return nil }
        if pattern.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            return "Patterns cannot contain control characters."
        }
        let expanded = Paths.expandingTilde(pattern)
        if !expanded.hasPrefix("/") { return "Use an absolute path or one starting with ~/." }
        if expanded.contains("//") { return "Remove the double slash." }
        if systemRoots.contains(where: { expanded == $0 || ($0 != "/" && expanded.hasPrefix($0 + "/")) }) {
            return "Mole never cleans system paths, so they need no protection here."
        }
        return nil
    }
}

/// Reads Mole's optional default whitelist from the pinned `lib/core/base.sh`, because an
/// existing whitelist file replaces those defaults and Burrow must write them out to keep them.
public enum MoleDefaults {
    public static func cleanWhitelist(moleExecutable: URL) -> [String] {
        let base = moleExecutable.deletingLastPathComponent().appendingPathComponent("lib/core/base.sh")
        guard let source = try? String(contentsOf: base, encoding: .utf8) else { return [] }
        return arrayLiteral(named: "DEFAULT_WHITELIST_PATTERNS", in: source).map { entry in
            entry.replacingOccurrences(of: "$HOME", with: "~")
                .replacingOccurrences(of: "$FINDER_METADATA_SENTINEL", with: "FINDER_METADATA")
        }
    }

    static func arrayLiteral(named name: String, in source: String) -> [String] {
        guard let start = source.range(of: "\(name)=(") else { return [] }
        let rest = source[start.upperBound...]
        guard let end = rest.range(of: "\n)") else { return [] }
        return rest[..<end.lowerBound].components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 else { return nil }
            return String(trimmed.dropFirst().dropLast())
        }
    }
}

public enum TouchIDState: Sendable, Equatable {
    case enabled, disabled, unknown
}

public enum TouchIDWorkflow {
    public static func state(with runner: MoleRunner) async -> TouchIDState {
        guard let result = try? await runner.capture(["touchid", "status"]) else { return .unknown }
        let text = TerminalText.plain(String(decoding: result.output, as: UTF8.self)).lowercased()
        if text.contains("not configured") || text.contains("disabled") { return .disabled }
        if text.contains("enabled") || text.contains("configured") { return .enabled }
        return .unknown
    }
}
