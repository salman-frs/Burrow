import Foundation

public struct InstallerFile: Sendable, Equatable, Identifiable, Hashable {
    /// The row exactly as Mole's menu draws it, which is how the real run finds it again.
    public let row: String
    public let name: String
    public let sizeLabel: String
    public let source: String
    public var bytes: Int64? { ByteSize.firstSize(in: sizeLabel) }
    public var id: String { row }
}

public struct RemovalOutcome: Sendable, Equatable {
    public let exitCode: Int32
    public let summary: [String]
    public let transcript: String

    public var succeeded: Bool { exitCode == 0 }
}

extension MoleSession {
    /// Mole drains pending input right after it prints a confirm prompt, so a key sent the
    /// moment the prompt appears can be discarded. Enter is sent once, after the drain; a second
    /// Enter could answer whatever Mole asks next, such as a sudo password prompt.
    func confirmAndFinish() async throws -> RemovalOutcome {
        do {
            try await Task.sleep(for: .seconds(1))
            let mark = mark()
            send(.enter)
            _ = try await waitForScreen(since: mark, timeout: 15, step: "waiting for Mole to accept the confirmation") {
                !$0.isEmpty
            }
        } catch {
            interrupt()
            _ = try? await exitCode()
            throw error
        }
        let code = try await exitCode()
        let screen = screen()
        return RemovalOutcome(exitCode: code, summary: Rows.summary(in: screen), transcript: screen)
    }

    /// Runs the steps before Mole's confirmation. Nothing has been removed while they run, so a
    /// failure backs out of the menu and may stop Mole forcefully if it does not quit.
    func beforeConfirmation(_ steps: () async throws -> Void) async throws {
        do {
            try await steps()
        } catch {
            send(.escape)
            send(.text("q"))
            interrupt(force: true)
            _ = try? await exitCode()
            throw error
        }
    }
}

enum Rows {
    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func summary(in screen: String) -> [String] {
        let lines = screen.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = lines.lastIndex(where: { $0.hasPrefix("=====") }),
              let first = lines[..<last].lastIndex(where: { $0.hasPrefix("=====") })
        else { return [] }
        return lines[(first + 1)..<last].filter { !$0.isEmpty }
    }

