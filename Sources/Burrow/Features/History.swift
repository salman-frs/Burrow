import AppKit
import BurrowCore
import SwiftUI

@MainActor
@Observable
final class HistoryModel {
    private(set) var report: HistoryReport?
    private(set) var loading = false
    private(set) var failure: String?
    private var stale = true
    var showPreviews = false
    private weak var app: AppModel?

    func attach(to app: AppModel) { self.app = app }

    func markStale() { stale = true }

    var sessions: [HistorySession] {
        (report?.sessions ?? []).filter { session in
            showPreviews || (!session.isPreview && session.operationCount > 0)
        }
    }

    func loadIfStale() async {
        guard stale else { return }
        await load()
    }

    func load() async {
        guard let runner = app?.runner else { return }
        loading = true
        failure = nil
        do {
            let result = try await runner.capture(["history", "--json", "--limit", "200"])
            report = try MoleJSON.decode(HistoryReport.self, from: result.output)
            stale = false
        } catch {
            failure = error.localizedDescription
        }
        loading = false
    }
}

struct HistoryView: View {
    @Environment(AppModel.self) private var app
    @ViewState private var tab = Tab.sessions

    enum Tab: String, CaseIterable { case sessions = "Runs", files = "Removed items" }

    var body: some View {
        @Bindable var model = app.history
        VStack(spacing: 0) {
            ModuleHeader(module: .history) {
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                Button("Refresh") { Task { await model.load() } }.disabled(model.loading)
            }
            Group {
                if let report = model.report {
                    switch tab {
                    case .sessions: SessionsTable(model: model)
                    case .files: DeletionsTable(deletions: report.deletions)
                    }
                } else if let failure = model.failure {
                    EmptyPrompt(symbol: "clock.arrow.circlepath", title: "History could not be read", message: failure) {
                        Button("Try again") { Task { await model.load() } }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task { await model.loadIfStale() }
    }
}

private struct SessionsTable: View {
    @Bindable var model: HistoryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Table(model.sessions) {
                TableColumn("Task") { session in
                    Text(title(for: session.command))
                }
                TableColumn("Started") { session in
                    Text(session.startedAt).monospacedDigit().foregroundStyle(.secondary)
                }
                .width(150)
                TableColumn("Items") { session in
                    Text(session.items.formatted()).monospacedDigit()
                }
                .width(70)
                TableColumn("Size") { session in SizeLabel(text: session.size) }
                    .width(80)
                TableColumn("Outcome") { session in
                    Text(outcome(session)).foregroundStyle(session.actions.failed > 0 ? Mineral.garnet : .secondary)
                }
            }
            Toggle("Show previews and runs that changed nothing", isOn: $model.showPreviews)
                .padding(.horizontal, 28).padding(.vertical, 10)
        }
    }

    private func title(for command: String) -> String {
        let preview = command.hasSuffix("-dry-run")
        let base = preview ? String(command.dropLast("-dry-run".count)) : command
        let names = ["clean": "Cleanup", "uninstall": "Uninstall", "optimize": "Optimize", "purge": "Project purge",
                     "installer": "Installers", "slim": "App slimming", "analyze": "Space Lens", "touchid": "Touch ID"]
        let name = names[base] ?? base.capitalized
        return preview ? "\(name) preview" : name
    }

    private func outcome(_ session: HistorySession) -> String {
        let actions = session.actions
        var parts: [String] = []
        if actions.removed > 0 { parts.append("\(actions.removed) removed") }
        if actions.trashed > 0 { parts.append("\(actions.trashed) in Trash") }
        if actions.rebuilt > 0 { parts.append("\(actions.rebuilt) rebuilt") }
        if actions.skipped > 0 { parts.append("\(actions.skipped) skipped") }
        if actions.failed > 0 { parts.append("\(actions.failed) failed") }
        return parts.isEmpty ? "No changes" : parts.joined(separator: ", ")
    }
}

private struct DeletionsTable: View {
    let deletions: [HistoryDeletion]

    var body: some View {
        Table(deletions) {
            TableColumn("Item") { deletion in
                Text(Paths.abbreviatingHome(deletion.path)).lineLimit(1).truncationMode(.middle)
                    .contextMenu {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: deletion.path)])
                        }
                    }
            }
            TableColumn("When") { deletion in
                Text(deletion.timestamp).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(170)
            TableColumn("How") { deletion in
                Text(deletion.mode == "trash" ? "Trash" : "Removed").foregroundStyle(.secondary)
            }
            .width(70)
            TableColumn("Size") { deletion in
                SizeLabel(text: deletion.sizeKb.map { ByteSize.format($0 * 1024) } ?? "–")
            }
            .width(80)
        }
    }
}
