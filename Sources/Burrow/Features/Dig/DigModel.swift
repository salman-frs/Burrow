import AppKit
import BurrowCore
import Foundation
import Observation

struct DigItem: Identifiable, Equatable {
    let id: String
    let name: String
    let path: String?
    let bytes: Int64
    /// For installers and build leftovers: picked. For caches: not kept.
    var included = true
}

struct DigCategory: Identifiable, Equatable {
    enum Kind { case cache, installers, projects }
    enum Selection { case none, some, all }

    let id: String
    let kind: Kind
    let vein: Int
    var items: [DigItem]
    /// What Mole measured for a cache section, which is more than the paths its preview file lists.
    let measured: Int64

    var isPickable: Bool { kind != .cache }

    var total: Int64 {
        kind == .cache ? measured : items.map(\.bytes).reduce(0, +)
    }

    var keptBytes: Int64 {
        items.filter { !$0.included }.map(\.bytes).reduce(0, +)
    }

    var pickedBytes: Int64 {
        kind == .cache ? max(measured - keptBytes, 0) : items.filter(\.included).map(\.bytes).reduce(0, +)
    }

    var selection: Selection {
        let picked = items.filter(\.included).count
        if picked == 0 { return .none }
        return picked == items.count ? .all : .some
    }
}

@MainActor
@Observable
final class DigModel {
    enum Phase: Equatable {
        case idle
        case digging(stopping: Bool)
        case ready
        /// The step is nil before the first removal starts and after the last one ends.
        case clearing(DigCategory.Kind?, stopping: Bool)
        case done

        var isDigging: Bool {
            if case .digging = self { true } else { false }
        }

        var isWorking: Bool {
            switch self {
            case .digging, .clearing: true
            case .idle, .ready, .done: false
            }
        }

        var isStopping: Bool {
            switch self {
            case .digging(let stopping), .clearing(_, let stopping): stopping
            case .idle, .ready, .done: false
            }
        }
    }

    private(set) var phase: Phase = .idle
    var includeSystem = false
    private(set) var categories: [DigCategory] = []
    private(set) var review: [ReviewItem] = []
    private(set) var scanNotes: [String] = []
    private(set) var clearNotes: [String] = []
    private(set) var ticker = ""
    private(set) var cachesIncluded = true
    /// False when the cache preview did not finish: `mo clean` would then clear sections nobody saw.
    private(set) var cachesClearable = true
    private(set) var cleared: Int64 = 0
    private(set) var remaining: Int64 = 0
    private(set) var freeBefore: Int64 = 0
    var hoveredVein: Int?
    private var installerFiles: [InstallerFile] = []
    private var artifacts: [PathEntry] = []
    let field = DotField(top: 132, seed: 23)
    let job = MoleJob()
    private var pendingLayers = false
    private weak var app: AppModel?

    func attach(to app: AppModel) { self.app = app }

    // MARK: Totals

    var found: Int64 { categories.map(\.total).reduce(0, +) }

    func picked(_ category: DigCategory) -> Int64 {
        switch category.kind {
        case .cache: cachesIncluded && cachesClearable ? category.pickedBytes : 0
        case .installers, .projects: category.pickedBytes
        }
    }

    var selectedTotal: Int64 { categories.map(picked).reduce(0, +) }

    var cacheCategories: [DigCategory] { categories.filter { $0.kind == .cache } }
    var pickableCategories: [DigCategory] { categories.filter(\.isPickable) }
    var largestCategory: Int64 { categories.map(\.total).max() ?? 1 }

    /// Picks are fixed once Clear starts. Keep writes Mole's protected list, so it waits for the full preview.
    func canEdit(_ category: DigCategory) -> Bool {
        phase == .ready || (phase.isDigging && category.isPickable)
    }

    // MARK: Field

    private var digBounds: (min: CGFloat, max: CGFloat) {
        (Metrics.inset + Metrics.sidebarWidth + 36, field.size.width - Metrics.inset - Metrics.inspectorWidth - 28)
    }

    func fieldResized(to size: CGSize) {
        guard phase == .idle || phase == .done || !field.hasLayout else { return }
        field.resize(to: size)
        if !field.hasLayout { applyLayers(animated: false) }
    }

    func layersChanged() {
        guard phase == .idle else {
            pendingLayers = true
            return
        }
        applyLayers(animated: field.hasLayout)
    }

