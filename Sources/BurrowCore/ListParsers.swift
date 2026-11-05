import Foundation

public struct PathEntry: Sendable, Equatable, Identifiable, Hashable {
    public let path: String
    public let sizeLabel: String
    public let bytes: Int64?
    public var id: String { path }
}

public struct PathGroup: Sendable, Equatable, Identifiable {
    public let title: String
    public var entries: [PathEntry]
    public var id: String { title }
}

/// `~/.config/mole/clean-list.txt`, written by every `mo clean --dry-run`.
public enum CleanListParser {
    public static func parse(_ text: String) -> [PathGroup] {
        var groups: [PathGroup] = []
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("=== "), line.hasSuffix(" ===") {
                let title = line.dropFirst(4).dropLast(4).trimmingCharacters(in: .whitespaces)
                groups.append(PathGroup(title: title, entries: []))
                continue
            }
            guard line.hasPrefix("/"), !groups.isEmpty,
                  let note = line.range(of: "  # ", options: .backwards)
            else { continue }
            let path = String(line[..<note.lowerBound])
            let label = String(line[note.upperBound...])
            let entry = PathEntry(path: path, sizeLabel: label, bytes: ByteSize.firstSize(in: label))
            groups[groups.count - 1].entries.append(entry)
        }
        return groups
    }
}

public enum PurgePreviewParser {
    private static let row = try! NSRegularExpression(pattern: #"^✓ \[DRY RUN\] (.+), (\S+)$"#)

    public static func parse(_ text: String) -> [PathEntry] {
        text.components(separatedBy: .newlines).compactMap { rawLine in
            let line = TerminalText.plain(rawLine).trimmingCharacters(in: .whitespaces)
            let range = NSRange(line.startIndex..., in: line)
            guard let match = row.firstMatch(in: line, range: range),
                  let pathRange = Range(match.range(at: 1), in: line),
                  let sizeRange = Range(match.range(at: 2), in: line)
            else { return nil }
            let size = String(line[sizeRange])
            return PathEntry(path: Paths.expandingTilde(String(line[pathRange])),
                             sizeLabel: size, bytes: ByteSize.firstSize(in: size))
        }
    }
}

public struct SlimCandidate: Sendable, Equatable, Identifiable, Hashable {
    public let name: String
    public let sizeLabel: String
    public let bytes: Int64?
    public var id: String { name }
}

public enum SlimPreviewParser {
    private static let row = try! NSRegularExpression(pattern: #"^  (\S.*?)\s{2,}(\d+(?:\.\d+)?(?:B|KB|MB|GB|TB))$"#)

    public static func parse(_ text: String) -> [SlimCandidate] {
        text.components(separatedBy: .newlines).compactMap { rawLine in
            let line = TerminalText.plain(rawLine)
            let range = NSRange(line.startIndex..., in: line)
            guard let match = row.firstMatch(in: line, range: range),
                  let nameRange = Range(match.range(at: 1), in: line),
                  let sizeRange = Range(match.range(at: 2), in: line)
            else { return nil }
            let size = String(line[sizeRange])
            return SlimCandidate(name: String(line[nameRange]), sizeLabel: size,
                                 bytes: ByteSize.firstSize(in: size))
        }
    }
}

public enum Paths {
    public static func expandingTilde(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return NSHomeDirectory() + path.dropFirst()
    }

    public static func abbreviatingHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
