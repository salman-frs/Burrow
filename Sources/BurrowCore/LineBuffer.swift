import Foundation

/// Treats `\r` as a line break too, so a redrawn progress line ends up as its own line.
struct LineBuffer {
    private var pending = Data()

    mutating func append(_ chunk: Data) -> [String] {
        pending.append(chunk)
        var lines: [String] = []
        while let breakIndex = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = pending[pending.startIndex..<breakIndex]
            pending.removeSubrange(pending.startIndex...breakIndex)
            lines.append(String(decoding: lineData, as: UTF8.self))
        }
        return lines
    }

    mutating func finish() -> [String] {
        guard !pending.isEmpty else { return [] }
        defer { pending.removeAll() }
        return [String(decoding: pending, as: UTF8.self)]
    }
}

public enum TerminalText {
    private static let escapeSequence = try! NSRegularExpression(
        pattern: "\u{1B}(\\[[0-9;?]*[ -/]*[@-~]|\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)|[()][A-Za-z0-9]|[=>78])"
    )

    public static func plain(_ line: String) -> String {
        let range = NSRange(line.startIndex..., in: line)
        return escapeSequence.stringByReplacingMatches(in: line, range: range, withTemplate: "")
    }
}