    private func applyLayers(animated: Bool) {
        guard let disk = app?.disk, disk.total > 0 else { return }
        let layers = disk.layers
        let strata = layers.enumerated().map { index, layer in
            Stratum(name: layer.name, bytes: layer.bytes, shade: .ramp(FieldTheme.rampIndex(index * 2, of: layers.count * 2 - 1)))
        }
        field.layout(strata, total: disk.total, animate: animated)
        pendingLayers = false
    }

    // MARK: Digging

    func dig() async {
        guard let app, let runner = app.runner, !phase.isWorking, app.begin(.dig) else { return }
        defer { app.end(.dig) }
        if phase == .done || pendingLayers { applyLayers(animated: false) } else { field.layout(field.strata, total: field.total) }
        categories = []
        review = []
        installerFiles = []
        artifacts = []
        scanNotes = []
        clearNotes = []
        cachesIncluded = true
        cachesClearable = true
        ticker = "Starting"
        phase = .digging(stopping: false)
        let bounds = digBounds
        field.startDigging(from: bounds.min, to: bounds.max, start: Moment.now)

        let declined = await scanCaches(with: runner, app: app)
        if !phase.isStopping && !declined { await scanInstallers(with: runner) }
        if !phase.isStopping && !declined { await scanProjects(with: runner) }
        field.stopDigging()

        if declined || categories.isEmpty && review.isEmpty {
            if phase.isStopping {
                app.notify("Dig stopped", symbol: "stop.circle.fill", warning: true)
            } else if !declined {
                app.notify("Nothing to clear. Your Mac is tidy.", symbol: "sparkles")
            }
            phase = .idle
            applyLayers(animated: true)
            return
        }
        categories.sort { $0.total > $1.total }
        phase = .ready
        relight()
    }

    func stop() {
        switch phase {
        case .digging: phase = .digging(stopping: true)
        case .clearing(let step, _): phase = .clearing(step, stopping: true)
        case .idle, .ready, .done: return
        }
        job.stop()
    }

    /// Returns true when the user cancelled the password sheet, which ends the whole dig.
    private func scanCaches(with runner: MoleRunner, app: AppModel) async -> Bool {
        var streamed = ""
        var announced: Set<String> = []
        let outcome = await job.run(["clean", "--dry-run"], with: runner, options: adminOptions(app)) { [weak self] line in
            guard let self else { return }
            streamed += line + "\n"
            if let text = Self.tickerText(line) { self.ticker = text }
            let report = MoleReportParser.parse(streamed)
            for section in report.cleanableSections where section.title != report.sections.last?.title && !announced.contains(section.title) {
                announced.insert(section.title)
                self.discover(cache: section)
            }
        }
        switch outcome {
        case .failed(let error) where error.isAdminDeclined:
            return true
        case .failed, .stopped:
            cachesClearable = false
            scanNotes.append("The cache scan didn't finish, so caches are left alone. Dig again to include them.")
        case .completed, .exited:
            break
        }
        let report = MoleReportParser.parse(job.text)
        for section in report.cleanableSections where !announced.contains(section.title) {
            discover(cache: section)
        }
        review = report.reviewItems
        attachPreviewPaths()
        return false
    }

    private func scanInstallers(with runner: MoleRunner) async {
        ticker = "Installers"
        do {
            let files = try await InstallerWorkflow.scan(with: runner)
            installerFiles = files
            let items = files.map { DigItem(id: $0.id, name: $0.name, path: nil, bytes: $0.bytes ?? 0) }
            if !items.isEmpty { discover(.installers, id: "installers", items: items) }
        } catch {
            scanNotes.append("Installers could not be listed. \(error.localizedDescription)")
        }
    }

    private func scanProjects(with runner: MoleRunner) async {
        ticker = "Build leftovers"
        do {
            let (found, report) = try await PurgeWorkflow.scan(with: runner)
            artifacts = found
            scanNotes += report.notices.filter { $0.status == .attention }.map(\.title)
            let items = found.map { entry in
                let url = URL(fileURLWithPath: entry.path)
                return DigItem(id: entry.id, name: "\(url.deletingLastPathComponent().lastPathComponent)/\(url.lastPathComponent)",
                               path: entry.path, bytes: entry.bytes ?? 0, included: false)
            }
            if !items.isEmpty { discover(.projects, id: "projects", items: items) }
        } catch {
            scanNotes.append("Build leftovers could not be listed. \(error.localizedDescription)")
        }
    }

