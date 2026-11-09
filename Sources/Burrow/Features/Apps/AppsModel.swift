import AppKit
import BurrowCore
import Foundation
import Observation

@MainActor
@Observable
final class AppsModel {
    enum Order: CaseIterable { case largest, name, slimmable }
    enum Listing: Equatable { case notLoaded, loading, loaded, failed(String) }

    enum PlanState {
        case nothingSelected
        case planning
        case planned(PlannedRemoval)
        case failed(String)
    }

    enum Removal: Equatable { case idle, uninstalling, leaving(Set<String>) }

    struct PlannedRemoval {
        let plan: UninstallPlan
        let paths: [FootprintPart: [String]]
        let parts: [FootprintPart: Int64]
        let personalPaths: [String]
        let personalBytes: Int64
    }

    private(set) var apps: [InstalledApp] = []
    private(set) var names: [String: String] = [:]
    private(set) var sizes: [String: Int64] = [:]
    /// Intel code Mole can strip, keyed by app path.
    private(set) var slimmable: [String: Int64] = [:]
    private(set) var slimmableChecked = false
    private(set) var listing = Listing.notLoaded
    var search = ""
    var order: Order = .largest
    private(set) var selection: Set<String> = []
    private(set) var includePersonalData = false

    private(set) var planState = PlanState.nothingSelected
    private(set) var removal = Removal.idle
    let footprint = DotField(pitch: 7, radius: 2, seed: 5, drawsAir: false)
    private var planTask: Task<Void, Never>?
    private weak var app: AppModel?

    func attach(to app: AppModel) { self.app = app }

    // MARK: List

    func name(of app: InstalledApp) -> String { names[app.path] ?? app.name }

    var totalBytes: Int64 { sizes.values.reduce(0, +) }

