import Foundation

/// The sectioned text `mo clean` and `mo optimize` print: `➤` section headings,
/// indented status rows, then a summary between two rules of `=`.
public struct MoleReport: Sendable, Equatable {
    public var notices: [ReportRow] = []
    public var sections: [ReportSection] = []
    public var summary: [String] = []

    public init() {}

    public var rows: [ReportRow] { sections.flatMap(\.rows) }

    public func summaryBytes(labeled label: String) -> Int64? {
        summary.first { $0.hasPrefix(label) }.flatMap { ByteSize.firstSize(in: $0) }
    }
}

public struct ReportSection: Sendable, Equatable, Identifiable {
    public let title: String
    public var rows: [ReportRow]
    public var id: String { title }

    /// Only rows Mole cleans count; review rows are sized for information and never removed.
    public var measuredBytes: Int64 {
        rows.filter { $0.status == .pending || $0.status == .done }.compactMap(\.bytes).reduce(0, +)
    }
}

public struct ReportRow: Sendable, Equatable, Identifiable {
    public enum Status: Sendable, Equatable {
        case done, pending, review, attention, failed, info
    }

    public let id: Int
    public let status: Status
    public let title: String
    public let detail: String
    public var children: [String] = []

    public var bytes: Int64? { ByteSize.firstSize(in: detail) }
}

public enum MoleReportParser {
    public static func parse(_ text: String) -> MoleReport {
        var report = MoleReport()
        var rowCount = 0
        var summaryRules = 0

        for rawLine in text.components(separatedBy: .newlines) {
            let line = TerminalText.plain(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if trimmed.hasPrefix("=====") {
                summaryRules += 1
                continue
            }
            if summaryRules == 1 {
                report.summary.append(trimmed)
                continue
            }
            if trimmed.hasPrefix("➤") {
                let title = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                report.sections.append(ReportSection(title: title, rows: []))
                continue
            }
            guard let status = status(of: trimmed.first) else {
                appendChild(trimmed, indent: line.prefix(while: { $0 == " " }).count, to: &report)
                continue
            }

            let body = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            let (title, detail) = split(body)
            let row = ReportRow(id: rowCount, status: status, title: title, detail: detail)
            rowCount += 1

            let indented = line.hasPrefix(" ")
            if indented, !report.sections.isEmpty {
                report.sections[report.sections.count - 1].rows.append(row)
            } else {
                report.notices.append(row)
            }
        }
        return report
    }

    private static func status(of marker: Character?) -> ReportRow.Status? {
        switch marker {
        case "✓": .done
        case "○": .pending
        case "⊙": .review
        case "◎": .attention
        case "☻", "✗": .failed
        case "⚙", "•": .info
        default: nil
        }
    }

    /// Mole separates a row's name from its measurement with ` · ` or, for a few
    /// rows, with a comma before `would clean` or a size.
    private static func split(_ body: String) -> (String, String) {
        if let separator = body.range(of: " · ") {
            return (String(body[..<separator.lowerBound]), String(body[separator.upperBound...]))
        }
        if let comma = body.range(of: ", ") {
            let rest = String(body[comma.upperBound...])
            if rest.hasPrefix("would") || ByteSize.firstSize(in: rest) != nil {
                return (String(body[..<comma.lowerBound]), rest)
            }
        }
        return (body, "")
    }

    private static func appendChild(_ text: String, indent: Int, to report: inout MoleReport) {
        guard indent >= 4, !report.sections.isEmpty,
              !report.sections[report.sections.count - 1].rows.isEmpty
        else { return }
        let section = report.sections.count - 1
        let row = report.sections[section].rows.count - 1
        report.sections[section].rows[row].children.append(text)
    }
}

public enum ByteSize {
    private static let pattern = try! NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)\s?(B|KB|MB|GB|TB)\b"#)
    private static let multipliers: [String: Double] = [
        "B": 1, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12,
    ]

    public static func firstSize(in text: String) -> Int64? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern.firstMatch(in: text, range: range),
              let numberRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text),
              let number = Double(text[numberRange]),
              let multiplier = multipliers[String(text[unitRange])]
        else { return nil }
        return Int64(number * multiplier)
    }

    public static func format(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }
}
