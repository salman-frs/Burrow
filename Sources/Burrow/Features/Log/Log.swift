import BurrowCore
import SwiftUI

struct LogEntry: Identifiable {
    let id: String
    let command: String
    let title: String
    let date: Date?
    let bytes: Int64
    let fixes: Int
    let kept: Int
    let failed: Int
    let deletions: [HistoryDeletion]
}

@MainActor
@Observable
final class LogModel {
    private(set) var entries: [LogEntry] = []
    private(set) var loaded = false
    private(set) var failure: String?
    private var stale = true
    private weak var app: AppModel?

    func attach(to app: AppModel) { self.app = app }

    func markStale() { stale = true }

    var total: Int64 { entries.map(\.bytes).reduce(0, +) }

    func loadIfStale() async {
        guard stale, let runner = app?.runner else { return }
        do {
            let result = try await runner.capture(["history", "--json", "--limit", "200"])
            let report = try MoleJSON.decode(HistoryReport.self, from: result.output)
            entries = Self.entries(from: report)
            stale = false
            failure = nil
        } catch {
            if Task.isCancelled { return }
            failure = error.localizedDescription
        }
        loaded = true
    }

    static func entries(from report: HistoryReport) -> [LogEntry] {
        let deletions = report.deletions.map { ($0, isoFormatter.date(from: $0.timestamp)) }
        return report.sessions
            .filter { !$0.isPreview && $0.operationCount > 0 }
            .map { session in
                let start = sessionFormatter.date(from: session.startedAt)
                let end = sessionFormatter.date(from: session.endedAt).map { $0.addingTimeInterval(1) }
                let removed = deletions.filter { _, date in
                    guard let date, let start, let end else { return false }
                    return date >= start && date <= end
                }.map(\.0)
                return LogEntry(id: session.id, command: session.command, title: title(for: session.command, removed: removed),
                                date: start, bytes: ByteSize.firstSize(in: session.size) ?? 0, fixes: session.operationCount,
                                kept: session.actions.skipped, failed: session.actions.failed, deletions: removed)
            }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    private static func title(for command: String, removed: [HistoryDeletion]) -> String {
        switch command {
        case "clean": return "Caches"
        case "installer": return "Installers"
        case "purge": return "Build leftovers"
        case "optimize": return "Tune up"
        case "slim": return "Slimmed apps"
        case "touchid": return "Touch ID"
        case "uninstall":
            let apps = removed.map { URL(fileURLWithPath: $0.path) }.filter { $0.pathExtension == "app" }
                .map { $0.deletingPathExtension().lastPathComponent }
            return apps.isEmpty ? "Uninstalled apps" : "Uninstalled \(apps.formatted(.list(type: .and)))"
        default: return command.capitalized
        }
    }

    private static let sessionFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let isoFormatter: ISO8601DateFormatter = ISO8601DateFormatter()
}

struct LogView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.log
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ByteFigure(model.total, word: "cleared")
                    .animation(.easeOut(duration: 0.8), value: model.total)
                    .opacity(model.loaded ? 1 : 0)
                    .animation(.easeOut(duration: 0.3), value: model.loaded)
                if !model.loaded {
                    Spinner(size: 20).padding(.top, 34)
                } else if let failure = model.failure, model.entries.isEmpty {
                    Text(failure).foregroundStyle(.secondary).padding(.top, 34)
                } else if model.loaded && model.entries.isEmpty {
                    Text("Nothing yet. What you clear shows up here.")
                        .foregroundStyle(.tertiary)
                        .padding(.top, 34)
                }
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(months(model.entries), id: \.title) { month in
                        Text(month.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 26)
                            .padding(.bottom, 6)
                        ForEach(month.entries) { LogRow(entry: $0) }
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.top, 8)
            }
            .padding(.top, Metrics.heroTop)
            .padding(.leading, Metrics.contentX)
            .padding(.trailing, 48)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .task { await model.loadIfStale() }
    }

    private func months(_ entries: [LogEntry]) -> [(title: String, entries: [LogEntry])] {
        let calendar = Calendar.current
        var groups: [(title: String, entries: [LogEntry])] = []
        for entry in entries {
            let title: String
            if let date = entry.date {
                let sameYear = calendar.isDate(date, equalTo: .now, toGranularity: .year)
                title = date.formatted(sameYear ? .dateTime.month(.wide) : .dateTime.month(.wide).year())
            } else {
                title = "Earlier"
            }
            if groups.last?.title == title { groups[groups.count - 1].entries.append(entry) } else { groups.append((title, [entry])) }
        }
        return groups
    }
}

