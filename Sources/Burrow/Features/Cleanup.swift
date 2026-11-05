import AppKit
import BurrowCore
import SwiftUI

@MainActor
@Observable
final class CleanupModel {
    enum Phase { case idle, scanning, ready, cleaning, finished }

    private(set) var phase: Phase = .idle
    private(set) var report = MoleReport()
    private(set) var paths: [String: [PathEntry]] = [:]
    private(set) var outcome: MoleReport?
    private(set) var failure: String?
    private(set) var keptPaths: Set<String> = []
    var includeSystem = false
    let job = MoleJob()
    private weak var app: AppModel?

    func attach(to app: AppModel) { self.app = app }

    var reclaimable: Int64 {
        report.summaryBytes(labeled: "Potential space:") ?? report.sections.map(\.measuredBytes).reduce(0, +)
    }

    var reclaimablePartial: Bool {
        report.summary.contains { $0.hasPrefix("Potential space:") && $0.contains("+") }
    }

    var cleanableSections: [ReportSection] {
        report.sections.filter { section in section.rows.contains { $0.status == .pending } }
    }

    var reviewRows: [ReportRow] { report.rows.filter { $0.status == .review } }

    var strata: [StrataLayer] {
        cleanableSections
            .map { StrataLayer(id: $0.title, title: $0.title, bytes: $0.measuredBytes) }
            .filter { $0.bytes > 0 }
            .sorted { $0.bytes > $1.bytes }
    }

    func scan() async {
        guard let app, let runner = app.runner, app.beginChange(in: .cleanup) else { return }
        defer { app.endChange(in: .cleanup) }
        phase = .scanning
        failure = nil
        outcome = nil
        keptPaths = []
        report = MoleReport()
        var streamed = ""
        await job.run(["clean", "--dry-run"], with: runner, options: adminOptions(app)) { [weak self] line in
            streamed += line + "\n"
            self?.report = MoleReportParser.parse(streamed)
        }
        if let error = job.failure {
            failure = error.isAdminDeclined ? nil : error.localizedDescription
            phase = .idle
            return
        }
        guard !job.stopping else {
            phase = .idle
            return
        }
        report = MoleReportParser.parse(job.text)
        loadPreviewPaths()
        phase = .ready
    }

    func clean() async {
        guard let app, let runner = app.runner, app.beginChange(in: .cleanup) else { return }
        defer { app.endChange(in: .cleanup) }
        phase = .cleaning
        failure = nil
        await job.run(["clean"], with: runner, options: adminOptions(app))
        if let error = job.failure {
            failure = error.localizedDescription
            phase = .ready
            return
        }
        outcome = MoleReportParser.parse(job.text)
        phase = .finished
    }

    func stop() { job.stop() }

    var wasStopped: Bool { job.stopping }

    func reset() {
        phase = .idle
        outcome = nil
        report = MoleReport()
    }

    func keep(_ path: String) {
        guard let app else { return }
        do {
            try app.settings.addProtectedPath(Paths.abbreviatingHome(path))
            keptPaths.insert(path)
        } catch {
            failure = "Could not update the protected paths: \(error.localizedDescription)"
        }
    }

    private func adminOptions(_ app: AppModel) -> SessionOptions {
        guard includeSystem else { return SessionOptions() }
        return SessionOptions(
            admin: app.admin.provider(reason: "Cleaning system caches and logs needs administrator access."),
            authenticateFirst: true
        )
    }

    private func loadPreviewPaths() {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/mole/clean-list.txt")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        paths = Dictionary(CleanListParser.parse(text).map { ($0.title, $0.entries) }, uniquingKeysWith: { $0 + $1 })
    }
}

struct CleanupView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var model = app.cleanup
        VStack(spacing: 0) {
            ModuleHeader(module: .cleanup) {
                if model.phase == .idle || model.phase == .ready || model.phase == .finished {
                    Toggle("Include system caches", isOn: $model.includeSystem)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .help("Asks for your administrator password before the scan")
                }
            }
            HStack(alignment: .top, spacing: 28) {
                StrataColumn(layers: model.strata)
                    .frame(width: 54)
                    .frame(maxHeight: .infinity)
                content(model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
    }

    @ViewBuilder
    private func content(_ model: CleanupModel) -> some View {
        switch model.phase {
        case .idle:
            IdleCleanup(model: model, busy: !app.canStartChange(in: .cleanup))
        case .scanning:
            VStack(alignment: .leading, spacing: 18) {
                Figure(bytes: model.reclaimable, caption: "found so far")
                WorkingStrip(title: model.job.stopping ? "Stopping" : "Scanning", detail: model.job.lastMeaningfulLine,
                             onStop: model.job.stopping ? nil : { model.stop() })
                SectionList(model: model, interactive: false)
            }
        case .ready:
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .bottom) {
                    Figure(bytes: model.reclaimable, caption: "can be cleaned", partial: model.reclaimablePartial)
                    Spacer()
                    Button("Scan again") { Task { await model.scan() } }
                    Button("Clean") { Task { await model.clean() } }
                        .buttonStyle(.accent)
                        .disabled(model.cleanableSections.isEmpty || !app.canStartChange(in: .cleanup))
                }
                if let failure = model.failure {
                    OutcomeBanner(tone: .failure, title: "The scan stopped early", lines: [failure])
                }
                SectionList(model: model, interactive: true)
            }
        case .cleaning:
            VStack(alignment: .leading, spacing: 18) {
                Figure(bytes: model.reclaimable, caption: "being cleaned", partial: model.reclaimablePartial)
                WorkingStrip(title: model.job.stopping ? "Stopping after the current step" : "Cleaning",
                             detail: model.job.lastMeaningfulLine,
                             onStop: model.job.stopping ? nil : { model.stop() })
                TranscriptDisclosure(lines: model.job.lines)
                Spacer()
            }
        case .finished:
            FinishedCleanup(model: model)
        }
    }
}

