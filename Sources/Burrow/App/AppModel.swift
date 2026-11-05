import BurrowCore
import Foundation
import Observation

enum Section: String, CaseIterable, Identifiable {
    case dig, apps, space, log

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dig: "Dig"
        case .apps: "Apps"
        case .space: "Space"
        case .log: "Log"
        }
    }

    var symbol: String? {
        switch self {
        case .dig: nil
        case .apps: "square.grid.2x2"
        case .space: "square.3.layers.3d"
        case .log: "clock"
        }
    }
}

/// Work that changes files. Only one runs at a time, so two Mole commands never touch the same files.
enum Change {
    case dig, tuneUp, uninstall
}

@MainActor
@Observable
final class AppModel {
    var section: Section = .dig
    var showingSettings = false
    private(set) var toast: Toast?
    private(set) var busy: Change?
    let runner: MoleRunner?
    let moleVersion: String?
    let admin = AdminBroker()

    let disk: DiskModel
    let dig: DigModel
    let vitals: VitalsModel
    let tuneUp: TuneUpModel
    let apps: AppsModel
    let space: SpaceModel
    let log: LogModel
    let settings: SettingsModel
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    init() {
        runner = MoleInstallation.locate().map(MoleRunner.init(installation:))
        moleVersion = runner.flatMap { Self.version(of: $0.installation.executable) }
        disk = DiskModel()
        dig = DigModel()
        vitals = VitalsModel()
        tuneUp = TuneUpModel()
        apps = AppsModel()
        space = SpaceModel()
        log = LogModel()
        settings = SettingsModel()
        disk.attach(to: self)
        dig.attach(to: self)
        vitals.attach(to: self)
        tuneUp.attach(to: self)
        apps.attach(to: self)
        space.attach(to: self)
        log.attach(to: self)
        settings.attach(to: self)
        guard let runner else { return }
        Task.detached(priority: .userInitiated) { runner.prepare() }
        Task { await disk.loadOverview() }
        Task { await apps.load() }
    }

    private static func version(of executable: URL) -> String? {
        guard let source = try? String(contentsOf: executable, encoding: .utf8),
              let line = source.split(separator: "\n").first(where: { $0.hasPrefix("VERSION=") })
        else { return nil }
        return line.dropFirst("VERSION=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    func canStart(_ change: Change) -> Bool { busy == nil || busy == change }

    func begin(_ change: Change) -> Bool {
        guard busy == nil else {
            notify("Another task is still running", symbol: "hourglass", warning: true)
            return false
        }
        busy = change
        return true
    }

    func end(_ change: Change) {
        if busy == change { busy = nil }
        log.markStale()
    }

    func diskChanged() {
        disk.refreshVolume()
        Task { await disk.loadOverview() }
    }

    func notify(_ text: String, symbol: String = "checkmark.circle.fill", warning: Bool = false) {
        toastTask?.cancel()
        toast = Toast(text: text, symbol: symbol, warning: warning)
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(warning ? 5 : 2.6))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}

@MainActor
@Observable
final class AdminBroker {
    struct Request: Identifiable {
        let id = UUID()
        let reason: String
        let attempt: Int
    }

    var request: Request?
    private var pending: CheckedContinuation<String?, Never>?

    func provider(reason: String) -> AdminPasswordProvider {
        { [weak self] attempt in
            guard let self else { return nil }
            return await self.ask(reason: reason, attempt: attempt)
        }
    }

    private func ask(reason: String, attempt: Int) async -> String? {
        pending?.resume(returning: nil)
        return await withCheckedContinuation { continuation in
            pending = continuation
            request = Request(reason: reason, attempt: attempt)
        }
    }

    func answer(_ password: String?) {
        let continuation = pending
        pending = nil
        request = nil
        continuation?.resume(returning: password)
    }
}

@MainActor
@Observable
final class DiskModel {
    private(set) var name = "Macintosh HD"
    private(set) var total: Int64 = 0
    private(set) var free: Int64 = 0
    private(set) var overview: DiskReport?
    private(set) var loadingOverview = false
    private weak var app: AppModel?

    func attach(to app: AppModel) {
        self.app = app
        refreshVolume()
    }

    var used: Int64 { max(total - free, 0) }
    var layers: [DiskLayer] { DiskLayers.make(overview: overview, used: used) }

    func refreshVolume() {
        let keys: Set<URLResourceKey> = [.volumeLocalizedNameKey, .volumeTotalCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) else { return }
        name = values.volumeLocalizedName ?? name
        total = Int64(values.volumeTotalCapacity ?? 0)
        free = values.volumeAvailableCapacityForImportantUsage ?? 0
    }

    func loadOverview() async {
        guard let app, let runner = app.runner, !loadingOverview else { return }
        loadingOverview = true
        defer { loadingOverview = false }
        do {
            let result = try await runner.capture(["analyze", "--json"])
            overview = try MoleJSON.decode(DiskReport.self, from: result.output)
            refreshVolume()
            app.dig.layersChanged()
            app.space.layersChanged()
        } catch {
            app.notify("Mole could not measure the disk. \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill", warning: true)
        }
    }
}
