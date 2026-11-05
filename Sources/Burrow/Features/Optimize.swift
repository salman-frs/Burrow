import BurrowCore
import SwiftUI

@MainActor
@Observable
final class OptimizeModel {
    enum Phase { case idle, previewing, ready, running, finished }

    private(set) var phase: Phase = .idle
    private(set) var plan = MoleReport()
    private(set) var result = MoleReport()
    private(set) var failure: String?
    let job = MoleJob()
    private weak var app: AppModel?

    func attach(to app: AppModel) { self.app = app }

    var tasks: [ReportSection] { plan.sections }

    func preview() async {
        guard let app, let runner = app.runner, app.beginChange(in: .optimize) else { return }
        defer { app.endChange(in: .optimize) }
        phase = .previewing
        failure = nil
        await job.run(["optimize", "--dry-run"], with: runner)
        if let error = job.failure {
            failure = error.localizedDescription
            phase = .idle
            return
        }
        plan = MoleReportParser.parse(job.text)
        phase = .ready
    }

    /// Mole asks for administrator access itself and skips only the tasks that need it when you decline.
    func run() async {
        guard let app, let runner = app.runner, app.beginChange(in: .optimize) else { return }
        defer { app.endChange(in: .optimize) }
        phase = .running
        failure = nil
        result = MoleReport()
        var streamed = ""
        let options = SessionOptions(admin: app.admin.provider(
            reason: "Refreshing DNS, the network stack, Spotlight and permissions needs administrator access. Cancel to run only the tasks that don't."
        ))
        await job.run(["optimize"], with: runner, options: options) { [weak self] line in
            streamed += line + "\n"
            self?.result = MoleReportParser.parse(streamed)
        }
        if let error = job.failure {
            failure = error.localizedDescription
        }
        result = MoleReportParser.parse(job.text)
        phase = .finished
    }

    func stop() { job.stop() }
}

struct OptimizeView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.optimize
        VStack(alignment: .leading, spacing: 0) {
            ModuleHeader(module: .optimize) {
                switch model.phase {
                case .idle:
                    Button("Check my Mac") { Task { await model.preview() } }
                        .buttonStyle(.accent)
                        .disabled(!app.canStartChange(in: .optimize))
                case .ready:
                    Button("Check again") { Task { await model.preview() } }
                    Button("Run optimizations") { Task { await model.run() } }
                        .buttonStyle(.accent)
                        .disabled(!app.canStartChange(in: .optimize))
                case .finished:
                    Button("Check again") { Task { await model.preview() } }
                        .disabled(!app.canStartChange(in: .optimize))
                case .previewing, .running:
                    EmptyView()
                }
            }
            Group {
                switch model.phase {
                case .idle:
                    EmptyPrompt(
                        symbol: "bolt.horizontal",
                        title: "Check what can be refreshed",
                        message: "Burrow asks Mole which maintenance tasks would change anything on this Mac. Nothing runs until you choose to."
                    ) {
                        if let failure = model.failure {
                            OutcomeBanner(tone: .failure, title: "The check did not finish", lines: [failure])
                        }
                    }
                case .previewing:
                    VStack { WorkingStrip(title: "Checking maintenance tasks", detail: model.job.lastMeaningfulLine); Spacer() }
                case .ready:
                    TaskList(sections: model.tasks, summary: model.plan.summary, diagnosis: model.plan.notices)
                case .running:
                    VStack(alignment: .leading, spacing: 14) {
                        WorkingStrip(title: model.job.stopping ? "Stopping after the current task" : "Optimizing",
                             detail: model.job.lastMeaningfulLine,
                             onStop: model.job.stopping ? nil : { model.stop() })
                        TaskList(sections: model.result.sections, summary: [], diagnosis: [])
                    }
                case .finished:
                    VStack(alignment: .leading, spacing: 14) {
                        let summary = model.result.summary
                        OutcomeBanner(tone: model.job.exitCode == 0 ? .success : .warning,
                                      title: summary.first ?? "Optimization finished",
                                      lines: Array(summary.dropFirst()) + [model.failure].compactMap { $0 })
                        TaskList(sections: model.result.sections, summary: [], diagnosis: [])
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
    }
}

private struct TaskList: View {
    let sections: [ReportSection]
    let summary: [String]
    let diagnosis: [ReportRow]

    var body: some View {
        List {
            if !diagnosis.filter({ $0.status == .attention }).isEmpty {
                Section("Diagnosis") {
                    ForEach(diagnosis.filter { $0.status == .attention }) { ReportRowView(row: $0) }
                }
            }
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.rows) { ReportRowView(row: $0) }
                }
            }
            if !summary.isEmpty {
                Section {
                    ForEach(summary, id: \.self) { Text($0).foregroundStyle(.secondary) }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }
}
