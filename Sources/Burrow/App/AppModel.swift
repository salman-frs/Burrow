import BurrowCore
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    var selection: Module = .overview
    let runner: MoleRunner?
    let admin = AdminBroker()

    /// Only one change runs at a time, so two Mole commands never work on the same files.
    private(set) var busyModule: Module?

    let overview: OverviewModel
    let cleanup: CleanupModel
    let optimize: OptimizeModel
    let uninstaller: UninstallerModel
    let slim: SlimModel
    let spaceLens: SpaceLensModel
    let projects: ProjectsModel
    let installers: InstallersModel
    let history: HistoryModel
    let settings: SettingsModel

    init() {
        runner = MoleInstallation.locate().map(MoleRunner.init(installation:))
        overview = OverviewModel()
        cleanup = CleanupModel()
        optimize = OptimizeModel()
        uninstaller = UninstallerModel()
        slim = SlimModel()
        spaceLens = SpaceLensModel()
        projects = ProjectsModel()
        installers = InstallersModel()
        history = HistoryModel()
        settings = SettingsModel()
        overview.attach(to: self)
        cleanup.attach(to: self)
        optimize.attach(to: self)
        uninstaller.attach(to: self)
        slim.attach(to: self)
        spaceLens.attach(to: self)
        projects.attach(to: self)
        installers.attach(to: self)
        history.attach(to: self)
        settings.attach(to: self)
        if let runner {
            Task.detached(priority: .userInitiated) { runner.prepare() }
        }
    }

    var moleVersion: String? {
        guard let executable = runner?.installation.executable,
              let source = try? String(contentsOf: executable, encoding: .utf8),
              let line = source.split(separator: "\n").first(where: { $0.hasPrefix("VERSION=") })
        else { return nil }
        return line.dropFirst("VERSION=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    func canStartChange(in module: Module) -> Bool {
        busyModule == nil || busyModule == module
    }

    func beginChange(in module: Module) -> Bool {
        guard busyModule == nil else { return false }
        busyModule = module
        return true
    }

    func endChange(in module: Module) {
        if busyModule == module { busyModule = nil }
        history.markStale()
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
