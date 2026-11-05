import AppKit
import BurrowCore
import SwiftUI

/// The shared flow behind Project Purge, Installers and App Slimming: Mole lists
/// candidates, the user picks, and Mole's own menu removes exactly that pick.
@MainActor
@Observable
class SelectionModel<Item: Identifiable & Hashable & Sendable> where Item.ID: Sendable {
    let module: Module
    private(set) var items: [Item] = []
    private(set) var scanning = false
    private(set) var scanned = false
    private(set) var working = false
    private(set) var outcome: RemovalOutcome?
    private(set) var failure: String?
    private(set) var notes: [String] = []
    var selection: Set<Item.ID> = []
    fileprivate(set) weak var app: AppModel?

    init(module: Module) { self.module = module }

    func attach(to app: AppModel) { self.app = app }

    var selectedItems: [Item] { items.filter { selection.contains($0.id) } }

    func scan() async {
        guard let runner = app?.runner, !scanning else { return }
        scanning = true
        failure = nil
        do {
            let found = try await list(with: runner)
            items = found.items
            notes = found.notes
            selection = selection.intersection(items.map(\.id))
            scanned = true
        } catch {
            failure = error.localizedDescription
        }
        scanning = false
    }

    func apply() async {
        guard let app, let runner = app.runner, !selectedItems.isEmpty, app.beginChange(in: module) else { return }
        defer { app.endChange(in: module) }
        working = true
        failure = nil
        outcome = nil
        do {
            outcome = try await perform(selectedItems, with: runner, app: app)
            selection = []
        } catch {
            failure = error.localizedDescription
        }
        working = false
        await scan()
    }

    func dismissOutcome() {
        outcome = nil
        failure = nil
    }

    func invalidate() {
        scanned = false
    }

    func list(with runner: MoleRunner) async throws -> (items: [Item], notes: [String]) { ([], []) }

    func perform(_ items: [Item], with runner: MoleRunner, app: AppModel) async throws -> RemovalOutcome {
        fatalError("subclasses perform their own removal")
    }
}

final class ProjectsModel: SelectionModel<PathEntry> {
    init() { super.init(module: .projects) }

    override func list(with runner: MoleRunner) async throws -> (items: [PathEntry], notes: [String]) {
        let (artifacts, report) = try await PurgeWorkflow.scan(with: runner)
        let notes = report.notices.filter { $0.status == .attention }.map(\.title)
        return (artifacts, notes)
    }

    override func perform(_ items: [PathEntry], with runner: MoleRunner, app: AppModel) async throws -> RemovalOutcome {
        try await PurgeWorkflow.remove(items, with: runner)
    }
}

final class InstallersModel: SelectionModel<InstallerFile> {
    init() { super.init(module: .installers) }

    override func list(with runner: MoleRunner) async throws -> (items: [InstallerFile], notes: [String]) {
        (try await InstallerWorkflow.scan(with: runner), [])
    }

    override func perform(_ items: [InstallerFile], with runner: MoleRunner, app: AppModel) async throws -> RemovalOutcome {
        try await InstallerWorkflow.remove(items, with: runner)
    }
}

// MARK: Views