private struct IdleCleanup: View {
    let model: CleanupModel
    let busy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Spacer()
            Text("Find what your Mac can safely rebuild")
                .font(.figure(30))
            Text("The scan only looks. You review the result before anything is removed, and files you clean go through Mole's protection rules first.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460, alignment: .leading)
            if let failure = model.failure {
                OutcomeBanner(tone: .failure, title: "The scan did not finish", lines: [failure])
                    .frame(maxWidth: 460)
            }
            Button("Scan") { Task { await model.scan() } }
                .buttonStyle(.accent)
                .controlSize(.large)
                .disabled(busy)
                .padding(.top, 6)
            if busy {
                Text("Another task is running. Scan when it finishes.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

private struct SectionList: View {
    let model: CleanupModel
    let interactive: Bool

    var body: some View {
        List {
            ForEach(model.cleanableSections) { section in
                Section {
                    ForEach(section.rows.filter { $0.status != .review }) { row in
                        ReportRowView(row: row)
                    }
                    if interactive, let entries = model.paths[section.title], !entries.isEmpty {
                        DisclosureGroup("\(entries.count) paths") {
                            ForEach(entries.prefix(300)) { entry in
                                PathRow(entry: entry, kept: model.keptPaths.contains(entry.path)) {
                                    model.keep(entry.path)
                                }
                            }
                        }
                        .font(.callout)
                    }
                } header: {
                    HStack {
                        Text(section.title)
                        Spacer()
                        Text(ByteSize.format(section.measuredBytes)).monospacedDigit()
                    }
                }
            }
            if interactive, !model.reviewRows.isEmpty {
                Section("Worth a look") {
                    ForEach(model.reviewRows) { row in
                        ReportRowView(row: row)
                    }
                    Text("Mole lists these but never removes them for you.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
    }
}

struct ReportRowView: View {
    let row: ReportRow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                StatusGlyph(status: row.status)
                Text(row.title)
                Spacer()
                if let bytes = row.bytes {
                    SizeLabel(text: ByteSize.format(bytes))
                } else if !row.detail.isEmpty {
                    Text(row.detail).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if row.bytes != nil, !row.detail.isEmpty {
                Text(row.detail).font(.caption).foregroundStyle(.secondary).padding(.leading, 26)
            }
            ForEach(row.children, id: \.self) { child in
                Text(child).font(.caption).foregroundStyle(.secondary).padding(.leading, 26)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct PathRow: View {
    let entry: PathEntry
    let kept: Bool
    let keep: () -> Void

    var body: some View {
        HStack {
            Text(Paths.abbreviatingHome(entry.path))
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .strikethrough(kept)
                .foregroundStyle(kept ? .secondary : .primary)
            Spacer()
            if kept {
                Text("Kept").font(.caption).foregroundStyle(.secondary)
            } else {
                SizeLabel(text: entry.sizeLabel)
            }
        }
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
            }
            Button("Always keep this") { keep() }.disabled(kept)
        }
    }
}

private struct FinishedCleanup: View {
    let model: CleanupModel

    var body: some View {
        let summary = model.outcome?.summary ?? []
        let complete = model.job.exitCode == 0
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            Text(headline(complete: complete)).font(.figure(30))
            OutcomeBanner(tone: complete ? .success : .warning,
                          title: summary.first ?? (model.wasStopped ? "Stopped before Mole finished" : "Cleanup finished"),
                          lines: Array(summary.dropFirst()))
                .frame(maxWidth: 520)
            HStack {
                Button("Scan again") { Task { await model.scan() } }.buttonStyle(.accent)
                Button("Done") { model.reset() }
            }
            TranscriptDisclosure(lines: model.job.lines).frame(maxWidth: 640)
            Spacer()
        }
    }

    private func headline(complete: Bool) -> String {
        if complete { return "Your Mac is cleaner" }
        return model.wasStopped ? "Cleanup stopped" : "Cleanup finished with warnings"
    }
}
