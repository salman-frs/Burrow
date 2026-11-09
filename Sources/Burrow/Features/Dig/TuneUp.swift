import BurrowCore
import SwiftUI

@MainActor
@Observable
final class TuneUpModel {
    enum Phase { case idle, checking, ready, running, finished }

    private(set) var phase: Phase = .idle
    private(set) var plan = MoleReport()
    private(set) var progress = MoleReport()
    private(set) var failure: String?
    let job = MoleJob()
    private weak var app: AppModel?

    func attach(to app: AppModel) { self.app = app }

    var tasks: [ReportSection] { plan.sections }
    var diagnosis: [ReportRow] { plan.notices.filter { $0.status == .attention } }

    func state(of task: String) -> TaskProgress {
        switch phase {
        case .running: progress.progress(of: task, finished: false)
        case .finished: progress.progress(of: task, finished: true)
        case .idle, .checking, .ready: .pending
        }
    }

    func check() async {
        guard let runner = app?.runner, phase == .idle else { return }
        phase = .checking
        failure = nil
        await job.run(["optimize", "--dry-run"], with: runner)
        if Task.isCancelled {
            phase = .idle
            return
        }
        let plan = MoleReportParser.parse(job.text)
        if let error = job.failure {
            failure = "Tune up could not check this Mac. \(error.localizedDescription)"
        } else if plan.sections.isEmpty {
            failure = job.lastMeaningfulLine ?? "Mole listed no tasks to run."
        }
        guard failure == nil else {
            phase = .idle
            return
        }
        self.plan = plan
        phase = .ready
    }

    /// Mole asks for administrator access itself and skips only the tasks that need it when you decline.
    func run() async {
        guard let app, let runner = app.runner, phase == .ready, app.begin(.tuneUp) else { return }
        defer { app.end(.tuneUp) }
        phase = .running
        progress = MoleReport()
        var streamed = ""
        let options = SessionOptions(admin: app.admin.provider(
            reason: "Refreshing DNS, the network stack, Spotlight and permissions needs your Mac password. Cancel to run only the tasks that don't."
        ))
        await job.run(["optimize"], with: runner, options: options) { [weak self] line in
            streamed += line + "\n"
            self?.progress = MoleReportParser.parse(streamed)
        }
        progress = MoleReportParser.parse(job.text)
        phase = .finished
        if let error = job.failure {
            app.notify(error.localizedDescription, symbol: "exclamationmark.triangle.fill", warning: true)
        } else if job.stopping {
            app.notify("Tune up stopped", symbol: "stop.circle.fill", warning: true)
        } else {
            let failed = tasks.filter { state(of: $0.title) == .failed }.count
            if failed > 0 {
                app.notify(failed == 1 ? "Tune up finished. 1 task failed." : "Tune up finished. \(failed) tasks failed.",
                           symbol: "exclamationmark.triangle.fill", warning: true)
            } else {
                app.notify("Tune up finished", symbol: "bolt.fill")
            }
        }
    }

    func stop() { job.stop() }

    func reset() {
        guard phase == .finished else { return }
        phase = .ready
        progress = MoleReport()
    }
}

struct TuneUpButton: View {
    @Environment(AppModel.self) private var app
    @ViewState private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 7) {
                if app.tuneUp.phase == .running {
                    Spinner(size: 13)
                } else {
                    Image(systemName: "bolt.fill").foregroundStyle(Palette.accent)
                }
                Text(app.tuneUp.phase == .running ? "Tuning up" : "Tune up").font(.system(size: 13, weight: .medium))
            }
            .padding(.leading, 12)
            .padding(.trailing, 15)
            .frame(height: 38)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .glass(Capsule())
        .popover(isPresented: $open, arrowEdge: .bottom) {
            TuneUpPopover(model: app.tuneUp) { open = false }
        }
    }
}

