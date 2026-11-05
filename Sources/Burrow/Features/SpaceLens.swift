import AppKit
import BurrowCore
import SwiftUI

@MainActor
@Observable
final class SpaceLensModel {
    /// nil is Mole's machine-wide overview; every other entry is a folder the user opened.
    private(set) var trail: [String?] = [nil]
    private(set) var reports: [String: DiskReport] = [:]
    private(set) var loading = false
    private(set) var failure: String?
    var pendingTrash: TrashCandidate?
    private weak var app: AppModel?

    func attach(to app: AppModel) { self.app = app }

    var current: String? { trail.last ?? nil }
    var report: DiskReport? { reports[key(current)] }

    func open(_ path: String?) async {
        if let path { trail.append(path) } else { trail = [nil] }
        await load(path)
    }

    func goBack(to index: Int) async {
        trail = Array(trail.prefix(index + 1))
        if report == nil { await load(current) }
    }

    func refresh() async {
        reports[key(current)] = nil
        await load(current)
    }

    func load(_ path: String?) async {
        guard let runner = app?.runner else { return }
        loading = true
        failure = nil
        do {
            let arguments = ["analyze", "--json"] + (path.map { [$0] } ?? [])
            let result = try await runner.capture(arguments)
            reports[key(path)] = try MoleJSON.decode(DiskReport.self, from: result.output)
        } catch {
            failure = "Mole could not measure this folder. \(error.localizedDescription)"
        }
        loading = false
    }

    func trash(_ entry: TrashCandidate) async {
        pendingTrash = nil
        guard TrashPolicy.allows(entry.path) else { return }
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: entry.path), resultingItemURL: nil)
            await refresh()
        } catch {
            failure = "\(entry.name) could not be moved to the Trash. \(error.localizedDescription)"
        }
    }

    private func key(_ path: String?) -> String { path ?? "" }
}

struct TrashCandidate: Equatable {
    let name: String
    let path: String
    let size: Int64
}

/// Space Lens only offers the Trash for things inside your home folder that are not
/// the folders macOS itself depends on; everything else is reveal-only.
enum TrashPolicy {
    static func allows(_ path: String) -> Bool {
        let home = NSHomeDirectory()
        guard path.hasPrefix(home + "/") else { return false }
        let relative = String(path.dropFirst(home.count + 1))
        let topLevel = ["Library", "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public", "Applications"]
        if topLevel.contains(relative) { return false }
        let protectedPrefixes = ["Library/Keychains", "Library/Mail", "Library/Messages", "Library/Mobile Documents",
                                 "Library/CloudStorage", "Library/Group Containers", "Library/Containers",
                                 "Library/Preferences", "Library/Application Support/com.apple"]
        return !protectedPrefixes.contains { relative == $0 || relative.hasPrefix($0 + "/") }
    }
}

struct SpaceLensView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var model = app.spaceLens
        VStack(alignment: .leading, spacing: 0) {
            ModuleHeader(module: .spaceLens) {
                Button("Choose folder…") { chooseFolder(model) }
                Button("Refresh") { Task { await model.refresh() } }.disabled(model.loading)
            }
            Breadcrumbs(model: model).padding(.horizontal, 28).padding(.bottom, 12)
            if let report = model.report {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Figure(bytes: report.totalSize, caption: caption(report), partial: report.scanStatus != .complete, size: 34)
                            Spacer()
                            if model.loading { ProgressView().controlSize(.small) }
                        }
                        Treemap(entries: treemapEntries(report)) { entry in
                            if entry.isDir { Task { await model.open(entry.path) } }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    EntryList(report: report, model: model).frame(width: 340)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
            } else if let failure = model.failure {
                EmptyPrompt(symbol: "circle.hexagongrid", title: "Nothing to show", message: failure) {
                    Button("Try again") { Task { await model.refresh() } }
                }
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Measuring your disk. The first scan can take a minute.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { if model.report == nil { await model.load(model.current) } }
        .confirmationDialog(
            "Move \(model.pendingTrash?.name ?? "") to the Trash?",
            isPresented: Binding(get: { model.pendingTrash != nil }, set: { if !$0 { model.pendingTrash = nil } }),
            titleVisibility: .visible
        ) {
            if let entry = model.pendingTrash {
                Button("Move to Trash (\(ByteSize.format(entry.size)))", role: .destructive) {
                    Task { await model.trash(entry) }
                }
            }
        } message: {
            Text("You can put it back from the Trash until you empty it.")
        }
    }

    /// The overview's insight rows sit inside Home, so drawing them beside it would count their space twice.
    private func treemapEntries(_ report: DiskReport) -> [DiskEntry] {
        report.entries.filter { $0.size > 0 && !(report.overview && $0.insight == true) }
    }

    private func caption(_ report: DiskReport) -> String {
        if report.overview { return "measured across your Mac" }
        let files = report.totalFiles.map { ", \($0.formatted()) files" } ?? ""
        return "in \(URL(fileURLWithPath: report.path).lastPathComponent)\(files)"
    }

    private func chooseFolder(_ model: SpaceLensModel) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Measure"
        if panel.runModal() == .OK, let url = panel.url {
            Task { await model.open(url.path) }
        }
    }
}

private struct Breadcrumbs: View {
    let model: SpaceLensModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(model.trail.enumerated()), id: \.offset) { index, path in
                if index > 0 { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                Button(path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "This Mac") {
                    Task { await model.goBack(to: index) }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(index == model.trail.count - 1 ? .primary : .secondary)
            }
        }
        .font(.callout)
    }
}

