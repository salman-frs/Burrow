import BurrowCore
import Foundation
import Observation

@MainActor
@Observable
final class SettingsModel {
    enum TouchID: Equatable {
        case unknown, on, off
        case switching(on: Bool)

        var isOn: Bool { self == .on || self == .switching(on: true) }
        var canSwitch: Bool { self == .on || self == .off }

        var isSwitching: Bool {
            if case .switching = self { true } else { false }
        }

        init(_ state: TouchIDState) {
            switch state {
            case .enabled: self = .on
            case .disabled: self = .off
            case .unknown: self = .unknown
            }
        }
    }

    private(set) var protectedPaths: [String] = []
    private(set) var moleDefaults: [String] = []
    private(set) var usingMoleDefaults = true
    private(set) var projectFolders: [String] = []
    private(set) var touchID: TouchID = .unknown
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
        guard let runner = app?.runner, !touchID.isSwitching else { return }
        let state = await TouchIDWorkflow.state(with: runner)
        if !touchID.isSwitching { touchID = TouchID(state) }
    }

    func setTouchID(enabled: Bool) async {
        guard let app, let runner = app.runner, touchID.canSwitch else { return }
        touchID = .switching(on: enabled)
        let options = SessionOptions(admin: app.admin.provider(
            reason: enabled ? "Turning on Touch ID for administrator tasks changes /etc/pam.d/sudo_local."
                : "Turning off Touch ID for administrator tasks changes /etc/pam.d/sudo_local."
        ))
        let job = MoleJob()
        switch await job.run(["touchid", enabled ? "enable" : "disable"], with: runner, options: options) {
        case .completed:
            break
        case .failed(let error):
            failure = error.localizedDescription
        case .exited, .stopped:
            failure = job.lastMeaningfulLine ?? "Mole reported an error."
        }
        touchID = TouchID(await TouchIDWorkflow.state(with: runner))
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

    var errorDescription: String? {
        switch self {
        case .invalid(let reason): reason
        }
    }
}