private struct TuneUpPopover: View {
    let model: TuneUpModel
    let close: () -> Void
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 10) {
            if let note = model.diagnosis.first {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Palette.accentText)
                    Text(note.title)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4)
            }
            if let failure = model.failure, model.phase == .idle {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Palette.accentText)
                    Text(failure)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 160)
            } else if model.phase == .idle || model.phase == .checking {
                VStack(spacing: 10) {
                    Spinner(size: 20)
                    Text("Checking").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(model.tasks) { task in
                        TaskTile(task: task, state: model.state(of: task.title))
                    }
                }
            }
            action
        }
        .padding(10)
        .frame(width: 360)
        .task { await model.check() }
    }

    @ViewBuilder
    private var action: some View {
        switch model.phase {
        case .idle where model.failure != nil:
            Button { Task { await model.check() } } label: { Text("Try again").frame(maxWidth: .infinity) }
                .buttonStyle(QuietButtonStyle(filled: true))
        case .idle, .checking:
            Button {} label: { Text("Run all").frame(maxWidth: .infinity) }
                .buttonStyle(AccentButtonStyle())
                .disabled(true)
        case .ready:
            Button { Task { await model.run() } } label: {
                Text("Run all \(model.tasks.count)").frame(maxWidth: .infinity)
            }
            .buttonStyle(AccentButtonStyle())
            .disabled(!app.canStart(.tuneUp))
            .help(app.canStart(.tuneUp) ? "" : "Another task is still running")
        case .running:
            Button { model.stop() } label: { Text(model.job.stopping ? "Stopping" : "Stop").frame(maxWidth: .infinity) }
                .buttonStyle(QuietButtonStyle(filled: true))
                .disabled(model.job.stopping)
        case .finished:
            Button {
                model.reset()
                close()
            } label: {
                Text("Done").frame(maxWidth: .infinity)
            }
            .buttonStyle(AccentButtonStyle())
        }
    }
}

private struct TaskTile: View {
    let task: ReportSection
    let state: TaskProgress

    var body: some View {
        let (label, symbol) = Self.presentation(of: task.title)
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .regular))
                .symbolEffect(.pulse, isActive: state == .running)
                .foregroundStyle(iconStyle)
                .frame(height: 22)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(labelStyle)
        .padding(.top, 14)
        .padding(.bottom, 11)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
        .background(state == .running ? AnyShapeStyle(Palette.accent.opacity(0.18)) : AnyShapeStyle(Palette.hover),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if let dot = dotColor {
                Circle().fill(dot).frame(width: 7, height: 7).padding(7).transition(.scale)
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.4), value: state)
        .help(task.rows.map(\.title).joined(separator: "\n"))
    }

    private var iconStyle: AnyShapeStyle {
        switch state {
        case .running: AnyShapeStyle(Palette.accentText)
        case .done: AnyShapeStyle(Palette.done)
        case .failed: AnyShapeStyle(Palette.danger)
        case .pending, .skipped: AnyShapeStyle(.secondary)
        }
    }

    private var labelStyle: AnyShapeStyle {
        switch state {
        case .running: AnyShapeStyle(Palette.accentText)
        case .done, .failed: AnyShapeStyle(.primary)
        case .pending: AnyShapeStyle(.secondary)
        case .skipped: AnyShapeStyle(.tertiary)
        }
    }

    private var dotColor: AnyShapeStyle? {
        switch state {
        case .done: AnyShapeStyle(Palette.done)
        case .failed: AnyShapeStyle(Palette.danger)
        case .skipped: AnyShapeStyle(Color.secondary)
        case .pending, .running: nil
        }
    }

    /// Short names for Mole's optimize sections; anything Mole adds later keeps its own title.
    static func presentation(of title: String) -> (String, String) {
        switch title {
        case "Finder Cache Refresh": ("Thumbnails", "photo")
        case "App State Cleanup": ("App states", "macwindow")
        case "Broken Config Repair": ("Preferences", "slider.horizontal.3")
        case "Network Cache Refresh": ("DNS", "globe")
        case "Database Optimization": ("Databases", "cylinder.split.1x2")
        case "Prevent Finder .DS_Store": (".DS_Store", "folder")
        case "Legacy Overrides": ("Overrides", "arrow.uturn.backward")
        case "Network Stack Refresh": ("Network", "network")
        case "Permission Repair": ("Permissions", "key")
        case "Spotlight Optimization": ("Spotlight", "magnifyingglass")
        case "Spotlight Orphan Rules": ("Search rules", "line.3.horizontal.decrease")
        case "Periodic Maintenance": ("Maintenance", "wrench.and.screwdriver")
        case "Shared File Lists": ("File lists", "list.bullet")
        case "Disk Health": ("Disk", "internaldrive")
        case "Login Items": ("Login items", "person.crop.circle")
        case "Quarantine Database Cleanup": ("Quarantine", "shield")
        case "Launch Agents Cleanup": ("Agents", "gearshape.2")
        case "Notifications": ("Notifications", "bell")
        case "Usage Data": ("Usage data", "chart.bar")
        default: (title, "bolt")
        }
    }
}