private struct EntryList: View {
    let report: DiskReport
    let model: SpaceLensModel

    var body: some View {
        List {
            Section("Largest items") {
                ForEach(report.entries.prefix(60)) { entry in
                    EntryRow(name: entry.name, path: entry.path, size: entry.size, isDir: entry.isDir,
                             note: entry.insight == true ? (entry.cleanable == true ? "Cleanable cache" : "Worth a look") : nil,
                             model: model)
                }
            }
            if let files = report.largeFiles, !files.isEmpty {
                Section("Large files") {
                    ForEach(files.prefix(30)) { file in
                        EntryRow(name: file.name, path: file.path, size: file.size, isDir: false, note: nil, model: model)
                    }
                }
            }
        }
        .listStyle(.inset)
    }
}

private struct EntryRow: View {
    let name: String
    let path: String
    let size: Int64
    let isDir: Bool
    let note: String?
    let model: SpaceLensModel

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).lineLimit(1).truncationMode(.middle)
                if let note { Text(note).font(.caption).foregroundStyle(Mineral.amethyst) }
            }
            Spacer()
            SizeLabel(text: ByteSize.format(size))
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if isDir { Task { await model.open(path) } } }
        .contextMenu {
            if isDir { Button("Open") { Task { await model.open(path) } } }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            Divider()
            Button("Move to Trash…") {
                model.pendingTrash = TrashCandidate(name: name, path: path, size: size)
            }
            .disabled(!TrashPolicy.allows(path))
        }
    }
}

private struct Treemap: View {
    let entries: [DiskEntry]
    let open: (DiskEntry) -> Void
    @Environment(\.moduleAccent) private var accent
    @ViewState private var hovered: String?

    var body: some View {
        GeometryReader { proxy in
            let tiles = Squarify.layout(entries.prefix(40).map { Double($0.size) }, in: CGRect(origin: .zero, size: proxy.size))
            ZStack(alignment: .topLeading) {
                ForEach(Array(zip(entries.prefix(40), tiles)), id: \.0.id) { entry, rect in
                    Tile(entry: entry, rect: rect, color: color(for: entry), hovered: hovered == entry.id)
                        .onHover { hovered = $0 ? entry.id : nil }
                        .onTapGesture { open(entry) }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func color(for entry: DiskEntry) -> Color {
        let rank = entries.firstIndex(of: entry) ?? 0
        return Mineral.layer(accent, index: min(rank, 11), of: 12)
    }
}

private struct Tile: View {
    let entry: DiskEntry
    let rect: CGRect
    let color: Color
    let hovered: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(color)
            .overlay(alignment: .topLeading) {
                if rect.width > 70 && rect.height > 34 {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.name).font(.caption.weight(.semibold)).lineLimit(1)
                        Text(ByteSize.format(entry.size)).font(.caption2).monospacedDigit()
                    }
                    .foregroundStyle(.white)
                    .padding(6)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(.white.opacity(hovered ? 0.9 : 0), lineWidth: 2)
            }
            .frame(width: max(rect.width - 2, 0), height: max(rect.height - 2, 0))
            .offset(x: rect.minX + 1, y: rect.minY + 1)
            .help("\(entry.name), \(ByteSize.format(entry.size))\(entry.isDir ? ". Click to open." : "")")
    }
}

enum Squarify {
    static func layout(_ values: [Double], in rect: CGRect) -> [CGRect] {
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return values.map { _ in .zero } }
        let scale = Double(rect.width * rect.height) / total
        var areas = values.map { $0 * scale }
        var result: [CGRect] = []
        var remaining = rect
        while !areas.isEmpty {
            let side = Double(min(remaining.width, remaining.height))
            var row: [Double] = []
            while let next = areas.first, row.isEmpty || worst(row + [next], side: side) <= worst(row, side: side) {
                row.append(next)
                areas.removeFirst()
            }
            let (rects, rest) = place(row, in: remaining)
            result.append(contentsOf: rects)
            remaining = rest
        }
        return result
    }

    private static func worst(_ row: [Double], side: Double) -> Double {
        let sum = row.reduce(0, +)
        guard let largest = row.max(), let smallest = row.min(), sum > 0, smallest > 0 else { return .infinity }
        let sideSquared = side * side
        return max(sideSquared * largest / (sum * sum), (sum * sum) / (sideSquared * smallest))
    }

    private static func place(_ row: [Double], in rect: CGRect) -> ([CGRect], CGRect) {
        let sum = row.reduce(0, +)
        var rects: [CGRect] = []
        if rect.width >= rect.height {
            let width = CGFloat(sum) / rect.height
            var y = rect.minY
            for area in row {
                let height = CGFloat(area) / width
                rects.append(CGRect(x: rect.minX, y: y, width: width, height: height))
                y += height
            }
            return (rects, CGRect(x: rect.minX + width, y: rect.minY, width: rect.width - width, height: rect.height))
        }
        let height = CGFloat(sum) / rect.width
        var x = rect.minX
        for area in row {
            let width = CGFloat(area) / height
            rects.append(CGRect(x: x, y: rect.minY, width: width, height: height))
            x += width
        }
        return (rects, CGRect(x: rect.minX, y: rect.minY + height, width: rect.width, height: rect.height - height))
    }
}