    private func discover(cache section: ReportSection) {
        guard section.measuredBytes > 0 else { return }
        let rows = section.rows.filter { $0.status == .pending && ($0.bytes ?? 0) > 0 }
        let items = rows.map { DigItem(id: "row-\($0.id)", name: $0.title, path: nil, bytes: $0.bytes ?? 0) }
        discover(.cache, id: section.title, items: items, measured: section.measuredBytes)
    }

    private func discover(_ kind: DigCategory.Kind, id: String, items: [DigItem], measured: Int64 = 0) {
        let category = DigCategory(id: id, kind: kind, vein: categories.count, items: items.sorted { $0.bytes > $1.bytes },
                                   measured: measured)
        categories.append(category)
        field.markTrail(category.vein, bytes: category.total)
    }

    /// `mo clean --dry-run` writes the paths behind each section to Mole's preview file; with them a
    /// cache can be kept by path. Sections the file does not list keep Mole's own rows.
    private func attachPreviewPaths() {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/mole/clean-list.txt")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let groups = Dictionary(CleanListParser.parse(text).map { ($0.title, $0.entries) }, uniquingKeysWith: +)
        let kept = Set(app?.settings.protectedPaths ?? [])
        for index in categories.indices where categories[index].kind == .cache {
            guard let entries = groups[categories[index].id], !entries.isEmpty else { continue }
            categories[index].items = entries
                .map { DigItem(id: $0.path, name: Self.displayName(for: $0.path), path: $0.path, bytes: $0.bytes ?? 0,
                               included: !kept.contains(Paths.abbreviatingHome($0.path))) }
                .sorted { $0.bytes > $1.bytes }
        }
    }

    // MARK: Picking

    func toggleCaches() {
        guard phase == .ready, cachesClearable else { return }
        cachesIncluded.toggle()
        relight()
    }

    func toggle(_ category: DigCategory) {
        guard canEdit(category), let index = categories.firstIndex(where: { $0.id == category.id }), category.isPickable else { return }
        let include = category.selection == .none
        for item in categories[index].items.indices { categories[index].items[item].included = include }
        relight()
    }

    func toggle(_ item: DigItem, in category: DigCategory) {
        guard canEdit(category), category.isPickable || phase == .ready,
              let c = categories.firstIndex(where: { $0.id == category.id }),
              let i = categories[c].items.firstIndex(where: { $0.id == item.id }) else { return }
        if category.kind == .cache {
            guard let path = item.path, let app else { return }
            let pattern = Paths.abbreviatingHome(path)
            do {
                if item.included {
                    try app.settings.addProtectedPath(pattern)
                    app.notify("\(item.name) will always be kept", symbol: "shield.lefthalf.filled")
                } else {
                    try app.settings.removeProtectedPath(pattern)
                }
            } catch {
                app.notify(error.localizedDescription, symbol: "exclamationmark.triangle.fill", warning: true)
                return
            }
        }
        categories[c].items[i].included.toggle()
        relight()
    }

    private func relight() {
        var shares: [Int: Double] = [:]
        for category in categories where category.total > 0 {
            shares[category.vein] = Double(picked(category)) / Double(category.total)
        }
        field.light(shares)
    }

    // MARK: Clearing

