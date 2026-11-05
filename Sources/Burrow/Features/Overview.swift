import BurrowCore
import SwiftUI

@MainActor
@Observable
final class OverviewModel {
    private(set) var snapshot: StatusSnapshot?
    private(set) var failure: String?
    private weak var app: AppModel?
    private var stream: Task<Void, Never>?

    func attach(to app: AppModel) { self.app = app }

    func startWatching() {
        guard stream == nil, let runner = app?.runner else { return }
        stream = Task { [weak self] in
            do {
                for try await event in runner.run(["status", "--watch", "--interval", "2s"]) {
                    guard case .line(let line) = event, line.hasPrefix("{") else { continue }
                    if let snapshot = try? MoleJSON.decode(StatusSnapshot.self, from: Data(line.utf8)) {
                        self?.snapshot = snapshot
                        self?.failure = nil
                    }
                }
            } catch {
                self?.failure = error.localizedDescription
            }
            self?.stream = nil
        }
    }

    func stopWatching() {
        stream?.cancel()
        stream = nil
    }
}

struct OverviewView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.overview
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ModuleHeader(module: .overview)
                if let snapshot = model.snapshot {
                    OverviewContent(snapshot: snapshot)
                        .padding(.horizontal, 28)
                        .padding(.bottom, 28)
                } else if let failure = model.failure {
                    EmptyPrompt(symbol: "waveform.path.ecg", title: "Health data is unavailable", message: failure) {
                        Button("Try again") { model.startWatching() }
                    }
                } else {
                    ProgressView("Reading sensors…").frame(maxWidth: .infinity).padding(.top, 120)
                }
            }
        }
        .onAppear { model.startWatching() }
        .onDisappear { model.stopWatching() }
    }
}

private struct OverviewContent: View {
    let snapshot: StatusSnapshot
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(alignment: .center, spacing: 28) {
                HealthDial(score: snapshot.healthScore)
                VStack(alignment: .leading, spacing: 6) {
                    Text(snapshot.healthScoreMsg).font(.title3.weight(.semibold))
                    Text("\(snapshot.hardware.model), \(snapshot.hardware.cpuModel), \(snapshot.hardware.osVersion)")
                        .foregroundStyle(.secondary)
                    Text("Up \(snapshot.uptime), \(snapshot.procs) processes")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Button("Scan for junk") { app.selection = .cleanup }
                            .buttonStyle(.accent)
                            .environment(\.moduleAccent, Module.cleanup.accent)
                        Button("Optimize") { app.selection = .optimize }
                    }
                    .padding(.top, 8)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 36, verticalSpacing: 22) {
                GridRow {
                    Meter(title: "Processor", value: snapshot.cpu.usage / 100,
                          reading: percent(snapshot.cpu.usage),
                          detail: "Load \(String(format: "%.2f", snapshot.cpu.load1)) on \(snapshot.cpu.coreCount) cores")
                    Meter(title: "Memory", value: snapshot.memory.usedPercent / 100,
                          reading: "\(ByteSize.format(snapshot.memory.used)) of \(ByteSize.format(snapshot.memory.total))",
                          detail: swapDetail)
                }
                GridRow {
                    ForEach(snapshot.disks.prefix(2)) { disk in
                        Meter(title: disk.mount == "/" ? "Startup disk" : disk.mount,
                              value: disk.usedPercent / 100,
                              reading: "\(ByteSize.format(disk.total - disk.used)) free",
                              detail: "\(ByteSize.format(disk.used)) of \(ByteSize.format(disk.total)) used")
                    }
                    if snapshot.disks.count < 2, let battery = snapshot.batteries?.first {
                        Meter(title: "Battery", value: battery.percent / 100,
                              reading: percent(battery.percent),
                              detail: batteryDetail(battery), fullIsGood: true)
                    }
                }
            }

            HStack(alignment: .top, spacing: 36) {
                if let processes = snapshot.topProcesses, !processes.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Busiest apps").font(.headline)
                        ForEach(processes.prefix(5)) { process in
                            HStack {
                                Text(process.name).lineLimit(1)
                                Spacer()
                                Text(percent(process.cpu)).monospacedDigit().foregroundStyle(.secondary)
                                Text(ByteSize.format(process.memoryBytes))
                                    .monospacedDigit().foregroundStyle(.secondary)
                                    .frame(width: 80, alignment: .trailing)
                            }
                            .font(.callout)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Network").font(.headline)
                    ForEach(snapshot.network.filter { !$0.ip.isEmpty }) { interface in
                        HStack {
                            Text(interface.name)
                            Text(interface.ip).foregroundStyle(.secondary)
                            Spacer()
                            Label(rate(interface.rxRateMbs), systemImage: "arrow.down")
                            Label(rate(interface.txRateMbs), systemImage: "arrow.up")
                        }
                        .font(.callout)
                        .monospacedDigit()
                    }
                    if snapshot.trashSize > 0 {
                        HStack {
                            Text("Trash")
                            Spacer()
                            Text(ByteSize.format(snapshot.trashSize)).foregroundStyle(.secondary)
                        }
                        .font(.callout)
                        .padding(.top, 8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var swapDetail: String {
        guard snapshot.memory.swapTotal > 0 else { return "No swap in use" }
        return "Swap \(ByteSize.format(snapshot.memory.swapUsed)) of \(ByteSize.format(snapshot.memory.swapTotal))"
    }

    private func batteryDetail(_ battery: StatusSnapshot.Battery) -> String {
        "\(battery.status.capitalized), \(battery.health.lowercased()) health, \(battery.cycleCount) cycles"
    }

    private func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    private func rate(_ megabytesPerSecond: Double) -> String {
        megabytesPerSecond < 1
            ? "\(Int((megabytesPerSecond * 1000).rounded())) KB/s"
            : String(format: "%.1f MB/s", megabytesPerSecond)
    }
}

private struct HealthDial: View {
    let score: Int
    @Environment(\.moduleAccent) private var accent

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 10)
            Circle()
                .trim(from: 0, to: CGFloat(score) / 100)
                .stroke(color.gradient, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.6), value: score)
            VStack(spacing: 0) {
                Text("\(score)").font(.figure(40)).contentTransition(.numericText())
                Text("health").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: 128, height: 128)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Health score \(score) of 100")
    }

    private var color: Color {
        switch score {
        case ..<40: Mineral.garnet
        case ..<70: Mineral.citrine
        default: Mineral.malachite
        }
    }
}

private struct Meter: View {
    let title: String
    let value: Double
    let reading: String
    let detail: String
    var fullIsGood = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                Text(reading).font(.callout.weight(.medium)).monospacedDigit()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(color.gradient)
                        .frame(width: proxy.size.width * min(max(value, 0), 1))
                        .animation(.easeOut(duration: 0.4), value: value)
                }
            }
            .frame(height: 8)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(minWidth: 260, maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        let strain = fullIsGood ? 1 - value : value
        switch strain {
        case 0.9...: return Mineral.garnet
        case 0.75...: return Mineral.citrine
        default: return fullIsGood ? Mineral.malachite : Mineral.quartz
        }
    }
}
