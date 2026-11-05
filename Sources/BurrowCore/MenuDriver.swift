import Foundation

public struct MenuRow: Sendable, Equatable {
    public let text: String
    public let selected: Bool
    public let isCursor: Bool
}

public struct MenuFrame: Sendable, Equatable {
    public var rows: [MenuRow] = []
    public var selectedCount: Int?
    public var cursorPath: String?

    public var cursor: MenuRow? { rows.first(where: \.isCursor) }
}

/// Reads the frames Mole's selection menus draw: a title line, one `●`/`○` row per
/// item with `➤` on the highlighted one, and a key legend at the bottom.
public enum MenuFrameParser {
    private static let row = try! NSRegularExpression(pattern: #"^\s*(➤)?\s*([●○])\s+(.*?)\s*$"#)
    private static let selectedCount = try! NSRegularExpression(pattern: #"(\d+) selected"#)

    public static func isComplete(_ screen: String, title: String) -> Bool {
        guard let titleRange = screen.range(of: title, options: .backwards) else { return false }
        return screen[titleRange.upperBound...].contains("Q Quit")
    }

    public static func lastFrame(in screen: String, title: String) -> MenuFrame? {
        guard let titleRange = screen.range(of: title, options: .backwards) else { return nil }
        var frame = MenuFrame()
        for line in screen[titleRange.upperBound...].components(separatedBy: CharacterSet(charactersIn: "\r\n")) {
            if line.contains("Q Quit") { break }
            if frame.rows.isEmpty, frame.selectedCount == nil, let count = selected(in: line) {
                frame.selectedCount = count
                continue
            }
            if let path = line.range(of: "Path: ") {
                frame.cursorPath = String(line[path.upperBound...]).trimmingCharacters(in: .whitespaces)
                continue
            }
            let range = NSRange(line.startIndex..., in: line)
            guard let match = row.firstMatch(in: line, range: range),
                  let markRange = Range(match.range(at: 2), in: line),
                  let textRange = Range(match.range(at: 3), in: line)
            else { continue }
            frame.rows.append(MenuRow(
                text: String(line[textRange]),
                selected: line[markRange] == "●",
                isCursor: match.range(at: 1).location != NSNotFound
            ))
        }
        return frame.rows.isEmpty ? nil : frame
    }

    private static func selected(in line: String) -> Int? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = selectedCount.firstMatch(in: line, range: range),
              let countRange = Range(match.range(at: 1), in: line)
        else { return nil }
        return Int(line[countRange])
    }
}

/// Moves through a Mole menu one row at a time and leaves exactly `targets` selected.
/// The caller still checks Mole's own confirmation list before anything is removed.
public struct MenuDriver: Sendable {
    public let session: MoleSession
    public let title: String
    public let identity: @Sendable (MenuFrame) -> String?
    public var keyTimeout: TimeInterval = 10
    public var trace: (@Sendable (String) -> Void)?

    public init(session: MoleSession, title: String, identity: @escaping @Sendable (MenuFrame) -> String?) {
        self.session = session
        self.title = title
        self.identity = identity
    }

    public func waitForMenu(timeout: TimeInterval) async throws -> MenuFrame {
        let title = title
        let screen = try await session.waitForScreen(since: 0, timeout: timeout, step: "scanning") {
            MenuFrameParser.isComplete($0, title: title)
        }
        guard let frame = MenuFrameParser.lastFrame(in: screen, title: title) else {
            throw RunError.timedOut("reading the selection list")
        }
        return frame
    }

    public func press(_ key: MoleSession.Key) async throws -> MenuFrame {
        let title = title
        let mark = session.mark()
        trace?("press \(key)")
        session.send(key)
        let screen = try await session.waitForScreen(since: mark, timeout: keyTimeout, step: "updating the selection") {
            MenuFrameParser.isComplete($0, title: title)
        }
        guard let frame = MenuFrameParser.lastFrame(in: screen, title: title) else {
            throw RunError.timedOut("reading the selection list")
        }
        return frame
    }

    /// Uses the menu's own All and Invert keys, since toggling preselected rows one by one costs a redraw each.
    func clearSelection(_ frame: MenuFrame) async throws -> MenuFrame {
        guard let count = frame.selectedCount else {
            throw RunError.planMismatch("the selection count could not be read")
        }
        if count == 0 { return frame }
        var current = try await press(.text("a"))
        if current.selectedCount != 0 {
            current = try await press(.text("i"))
        }
        guard current.selectedCount == 0 else {
            throw RunError.planMismatch("the menu's preselected items could not be cleared")
        }
        return current
    }

    @discardableResult
    public func select(_ targets: Set<String>, startingAt first: MenuFrame, limit: Int = 2000) async throws -> Set<String> {
        var frame = try await clearSelection(first)
        var visited: Set<String> = []
        for _ in 0..<limit {
            guard let current = identity(frame), let cursor = frame.cursor else {
                throw RunError.planMismatch("the highlighted row could not be identified")
            }
            if visited.contains(current) { break }
            visited.insert(current)

            if targets.contains(current) != cursor.selected {
                frame = try await press(.space)
                guard identity(frame) == current, frame.cursor?.selected == targets.contains(current) else {
                    throw RunError.planMismatch("Mole did not toggle \(current)")
                }
            }

            let next = try await press(.down)
            if identity(next) == current { break }
            frame = next
        }
        let missing = targets.subtracting(visited)
        guard missing.isEmpty else {
            throw RunError.planMismatch("\(missing.count) selected item(s) are no longer offered by Mole")
        }
        guard frame.selectedCount == nil || frame.selectedCount == targets.count else {
            throw RunError.planMismatch("Mole reports a different number of selected items")
        }
        return visited
    }
}