private struct LogRow: View {
    let entry: LogEntry
    @ViewState private var expanded = false
    @ViewState private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                Group {
                    if entry.command == "clean" {
                        ShovelIcon(size: 18)
                    } else {
                        Image(systemName: symbol).font(.system(size: 15, weight: .medium))
                    }
                }
                .foregroundStyle(.secondary)
                .frame(width: 38, height: 38)
                .background(Palette.hover, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(entry.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        if entry.kept > 0 {
                            Text("\(entry.kept) kept").font(.system(size: 12)).foregroundStyle(Palette.accentText)
                        }
                        if entry.failed > 0 {
                            Text("\(entry.failed) failed").font(.system(size: 12)).foregroundStyle(Palette.danger)
                        }
                    }
                    Text(when).font(.system(size: 12)).foregroundStyle(.tertiary)
                }
                .frame(width: 210, alignment: .leading)
                Pellets(count: pelletCount, partial: partialPellet, done: entry.command == "optimize")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(amount)
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(entry.command != "optimize" && entry.bytes == 0 ? .tertiary : .primary)
                    .frame(width: 78, alignment: .trailing)
                Chevron(expanded: expanded)
                    .opacity(entry.deletions.isEmpty ? 0 : 1)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(entry.deletions.isEmpty ? [] : .isButton)
            .accessibilityAction { toggle() }
            if expanded {
                VStack(spacing: 0) {
                    ForEach(entry.deletions.prefix(100)) { deletion in
                        HStack(spacing: 10) {
                            Image(systemName: deletion.mode == "trash" ? "trash" : "xmark.circle")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .help(deletion.mode == "trash" ? "In the Trash" : "Removed")
                            Text(Paths.abbreviatingHome(deletion.path)).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Text(deletion.sizeKb.map { ByteText.string($0 * 1024) } ?? "")
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                        }
                        .font(.system(size: 12))
                        .frame(minHeight: 24)
                        .contextMenu { Button("Show in Finder") { revealInFinder(deletion.path) } }
                    }
                }
                .padding(.leading, 66)
                .padding(.trailing, 12)
                .padding(.bottom, 10)
                .transition(.opacity)
            }
        }
        .background((hovering && !entry.deletions.isEmpty) || expanded ? Palette.hover : .clear,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, -12)
        .onHover { hovering = $0 }
        .help(entry.deletions.isEmpty ? "" : "Show what Mole logged")
    }

    private func toggle() {
        guard !entry.deletions.isEmpty else { return }
        withAnimation(.spring(duration: 0.35, bounce: 0.2)) { expanded.toggle() }
    }

    private var amount: String {
        if entry.command == "optimize" { return entry.fixes == 1 ? "1 fix" : "\(entry.fixes) fixes" }
        return entry.bytes > 0 ? ByteText.string(entry.bytes) : "–"
    }

    private var symbol: String {
        switch entry.command {
        case "uninstall": "trash"
        case "optimize": "bolt"
        case "installer": "shippingbox"
        case "purge": "hammer"
        case "slim": "scissors"
        case "touchid": "touchid"
        default: "sparkles"
        }
    }

    private var when: String {
        guard let date = entry.date else { return "" }
        if Calendar.current.isDateInToday(date) { return "Today, \(date.formatted(date: .omitted, time: .shortened))" }
        let sameYear = Calendar.current.isDate(date, equalTo: .now, toGranularity: .year)
        return date.formatted(sameYear ? .dateTime.month(.abbreviated).day().hour().minute() : .dateTime.month(.abbreviated).day().year())
    }

    private var pelletCount: Int {
        entry.command == "optimize" ? min(entry.fixes, 40) : min(Int(entry.bytes / 100_000_000), 120)
    }

    private var partialPellet: Bool {
        entry.command != "optimize" && pelletCount < 120 && entry.bytes % 100_000_000 > 30_000_000
    }
}

private struct Pellets: View {
    let count: Int
    let partial: Bool
    let done: Bool
    @Environment(\.accent) private var accent

    var body: some View {
        let color = (done ? accent.done : accent.fill).color
        FlowLayout(spacing: 3) {
            ForEach(0..<count, id: \.self) { _ in
                Circle().fill(color).frame(width: 5, height: 5).shadow(color: done ? .clear : color.opacity(0.55), radius: 3)
            }
            if partial {
                Circle().fill(color.opacity(0.45)).frame(width: 5, height: 5)
            }
        }
        .help(done ? "One dot per fix" : "Each dot is 100 MB")
    }
}

struct FlowLayout: SwiftUI.Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (indices: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = ([index], size.width, size.height)
            } else {
                current = (current.indices + [index], needed, max(current.height, size.height))
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
