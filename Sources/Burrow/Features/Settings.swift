import AppKit
import BurrowCore
import SwiftUI

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

    func removeProtectedPath(_ pattern: String) {
        perform { try PatternFile.cleanWhitelist.write(try savedProtectedPaths().filter { $0 != pattern }) }
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
        app?.projects.invalidate()
    }

    func removeProjectFolder(_ pattern: String) {
        perform { try PatternFile.purgePaths.write((try PatternFile.purgePaths.read() ?? []).filter { $0 != pattern }) }
        app?.projects.invalidate()
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

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @ViewState private var newPattern = ""
    @ViewState private var patternProblem: String?

    var body: some View {
        let model = app.settings
        VStack(spacing: 0) {
            ModuleHeader(module: .settings)
            Form {
                if let failure = model.failure {
                    OutcomeBanner(tone: .failure, title: "Something went wrong", lines: [failure])
                }

                Section {
                    ForEach(model.protectedPaths, id: \.self) { pattern in
                        HStack {
                            Text(pattern == "FINDER_METADATA" ? "Finder metadata (.DS_Store)" : pattern)
                                .lineLimit(1).truncationMode(.middle)
                            if model.moleDefaults.contains(pattern) {
                                Text("Mole default").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Remove") { model.removeProtectedPath(pattern) }
                                .buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        TextField("Path or pattern, like ~/Library/Caches/com.example.app", text: $newPattern)
                            .onSubmit(addPattern)
                        Button("Choose…") { choose(directory: false) { newPattern = Paths.abbreviatingHome($0) } }
                        Button("Add", action: addPattern).disabled(newPattern.isEmpty)
                    }
                    if let patternProblem {
                        Text(patternProblem).font(.caption).foregroundStyle(Mineral.garnet)
                    }
                    if !model.usingMoleDefaults {
                        Button("Restore Mole's defaults") { model.restoreMoleDefaults() }
                    }
                } header: {
                    Text("Protected from cleanup")
                } footer: {
                    Text("Cleanup never touches these paths. Mole's built-in safety rules apply on top of this list. Wildcards like * are allowed.")
                }

                Section {
                    if model.projectFolders.isEmpty {
                        Text("Mole searches its usual project locations, such as ~/Projects, ~/Code and ~/Developer.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.projectFolders, id: \.self) { folder in
                        HStack {
                            Text(folder)
                            Spacer()
                            Button("Remove") { model.removeProjectFolder(folder) }.buttonStyle(.borderless)
                        }
                    }
                    Button("Add folder…") { choose(directory: true) { model.addProjectFolder($0) } }
                } header: {
                    Text("Project folders")
                } footer: {
                    Text("Adding a folder replaces the default list, so add every folder you want Project Purge to search.")
                }

                Section {
                    LabeledContent("Touch ID for administrator tasks") {
                        switch model.touchID {
                        case .enabled:
                            Button("Turn off") { Task { await model.setTouchID(enabled: false) } }.disabled(model.touchIDBusy)
                        case .disabled:
                            Button("Turn on") { Task { await model.setTouchID(enabled: true) } }.disabled(model.touchIDBusy)
                        case .unknown:
                            Text("Unavailable").foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Administrator access")
                } footer: {
                    Text("When it's on, macOS shows its own Touch ID prompt instead of Burrow's password sheet. This changes how sudo authenticates everywhere on this Mac, including Terminal.")
                }

                Section("About") {
                    LabeledContent("Burrow", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development")
                    LabeledContent("Mole engine", value: app.moleVersion ?? "unknown")
                    Text("Burrow is free software under the GNU GPL v3. Every scan and cleanup runs through Mole by tw93, bundled unmodified.")
                        .foregroundStyle(.secondary)
                    Link("Mole on GitHub", destination: URL(string: "https://github.com/tw93/Mole")!)
                }
            }
            .formStyle(.grouped)
        }
        .task {
            model.reload()
            await model.refreshTouchID()
        }
    }

    private func addPattern() {
        do {
            try app.settings.addProtectedPath(newPattern.trimmingCharacters(in: .whitespaces))
            newPattern = ""
            patternProblem = nil
        } catch {
            patternProblem = error.localizedDescription
        }
    }

    private func choose(directory: Bool, then use: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = !directory
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { use(url.path) }
    }
}
