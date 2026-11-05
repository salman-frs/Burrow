import AppKit
import BurrowCore
import Foundation
import Observation

struct SpaceItem: Identifiable, Equatable {
    enum Kind { case folder, file, system, rest }

    let id: String
    let name: String
    let path: String?
    let bytes: Int64
    let kind: Kind
    var insight = false
    var cleanable = false
}

@MainActor
@Observable
final class SpaceModel {
    struct Crumb: Equatable {
        let name: String
        /// nil is the whole disk, drawn from Mole's overview.
        let path: String?
    }

    private(set) var trail = [Crumb(name: "", path: nil)]
    private(set) var reports: [String: DiskReport] = [:]
    private(set) var loadingPath: String?
    var selectedID: String?
    var pendingTrash: SpaceItem?
    let field = DotField(top: 168, seed: 23)
    private weak var app: AppModel?

    func attach(to app: AppModel) { self.app = app }

    var current: Crumb { trail[trail.count - 1] }
    var diskName: String { app?.disk.name ?? "" }
    var atRoot: Bool { current.path == nil }
    var report: DiskReport? { current.path.flatMap { reports[$0] } }

    /// Deepest first, as the field stacks them: macOS at the bottom of the disk, the largest folder at the bottom of a folder.
    var items: [SpaceItem] {
        guard let path = current.path else {
            return (app?.disk.layers ?? []).map { layer in
                SpaceItem(id: layer.id, name: layer.name, path: layer.path, bytes: layer.bytes,
                          kind: layer.path == nil ? .system : .folder)
            }
        }
        guard let report = reports[path] else { return [] }
        let entries = report.entries.filter { $0.size > 0 }.sorted { $0.size > $1.size }
        var items = entries.prefix(13).map { entry in
            SpaceItem(id: entry.path, name: entry.name, path: entry.path, bytes: entry.size,
                      kind: entry.isDir ? .folder : .file, insight: entry.insight == true, cleanable: entry.cleanable == true)
        }
        let rest = entries.dropFirst(13).map(\.size).reduce(0, +)
        if rest > 0 {
            items.append(SpaceItem(id: "\(path)#rest", name: "Everything else", path: nil, bytes: rest, kind: .rest))
        }
        return items
    }

    var selected: SpaceItem? { items.first { $0.id == selectedID } }

    var total: Int64 {
        atRoot ? (app?.disk.used ?? 0) : max(report?.totalSize ?? 0, items.map(\.bytes).reduce(0, +))
    }

    // MARK: Field

    func strata(for items: [SpaceItem]) -> [Stratum] {
        items.enumerated().map { index, item in
            let ramp = atRoot ? FieldTheme.rampIndex(index * 2, of: items.count * 2 - 1) : FieldTheme.rampIndex(index, of: items.count)
            return Stratum(name: item.name, bytes: item.bytes, shade: item.insight ? .insight(ramp) : .ramp(ramp))
        }
    }

    func fieldResized(to size: CGSize) {
        if field.resize(to: size) || !field.hasLayout { relayout(animated: false) }
    }

    func layersChanged() {
        if atRoot { relayout(animated: field.hasLayout) }
    }

    private func relayout(animated: Bool) {
        let items = items
        guard !items.isEmpty else { return }
        let fieldTotal = atRoot ? (app?.disk.total ?? total) : total
        field.layout(strata(for: items), total: fieldTotal, animate: animated)
    }

    // MARK: Navigation

    func open(_ item: SpaceItem) async {
        guard item.kind == .folder, let path = item.path else { return }
        await open(path: path, named: item.name)
    }

    func open(path: String, named name: String) async {
        trail.append(Crumb(name: name, path: path))
        selectedID = nil
        if reports[path] == nil { await load(path) } else { relayout(animated: true) }
    }

    func go(to index: Int) {
        guard index < trail.count - 1 else { return }
        trail = Array(trail.prefix(index + 1))
        selectedID = nil
        relayout(animated: true)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Measure"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        trail = [trail[0]]
        Task { await open(path: url.path, named: url.lastPathComponent) }
    }

    func refresh() async {
        guard let path = current.path else {
            await app?.disk.loadOverview()
            return
        }
        reports[path] = nil
        await load(path)
    }

    private func load(_ path: String) async {
        guard let runner = app?.runner else { return }
        loadingPath = path
        defer { if loadingPath == path { loadingPath = nil } }
        do {
            let result = try await runner.capture(["analyze", "--json", path])
            reports[path] = try MoleJSON.decode(DiskReport.self, from: result.output)
            if current.path == path { relayout(animated: true) }
        } catch {
            app?.notify("Mole could not measure \(URL(fileURLWithPath: path).lastPathComponent). \(error.localizedDescription)",
                        symbol: "exclamationmark.triangle.fill", warning: true)
            if current.path == path, reports[path] == nil { trail.removeLast() }
        }
    }

    // MARK: Trash

    func canTrash(_ item: SpaceItem) -> Bool {
        guard let path = item.path, item.kind == .folder || item.kind == .file else { return false }
        return TrashPolicy.allows(path)
    }

    func trash(_ item: SpaceItem) async {
        pendingTrash = nil
        guard let path = item.path, canTrash(item) else { return }
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            selectedID = nil
            app?.notify("\(item.name) moved to Trash", symbol: "trash.fill")
            app?.diskChanged()
            await refresh()
        } catch {
            app?.notify("\(item.name) could not be moved to the Trash. \(error.localizedDescription)",
                        symbol: "exclamationmark.triangle.fill", warning: true)
        }
    }
}

/// Space only offers the Trash for things inside your home folder that are not
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
