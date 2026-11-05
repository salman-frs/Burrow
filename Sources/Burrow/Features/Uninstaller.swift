import AppKit
import BurrowCore
import SwiftUI

@MainActor
@Observable
final class UninstallerModel {
    private(set) var apps: [InstalledApp] = []
    private(set) var sizes: [String: Int64] = [:]
    private(set) var loading = false
    private(set) var failure: String?
    var search = ""
    var selection: Set<InstalledApp.ID> = []
    var removePersonalData = false

    private(set) var plan: UninstallPlan?
    private(set) var reviewedApps: [InstalledApp] = []
    private(set) var reviewedWithData = false
    private(set) var planning = false
    var showingPlan = false
    private(set) var running = false
    private(set) var outcome: RemovalOutcome?
    private(set) var runFailure: String?
    private weak var app: AppModel?

    func attach(to app: AppModel) { self.app = app }

    var visibleApps: [InstalledApp] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let matching = query.isEmpty ? apps : apps.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.bundleId.localizedCaseInsensitiveContains(query)
        }
        return matching.sorted { (sizes[$0.path] ?? 0) > (sizes[$1.path] ?? 0) }
    }

    var selectedApps: [InstalledApp] { apps.filter { selection.contains($0.id) } }

    func load() async {
        guard let runner = app?.runner, !loading else { return }
        loading = true
        failure = nil
        do {
            apps = try await UninstallWorkflow.installedApps(with: runner)
            selection = selection.intersection(apps.map(\.id))
            await measure(apps)
        } catch {
            failure = error.localizedDescription
        }
        loading = false
    }

    /// The plan must name the exact bundles that were picked; anything else stays unconfirmable.
    var planCoversSelection: Bool {
        guard let plan, plan.apps.count == reviewedApps.count else { return false }
        return reviewedApps.allSatisfy { app in plan.apps.contains { $0.files.contains(app.path) } }
    }

    func review() async {
        guard let runner = app?.runner, !selectedApps.isEmpty else { return }
        let targets = selectedApps
        let unclear = UninstallWorkflow.ambiguous(targets, among: apps)
        guard unclear.isEmpty else {
            runFailure = "Another app shares the name of \(unclear.map(\.name).joined(separator: ", ")), so Mole could not tell them apart. Uninstall it from Terminal with mo uninstall."
            return
        }
        planning = true
        runFailure = nil
        do {
            plan = try await UninstallWorkflow.preview(targets, withData: removePersonalData, with: runner)
            reviewedApps = targets
            reviewedWithData = removePersonalData
            showingPlan = true
        } catch {
            runFailure = error.localizedDescription
        }
        planning = false
    }

    func uninstall() async {
        guard let app, let runner = app.runner, app.beginChange(in: .uninstaller) else { return }
        defer { app.endChange(in: .uninstaller) }
        let targets = reviewedApps
        showingPlan = false
        running = true
        runFailure = nil
        outcome = nil
        do {
            outcome = try await UninstallWorkflow.uninstall(
                targets, among: apps, withData: reviewedWithData, with: runner,
                admin: app.admin.provider(reason: "Removing \(targets.count == 1 ? targets[0].name : "these apps") needs administrator access.")
            )
            selection = []
        } catch {
            runFailure = error.localizedDescription
        }
        running = false
        await load()
    }

    func dismissOutcome() {
        outcome = nil
        runFailure = nil
    }

    private func measure(_ apps: [InstalledApp]) async {
        let pending = apps.map(\.path).filter { sizes[$0] == nil }
        let measured = await Task.detached(priority: .utility) {
            pending.map { ($0, DirectorySize.allocated(at: URL(fileURLWithPath: $0))) }
        }.value
        for (path, size) in measured { sizes[path] = size }
    }
}