    var visibleApps: [InstalledApp] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let matching = query.isEmpty ? apps : apps.filter {
            name(of: $0).localizedCaseInsensitiveContains(query) || $0.bundleId.localizedCaseInsensitiveContains(query)
        }
        switch order {
        case .largest:
            return matching.sorted { (sizes[$0.path] ?? 0) > (sizes[$1.path] ?? 0) }
        case .name:
            return matching.sorted { name(of: $0).localizedStandardCompare(name(of: $1)) == .orderedAscending }
        case .slimmable:
            return matching.filter { slimmable[$0.path] != nil }.sorted { slimmable[$0.path, default: 0] > slimmable[$1.path, default: 0] }
        }
    }

    func load() async {
        guard let runner = app?.runner, listing != .loading else { return }
        listing = .loading
        do {
            apps = try await UninstallWorkflow.installedApps(with: runner)
            for app in apps where names[app.path] == nil {
                names[app.path] = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
            }
            let installed = Set(apps.map(\.path))
            if !selection.isSubset(of: installed) {
                selection.formIntersection(installed)
                selectionChanged()
            }
            listing = .loaded
        } catch {
            listing = Task.isCancelled ? .notLoaded : .failed(error.localizedDescription)
        }
        await measure()
        await findSlimmable(with: runner)
    }

    private func measure() async {
        let pending = apps.map(\.path).filter { sizes[$0] == nil }
        let measured = await Task.detached(priority: .utility) {
            pending.map { ($0, DirectorySize.allocated(at: URL(fileURLWithPath: $0))) }
        }.value
        for (path, size) in measured { sizes[path] = size }
    }

    private func findSlimmable(with runner: MoleRunner) async {
        defer { slimmableChecked = true }
        guard let candidates = try? await SlimWorkflow.scan(with: runner) else { return }
        var found: [String: Int64] = [:]
        for candidate in candidates {
            guard let match = apps.first(where: { $0.name == candidate.name || name(of: $0) == candidate.name }) else { continue }
            found[match.path] = candidate.bytes ?? 0
        }
        slimmable = found
    }

    // MARK: Selection

    var selectedApps: [InstalledApp] { apps.filter { selection.contains($0.id) } }

    var selectionLabel: String {
        let picked = selectedApps
        return picked.count == 1 ? name(of: picked[0]) : "\(picked.count) apps"
    }

    func toggle(_ installed: InstalledApp) {
        guard !uninstalling else { return }
        if selection.contains(installed.id) { selection.remove(installed.id) } else { selection.insert(installed.id) }
        selectionChanged()
    }

    func pick(droppedURLs urls: [URL]) -> Bool {
        guard !uninstalling else { return false }
        let paths = Set(urls.map { $0.standardizedFileURL.path })
        let matches = apps.filter { paths.contains($0.path) }
        guard !matches.isEmpty else { return false }
        selection.formUnion(matches.map(\.id))
        selectionChanged()
        return true
    }

    func togglePersonalData() {
        guard !uninstalling else { return }
        includePersonalData.toggle()
        selectionChanged()
    }

    var uninstalling: Bool { removal != .idle }

    var leaving: Set<String> {
        if case .leaving(let paths) = removal { paths } else { [] }
    }

    var slimBytes: Int64 { selectedApps.compactMap { slimmable[$0.path] }.reduce(0, +) }

    private var planned: PlannedRemoval? {
        if case .planned(let planned) = planState { planned } else { nil }
    }

    var planning: Bool {
        if case .planning = planState { true } else { false }
    }

    var paths: [FootprintPart: [String]] { planned?.paths ?? [:] }
    var personalPaths: [String] { planned?.personalPaths ?? [] }
    var personalBytes: Int64 { planned?.personalBytes ?? 0 }

    /// Until Mole's plan arrives, only the app bundles are known.
    func bytes(of part: FootprintPart) -> Int64 {
        planned?.parts[part] ?? (part == .app ? selectedApps.compactMap { sizes[$0.path] }.reduce(0, +) : 0)
    }

    var footprintTotal: Int64 {
        FootprintPart.allCases.map(bytes(of:)).reduce(0, +) + (includePersonalData ? personalBytes : 0)
    }

    /// The plan must name the exact bundles that were picked; anything else stays unconfirmable.
    var planCoversSelection: Bool {
        guard let plan = planned?.plan, plan.apps.count == selection.count else { return false }
        return selectedApps.allSatisfy { app in plan.apps.contains { $0.files.contains(app.path) } }
    }

    var runningApps: [String] { planned?.plan.apps.filter(\.isRunning).map(\.name) ?? [] }

    var planProblem: String? {
        switch planState {
        case .failed(let reason): reason
        case .planned where !planCoversSelection: "Mole's plan does not match the apps you picked, so Burrow won't uninstall them."
        case .nothingSelected, .planning, .planned: nil
        }
    }

    private func selectionChanged() {
        planTask?.cancel()
        planState = selection.isEmpty ? .nothingSelected : .planning
        layoutFootprint(animate: true)
        guard !selection.isEmpty else { return }
        planTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.35))
            guard !Task.isCancelled else { return }
            await self?.preview()
        }
    }

    private func preview() async {
        guard let runner = app?.runner else { return }
        let targets = selectedApps
        let unclear = UninstallWorkflow.ambiguous(targets, among: apps)
        guard unclear.isEmpty else {
            planState = .failed("Another app shares the name of \(unclear.map(name(of:)).joined(separator: ", ")). Uninstall it from Terminal with mo uninstall.")
            return
        }
        let withData = includePersonalData
        do {
            let plan = try await UninstallWorkflow.preview(targets, withData: withData, with: runner)
            guard !Task.isCancelled else { return }
            let files = plan.apps.flatMap { $0.files + $0.systemPaths }
            let personal = (withData ? plan.personalDataRemoved : plan.personalDataKept).filter { !files.contains($0) }
            let measured = await Task.detached(priority: .userInitiated) {
                Dictionary((files + personal).map { ($0, DirectorySize.allocated(at: URL(fileURLWithPath: $0))) }, uniquingKeysWith: max)
            }.value
            guard !Task.isCancelled else { return }
            let paths = Dictionary(grouping: files, by: FootprintPart.of)
            planState = .planned(PlannedRemoval(
                plan: plan,
                paths: paths,
                parts: paths.mapValues { $0.map { measured[$0] ?? 0 }.reduce(0, +) },
                personalPaths: personal,
                personalBytes: personal.map { measured[$0] ?? 0 }.reduce(0, +)
            ))
            layoutFootprint(animate: true)
        } catch {
            guard !Task.isCancelled else { return }
            planState = .failed(error.localizedDescription)
        }
    }

    func footprintResized(to size: CGSize) {
        if footprint.resize(to: size) || !footprint.hasLayout { layoutFootprint(animate: false) }
    }

    private func layoutFootprint(animate: Bool) {
        guard !selection.isEmpty else { return }
        let strata = FootprintPart.allCases.reversed().map { part in
            Stratum(name: part.title, bytes: bytes(of: part) + (part == .data && includePersonalData ? personalBytes : 0),
                    shade: part.shade)
        }
        footprint.layout(strata, total: max(footprintTotal, 1), animate: animate)
    }

    // MARK: Changes

    func uninstall() async {
        guard let app, let runner = app.runner, planCoversSelection, !uninstalling, app.begin(.uninstall) else { return }
        let targets = selectedApps
        let label = selectionLabel
        let total = footprintTotal
        removal = .uninstalling
        do {
            let outcome = try await UninstallWorkflow.uninstall(
                targets, among: apps, withData: includePersonalData, with: runner,
                admin: app.admin.provider(reason: "Removing \(label) needs your Mac password.")
            )
            if outcome.succeeded {
                let removed = Set(targets.map(\.path))
                removal = .leaving(removed)
                try? await Task.sleep(for: .seconds(0.4))
                apps.removeAll { removed.contains($0.path) }
                for path in removed { sizes[path] = nil }
                selection = []
                includePersonalData = false
                selectionChanged()
                app.notify("\(label) moved to Trash, \(ByteText.string(total))", symbol: "trash.fill")
                app.diskChanged()
            } else {
                app.notify(outcome.summary.first ?? "Mole stopped before it finished.", symbol: "exclamationmark.triangle.fill", warning: true)
            }
        } catch {
            app.notify(error.localizedDescription, symbol: "exclamationmark.triangle.fill", warning: true)
        }
        removal = .idle
        app.end(.uninstall)
        await load()
    }

    /// `mo slim` redraws only the rows that change in its menu, which Burrow cannot follow,
    /// so the choice happens in Mole's own picker in Terminal.
    func slimInTerminal() {
        guard let executable = app?.runner?.installation.executable else { return }
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("burrow-slim-\(UUID().uuidString).command")
        do {
            try SlimWorkflow.terminalScript(moleExecutable: executable).write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
            app?.log.markStale()
        } catch {
            app?.notify("Terminal could not be opened. \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill", warning: true)
        }
    }
}

extension FootprintPart {
    var title: String {
        switch self {
        case .app: "App"
        case .data: "Data"
        case .caches: "Caches"
        case .settings: "Settings"
        }
    }

    var shade: Shade {
        switch self {
        case .app: .ramp(2)
        case .data: .ramp(5)
        case .caches: .accent
        case .settings: .ramp(8)
        }
    }
}