    static func confirmationList(in screen: String, heading: String) -> [String]? {
        guard let headingRange = screen.range(of: heading, options: .backwards) else { return nil }
        let body = screen[headingRange.upperBound...]
        guard let prompt = body.range(of: "Enter confirm") else { return nil }
        return body[..<prompt.lowerBound]
            .components(separatedBy: CharacterSet(charactersIn: "\r\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// Drives one of Mole's selection menus to exactly `targets`, then confirms only when Mole's
/// own confirmation screen satisfies `matches`.
struct MenuRemoval {
    let session: MoleSession
    let title: String
    let identity: @Sendable (MenuFrame) -> String?
    let menuTimeout: TimeInterval

    func run(_ targets: Set<String>, confirmationTimeout: TimeInterval,
             matches: @escaping (String) -> Bool) async throws -> RemovalOutcome {
        let driver = MenuDriver(session: session, title: title, identity: identity)
        try await session.beforeConfirmation {
            let first = try await driver.waitForMenu(timeout: menuTimeout)
            try await driver.select(targets, startingAt: first)
            let mark = session.mark()
            session.send(.enter)
            let confirmation = try await session.waitForScreen(
                since: mark, timeout: confirmationTimeout, step: "preparing the removal"
            ) { $0.contains("Enter confirm") }
            guard matches(confirmation) else {
                throw RunError.planMismatch("Mole's removal list did not match your selection.")
            }
        }
        return try await session.confirmAndFinish()
    }
}

// MARK: mo installer

public enum InstallerWorkflow {
    static let menuTitle = "Select Installers to Remove"
    private static let row = try! NSRegularExpression(pattern: #"^(.+?)\s{2,}(\S+)\s+\|\s+(.+)$"#)

    public static func scan(with runner: MoleRunner) async throws -> [InstallerFile] {
        let result = try await runner.capture(["installer", "--dry-run"])
        let screen = TerminalText.plain(String(decoding: result.output, as: UTF8.self))
        return parseMenu(screen)
    }

    static func parseMenu(_ screen: String) -> [InstallerFile] {
        guard let frame = MenuFrameParser.lastFrame(in: screen, title: menuTitle) else { return [] }
        return frame.rows.compactMap { file(fromRow: $0.text) }
    }

    static func file(fromRow text: String) -> InstallerFile? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = row.firstMatch(in: text, range: range),
              let name = Range(match.range(at: 1), in: text),
              let size = Range(match.range(at: 2), in: text),
              let source = Range(match.range(at: 3), in: text)
        else { return nil }
        return InstallerFile(row: Rows.normalized(text), name: String(text[name]),
                             sizeLabel: String(text[size]), source: String(text[source]))
    }

    /// Mole lists each planned file as `✓ <file name> , <size>`; Burrow confirms only when every
    /// planned file is one of the picked rows and every picked row is planned.
    static func confirmationMatches(_ screen: String, selection: [InstallerFile]) -> Bool {
        guard let lines = Rows.confirmationList(in: screen, heading: "Files to be removed:") else { return false }
        var unmatched = selection
        for line in lines where line.hasPrefix("✓") {
            let body = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            guard let separator = body.range(of: " , ", options: .backwards) else { return false }
            let fileName = String(body[..<separator.lowerBound])
            let size = String(body[separator.upperBound...])
            guard let index = unmatched.firstIndex(where: {
                $0.sizeLabel == size && menuName($0.name, shows: fileName)
            }) else { return false }
            unmatched.remove(at: index)
        }
        return unmatched.isEmpty
    }

    /// The menu drops a Homebrew download's `<sha256>--` prefix and cuts names longer than
    /// 40 columns with `...`; the confirmation prints the file name in full.
    static func menuName(_ shown: String, shows fileName: String) -> Bool {
        var name = fileName
        if let match = fileName.firstMatch(of: /^[0-9a-f]{64}--(.+)$/) {
            name = String(match.1)
        }
        if shown == name || shown == fileName { return true }
        guard shown.hasSuffix("..."), shown.count > 3 else { return false }
        return name.hasPrefix(String(shown.dropLast(3)))
    }

    public static func remove(_ selection: [InstallerFile], with runner: MoleRunner,
                              dryRun: Bool = false) async throws -> RemovalOutcome {
        let session = try runner.start(dryRun ? ["installer", "--dry-run"] : ["installer"], options: SessionOptions(
            interactive: true, environment: ["MOLE_DELETE_MODE": "trash"]
        ))
        let removal = MenuRemoval(session: session, title: menuTitle, identity: { frame in
            frame.cursor.map { Rows.normalized($0.text) }
        }, menuTimeout: 120)
        return try await removal.run(Set(selection.map(\.row)), confirmationTimeout: 60) {
            confirmationMatches($0, selection: selection)
        }
    }
}

// MARK: mo purge

public enum PurgeWorkflow {
    static let menuTitle = "Select Artifacts to Purge"

    public static func scan(with runner: MoleRunner) async throws -> (artifacts: [PathEntry], report: MoleReport) {
        let result = try await runner.capture(["purge", "--dry-run"])
        let text = String(decoding: result.output, as: UTF8.self)
        return (PurgePreviewParser.parse(text), MoleReportParser.parse(text))
    }

    /// Cloud-synced artifacts carry a `[cloud] ` tag in front of their path.
    static func artifactPath(_ shown: String) -> String {
        Paths.expandingTilde(shown.hasPrefix("[cloud] ") ? String(shown.dropFirst(8)) : shown)
    }

    static func confirmationMatches(_ screen: String, selection: [PathEntry]) -> Bool {
        guard let lines = Rows.confirmationList(in: screen, heading: "Selected paths:") else { return false }
        let planned = lines.map(artifactPath).filter { $0.hasPrefix("/") }
        return Set(planned) == Set(selection.map(\.path)) && planned.count == selection.count
    }

    public static func remove(_ selection: [PathEntry], with runner: MoleRunner,
                              dryRun: Bool = false) async throws -> RemovalOutcome {
        let session = try runner.start(dryRun ? ["purge", "--dry-run"] : ["purge"],
                                       options: SessionOptions(interactive: true))
        let removal = MenuRemoval(session: session, title: menuTitle, identity: { frame in
            frame.cursorPath.map(artifactPath)
        }, menuTimeout: 600)
        return try await removal.run(Set(selection.map(\.path)), confirmationTimeout: 120) {
            confirmationMatches($0, selection: selection)
        }
    }
}

// MARK: mo slim

public enum SlimWorkflow {
    public static func scan(with runner: MoleRunner) async throws -> [SlimCandidate] {
        let result = try await runner.capture(["slim", "--dry-run"])
        return SlimPreviewParser.parse(String(decoding: result.output, as: UTF8.self))
    }

    /// `mo slim` redraws only the rows that change in its menu, which Burrow cannot follow,
    /// so the choice happens in Terminal against the same bundled Mole.
    public static func terminalScript(moleExecutable: URL) -> String {
        let quoted = "'" + moleExecutable.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "#!/bin/bash\nclear\nexec \(quoted) slim\n"
    }
}
