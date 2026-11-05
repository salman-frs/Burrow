import BurrowCore
import Foundation
import Observation

@MainActor
@Observable
final class SettingsModel {
    private(set) var protectedPaths: [String] = []
    private(set) var moleDefaults: [String] = []
    private(set) var usingMoleDefaults = true
    private(set) var projectFolders: [String] = []
    private(set) var touchID: TouchIDState = .unknown
    private(set) var touchIDBusy = false
    private(set) var failure: String?
    private weak var app: AppModel?

    func attach(to app: AppModel) {
        self.app = app
        if let executable = app.runner?.installation.executable {
            moleDefaults = MoleDefaults.cleanWhitelist(moleExecutable: executable)
        }
        reload()
    }

    func reload() {
        do {
            let saved = try PatternFile.cleanWhitelist.read()
            usingMoleDefaults = saved == nil
            protectedPaths = saved ?? moleDefaults
            projectFolders = try PatternFile.purgePaths.read() ?? []
            failure = nil
        } catch {
            failure = "Mole's settings could not be read. \(error.localizedDescription)"
        }
    }

    /// Edits start from the file as it is now, never from what Burrow loaded earlier, and a file
    /// that cannot be read is left alone: rewriting it would drop protections Mole still honours.
    /// A missing file means Mole's defaults apply, so the first saved list starts from them.
    private func savedProtectedPaths() throws -> [String] {
        try PatternFile.cleanWhitelist.read() ?? moleDefaults
    }

    func addProtectedPath(_ pattern: String) throws {
        if let problem = PatternRules.problem(with: pattern) { throw SettingsError.invalid(problem) }
        let current = try savedProtectedPaths()
        guard !current.contains(pattern) else { return }
        try PatternFile.cleanWhitelist.write(current + [pattern])
        reload()
    }

    func removeProtectedPath(_ pattern: String) throws {
        try PatternFile.cleanWhitelist.write(try savedProtectedPaths().filter { $0 != pattern })
        reload()
    }

    func restoreMoleDefaults() {
        perform { try PatternFile.cleanWhitelist.write(moleDefaults) }
    }

    func addProjectFolder(_ path: String) {
        let pattern = Paths.abbreviatingHome(path)
        guard !projectFolders.contains(pattern) else { return }
        if let problem = PatternRules.problem(with: pattern) {
            failure = problem
            return
        }
        perform { try PatternFile.purgePaths.write((try PatternFile.purgePaths.read() ?? []) + [pattern]) }
    }

    func removeProjectFolder(_ pattern: String) {
        perform { try PatternFile.purgePaths.write((try PatternFile.purgePaths.read() ?? []).filter { $0 != pattern }) }
    }

    func refreshTouchID() async {
        guard let runner = app?.runner else { return }
        touchID = await TouchIDWorkflow.state(with: runner)
    }

    func setTouchID(enabled: Bool) async {
        guard let app, let runner = app.runner, !touchIDBusy else { return }
        touchIDBusy = true
        let options = SessionOptions(admin: app.admin.provider(
            reason: enabled ? "Turning on Touch ID for administrator tasks changes /etc/pam.d/sudo_local."
                : "Turning off Touch ID for administrator tasks changes /etc/pam.d/sudo_local."
        ))
        let job = MoleJob()
        await job.run(["touchid", enabled ? "enable" : "disable"], with: runner, options: options)
        if let error = job.failure ?? (job.exitCode == 0 ? nil : SettingsError.mole(job.lastMeaningfulLine ?? "Mole reported an error.")) {
            failure = error.localizedDescription
        }
        await refreshTouchID()
        touchIDBusy = false
    }

    private func perform(_ change: () throws -> Void) {
        do {
            try change()
            reload()
        } catch {
            failure = error.localizedDescription
        }
    }
}

enum SettingsError: LocalizedError {
    case invalid(String)
    case mole(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let reason), .mole(let reason): reason
        }
    }
}