enum DirectorySize {
    static func allocated(at url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

struct UninstallerView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var model = app.uninstaller
        VStack(spacing: 0) {
            ModuleHeader(module: .uninstaller) {
                TextField("Search apps", text: $model.search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
            if let outcome = model.outcome {
                OutcomeBanner(tone: outcome.succeeded ? .success : .warning,
                              title: outcome.summary.first ?? "Uninstall finished",
                              lines: Array(outcome.summary.dropFirst()),
                              onDismiss: model.dismissOutcome)
                    .padding(.horizontal, 28).padding(.bottom, 12)
            }
            if let failure = model.runFailure {
                OutcomeBanner(tone: .failure, title: "Nothing was uninstalled", lines: [failure], onDismiss: model.dismissOutcome)
                    .padding(.horizontal, 28).padding(.bottom, 12)
            }
            if model.apps.isEmpty && model.loading {
                ProgressView("Finding apps…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let failure = model.failure, model.apps.isEmpty {
                EmptyPrompt(symbol: "xmark.app", title: "The app list could not be read", message: failure) {
                    Button("Try again") { Task { await model.load() } }
                }
            } else {
                AppTable(model: model)
            }
            SelectionBar(
                count: model.selection.count,
                bytes: model.selectedApps.compactMap { model.sizes[$0.path] }.reduce(0, +),
                noun: ("app", "apps")
            ) {
                Toggle("Also remove personal data", isOn: $model.removePersonalData)
                    .help("Settings, containers and saved state. Browser profiles and game libraries stay unselected.")
                Button(model.planning ? "Reviewing…" : "Review") { Task { await model.review() } }
                    .buttonStyle(.accent)
                    .disabled(model.selection.isEmpty || model.planning || model.running || !app.canStartChange(in: .uninstaller))
            }
        }
        .overlay {
            if model.running {
                WorkingStrip(title: "Uninstalling", detail: "Mole is moving the apps and their files to the Trash")
                    .frame(width: 420)
            }
        }
        .sheet(isPresented: $model.showingPlan) {
            if let plan = model.plan {
                UninstallPlanSheet(plan: plan, coversSelection: model.planCoversSelection) {
                    Task { await model.uninstall() }
                } cancel: {
                    model.showingPlan = false
                }
            }
        }
        .task { if model.apps.isEmpty { await model.load() } }
    }
}

private struct AppTable: View {
    @Bindable var model: UninstallerModel

    var body: some View {
        Table(model.visibleApps, selection: $model.selection) {
            TableColumn("App") { app in
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                        .resizable().frame(width: 26, height: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.name)
                        Text(app.bundleId).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            TableColumn("Source") { app in
                Text(app.source == "Brew" ? "Homebrew" : app.source).foregroundStyle(.secondary)
            }
            .width(90)
            TableColumn("Size") { app in
                if let size = model.sizes[app.path] {
                    SizeLabel(text: ByteSize.format(size))
                } else {
                    Text("…").foregroundStyle(.tertiary)
                }
            }
            .width(90)
        }
        .contextMenu(forSelectionType: InstalledApp.ID.self) { ids in
            if let path = ids.first {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            }
        }
    }
}

struct SelectionBar<Controls: View>: View {
    let count: Int
    let bytes: Int64
    let noun: (singular: String, plural: String)
    @ViewBuilder var controls: Controls

    var body: some View {
        HStack(spacing: 16) {
            if count == 0 {
                Text("Select \(noun.plural) to continue").foregroundStyle(.secondary)
            } else {
                Text("\(count) \(count == 1 ? noun.singular : noun.plural)").font(.headline)
                if bytes > 0 { SizeLabel(text: ByteSize.format(bytes)) }
            }
            Spacer()
            controls
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

private struct UninstallPlanSheet: View {
    let plan: UninstallPlan
    let coversSelection: Bool
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Review before uninstalling").font(.title3.weight(.semibold))
            Text("Mole moves everything below to the Trash. You can put it back from there.")
                .foregroundStyle(.secondary)
            List {
                ForEach(plan.apps) { app in
                    Section {
                        ForEach(app.files, id: \.self) { PlanPath(path: $0, symbol: "trash") }
                        ForEach(app.systemPaths, id: \.self) { PlanPath(path: $0, symbol: "lock") }
                        ForEach(app.reviewOnly, id: \.self) { PlanPath(path: $0, symbol: "eye") }
                    } header: {
                        HStack {
                            Text(app.name)
                            if app.viaHomebrew { Text("Homebrew").foregroundStyle(.secondary) }
                            if app.isRunning { Text("Running").foregroundStyle(Mineral.citrine) }
                            Spacer()
                            Text(app.sizeLabel)
                        }
                    }
                }
                if !plan.personalDataRemoved.isEmpty {
                    Section("Personal data to remove") {
                        ForEach(plan.personalDataRemoved, id: \.self) { PlanPath(path: $0, symbol: "person.crop.circle.badge.minus") }
                    }
                }
                if !plan.personalDataKept.isEmpty {
                    Section("Personal data kept") {
                        ForEach(plan.personalDataKept, id: \.self) { PlanPath(path: $0, symbol: "person.crop.circle.badge.checkmark") }
                    }
                }
                if !plan.notes.isEmpty {
                    Section("Notes from Mole") {
                        ForEach(plan.notes, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
                    }
                }
            }
            .frame(minHeight: 320)
            if !coversSelection {
                Text("Mole's plan does not match the apps you picked, so Burrow won't uninstall them. Check the list and try again.")
                    .font(.callout).foregroundStyle(Mineral.garnet)
            }
            if plan.apps.contains(where: \.isRunning) {
                Text("Some of these apps are running. Quit them before you continue.")
                    .font(.callout).foregroundStyle(Mineral.citrine)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button(plan.apps.count == 1 ? "Uninstall \(plan.apps[0].name)" : "Uninstall \(plan.apps.count) apps", action: confirm)
                    .buttonStyle(.accent)
                    .environment(\.moduleAccent, Module.uninstaller.accent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!coversSelection)
            }
        }
        .padding(22)
        .frame(width: 620, height: 560)
    }
}

private struct PlanPath: View {
    let path: String
    let symbol: String

    var body: some View {
        Label {
            Text(Paths.abbreviatingHome(path)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}