    func clear() async {
        guard phase == .ready, selectedTotal > 0, let app, let runner = app.runner, app.begin(.dig) else { return }
        defer { app.end(.dig) }
        hoveredVein = nil
        let picks = Dictionary(uniqueKeysWithValues: categories.map { ($0.vein, picked($0)) })
        let installerIDs = pickedIDs(.installers)
        let artifactIDs = pickedIDs(.projects)
        app.disk.refreshVolume()
        freeBefore = app.disk.free
        remaining = picks.values.reduce(0, +)
        cleared = 0
        clearNotes = []
        phase = .clearing(nil, stopping: false)
        field.setContinuous(true)
        var rank = 0

        if cacheCategories.contains(where: { picks[$0.vein, default: 0] > 0 }) {
            phase = .clearing(.cache, stopping: false)
            let outcome = await job.run(["clean"], with: runner, options: adminOptions(app)) { [weak self] line in
                if let text = Self.tickerText(line) { self?.ticker = text }
            }
            let report = MoleReportParser.parse(job.text)
            let keptByMole = report.summary + report.rows.filter { $0.status == .attention || $0.status == .failed }.map(\.title)
            switch outcome {
            case .completed:
                release(.cache, picks: picks, rank: &rank)
            case .failed(let error):
                clearNotes.append(error.localizedDescription)
            case .stopped:
                clearNotes.append("Stopped before Mole finished. Some caches may already be cleared.")
                clearNotes += keptByMole
            case .exited(let code):
                clearNotes += keptByMole
                if clearNotes.isEmpty { clearNotes.append("Mole stopped with exit code \(code). Some caches may already be cleared.") }
            }
        }
        let pickedInstallers = installerFiles.filter { installerIDs.contains($0.id) }
        if !phase.isStopping, !pickedInstallers.isEmpty {
            phase = .clearing(.installers, stopping: false)
            ticker = "Installers"
            await removal(.installers, picks: picks, rank: &rank) { try await InstallerWorkflow.remove(pickedInstallers, with: runner) }
        }
        let pickedArtifacts = artifacts.filter { artifactIDs.contains($0.id) }
        if !phase.isStopping, !pickedArtifacts.isEmpty {
            phase = .clearing(.projects, stopping: false)
            ticker = "Build leftovers"
            await removal(.projects, picks: picks, rank: &rank, removedAll: { _ in
                pickedArtifacts.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }
            }) { try await PurgeWorkflow.remove(pickedArtifacts, with: runner) }
        }
        phase = .clearing(nil, stopping: phase.isStopping)
        field.setContinuous(false)
        try? await Task.sleep(for: .seconds(0.35))
        field.settle()
        app.disk.refreshVolume()
        phase = .done
        if !clearNotes.isEmpty {
            app.notify("Mole kept some items. Details are in the panel.", symbol: "exclamationmark.triangle.fill", warning: true)
        }
        Task { await app.disk.loadOverview() }
    }

    private func pickedIDs(_ kind: DigCategory.Kind) -> Set<String> {
        guard let category = categories.first(where: { $0.kind == kind }) else { return [] }
        return Set(category.items.filter(\.included).map(\.id))
    }

    /// Mole checks its own removal list against the pick before it confirms, so a file that changed since the dig is never removed blindly.
    /// `mo purge` also exits with an error for artifacts it could not inspect while scanning, which were never
    /// picked, so build leftovers count as removed once none of the picked paths is left.
    private func removal(_ kind: DigCategory.Kind, picks: [Int: Int64], rank: inout Int,
                         removedAll: (RemovalOutcome) -> Bool = \.succeeded,
                         _ run: () async throws -> RemovalOutcome) async {
        do {
            let outcome = try await run()
            if removedAll(outcome) {
                release(kind, picks: picks, rank: &rank)
            } else {
                clearNotes += outcome.summary + outcome.notices
            }
        } catch {
            clearNotes.append(error.localizedDescription)
        }
    }

    private func release(_ kind: DigCategory.Kind, picks: [Int: Int64], rank: inout Int) {
        for category in categories where category.kind == kind {
            let bytes = picks[category.vein, default: 0]
            cleared += bytes
            remaining = max(remaining - bytes, 0)
            field.release(category.vein, rank: rank)
            rank += 1
        }
    }

    func finish() {
        phase = .idle
        hoveredVein = nil
        categories = []
        review = []
        clearNotes = []
        applyLayers(animated: true)
    }

    // MARK: Helpers

    private func adminOptions(_ app: AppModel) -> SessionOptions {
        guard includeSystem else { return SessionOptions() }
        return SessionOptions(
            admin: app.admin.provider(reason: "Including system caches and logs needs your Mac password."),
            authenticateFirst: true
        )
    }

    /// The section or row Mole is working on, without its mark or measurements; notices are skipped.
    static func tickerText(_ line: String) -> String? {
        let text = TerminalText.plain(line).trimmingCharacters(in: .whitespaces)
        guard let first = text.first, "➤○✓⊙".contains(first) else { return nil }
        let name = String(text.dropFirst()).trimmingCharacters(in: .whitespaces).components(separatedBy: " · ").first ?? ""
        return name.isEmpty ? nil : name
    }

    /// A cache folder's owner rather than its full path: the app for a bundle ID, or the parent for generic names.
    static func displayName(for path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        if name.split(separator: ".").count >= 3,
           let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) {
            return FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        }
        let parent = url.deletingLastPathComponent().lastPathComponent
        let containers: Set<String> = ["Caches", "Logs", "Library", "Application Support", "Containers", "Group Containers", "Cache"]
        guard !containers.contains(parent) else { return name }
        let owner = parent.hasPrefix(".") ? String(parent.dropFirst()) : parent
        return "\(owner) › \(name)"
    }
}