private struct SelectionScreen<Item: Identifiable & Hashable & Sendable, Row: View, Empty: View>: View where Item.ID: Sendable {
    let model: SelectionModel<Item>
    let bytes: (Item) -> Int64
    let noun: (singular: String, plural: String)
    let actionTitle: String
    let workingTitle: String
    let emptyTitle: String
    let emptyMessage: String
    @ViewBuilder let row: (Item) -> Row
    @ViewBuilder let footnote: () -> Empty
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            ModuleHeader(module: model.module) {
                if model.scanned {
                    Button("Scan again") { Task { await model.scan() } }
                        .disabled(model.scanning || model.working)
                }
            }
            if let outcome = model.outcome {
                OutcomeBanner(tone: outcome.succeeded ? .success : .warning,
                              title: outcome.summary.first ?? "Finished",
                              lines: Array(outcome.summary.dropFirst()) + (outcome.succeeded ? [] : outcome.notices),
                              onDismiss: model.dismissOutcome)
                    .padding(.horizontal, 28).padding(.bottom, 12)
            }
            if let failure = model.failure {
                OutcomeBanner(tone: .failure, title: "Nothing was changed", lines: [failure], onDismiss: model.dismissOutcome)
                    .padding(.horizontal, 28).padding(.bottom, 12)
            }
            HStack(alignment: .top, spacing: 28) {
                StrataColumn(layers: model.items.sorted { bytes($0) > bytes($1) }.prefix(40).map {
                    StrataLayer(id: "\($0.id)", title: "\($0.id)", bytes: bytes($0))
                })
                .frame(width: 54)
                .frame(maxHeight: .infinity)
                content(model)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 16)
            SelectionBar(count: model.selection.count,
                         bytes: model.selectedItems.map(bytes).reduce(0, +),
                         noun: noun) {
                if !model.items.isEmpty {
                    Button(model.selection.count == model.items.count ? "Select none" : "Select all") {
                        model.selection = model.selection.count == model.items.count ? [] : Set(model.items.map(\.id))
                    }
                }
                Button(actionTitle) { Task { await model.apply() } }
                    .buttonStyle(.accent)
                    .disabled(model.selection.isEmpty || model.working || !app.canStartChange(in: model.module))
            }
        }
        .overlay {
            if model.working {
                WorkingStrip(title: workingTitle, detail: "Mole checks each item again before it changes anything")
                    .frame(width: 440)
            }
        }
        .task { if !model.scanned { await model.scan() } }
    }

    @ViewBuilder
    private func content(_ model: SelectionModel<Item>) -> some View {
        if model.scanning && model.items.isEmpty {
            VStack { WorkingStrip(title: "Scanning", detail: nil); Spacer() }
        } else if model.items.isEmpty && model.scanned {
            EmptyPrompt(symbol: model.module.symbol, title: emptyTitle, message: emptyMessage) { footnote() }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.notes, id: \.self) { note in
                    Label(note, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary)
                }
                List(model.items, selection: Bindable(model).selection) { item in
                    row(item).tag(item.id)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                footnote()
            }
        }
    }
}

struct ProjectsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        SelectionScreen(
            model: app.projects,
            bytes: { $0.bytes ?? 0 },
            noun: ("artifact", "artifacts"),
            actionTitle: "Remove",
            workingTitle: "Removing build artifacts",
            emptyTitle: "No old build artifacts",
            emptyMessage: "Mole looks in your project folders for build output and dependencies untouched for at least a week. Add folders in Settings."
        ) { entry in
            ArtifactRow(entry: entry)
        } footnote: {
            Text("Artifacts changed in the last 7 days are never offered. Projects rebuild them on the next build or install.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ArtifactRow: View {
    let entry: PathEntry

    var body: some View {
        let url = URL(fileURLWithPath: entry.path)
        HStack(spacing: 10) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent)
                Text(Paths.abbreviatingHome(url.deletingLastPathComponent().path))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            SizeLabel(text: entry.sizeLabel)
        }
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }
}

struct InstallersView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        SelectionScreen(
            model: app.installers,
            bytes: { $0.bytes ?? 0 },
            noun: ("installer", "installers"),
            actionTitle: "Move to Trash",
            workingTitle: "Moving installers to the Trash",
            emptyTitle: "No installers lying around",
            emptyMessage: "Mole checks Downloads, Desktop, Documents and a few app download folders for .dmg, .pkg, .iso, .xip and installer archives."
        ) { file in
            HStack(spacing: 10) {
                Image(systemName: icon(for: file.name)).foregroundStyle(.secondary).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.name).lineLimit(1).truncationMode(.middle)
                    Text(file.source).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                SizeLabel(text: file.sizeLabel)
            }
        } footnote: {
            EmptyView()
        }
    }

    private func icon(for name: String) -> String {
        switch URL(fileURLWithPath: name).pathExtension.lowercased() {
        case "pkg", "mpkg": "shippingbox"
        case "zip": "doc.zipper"
        default: "opticaldiscdrive"
        }
    }
}
