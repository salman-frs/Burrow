import BurrowCore
import SwiftUI

@MainActor
@Observable
final class VitalsModel {
    private(set) var snapshot: StatusSnapshot?
    private(set) var cpuHistory: [Double] = []
    private var stream: Task<Void, Never>?
    private weak var app: AppModel?

    func attach(to app: AppModel) { self.app = app }

    func start() {
        guard stream == nil, let runner = app?.runner else { return }
        stream = Task { [weak self] in
            do {
                for try await event in runner.run(["status", "--watch", "--interval", "2s"]) {
                    guard case .line(let line) = event, line.hasPrefix("{"),
                          let snapshot = try? MoleJSON.decode(StatusSnapshot.self, from: Data(line.utf8)) else { continue }
                    self?.record(snapshot)
                }
            } catch {}
            self?.stream = nil
        }
    }

    func stop() {
        stream?.cancel()
        stream = nil
    }

    private func record(_ snapshot: StatusSnapshot) {
        self.snapshot = snapshot
        cpuHistory.append(snapshot.cpu.usage)
        if cpuHistory.count > 28 { cpuHistory.removeFirst(cpuHistory.count - 28) }
    }
}

struct VitalsPill: View {
    let snapshot: StatusSnapshot
    let cpuHistory: [Double]
    @ViewState private var showingHealth = false

    var body: some View {
        let hot = snapshot.cpu.usage > 75
        Button { showingHealth.toggle() } label: {
            HStack(spacing: 0) {
                Vital {
                    Image(systemName: "cpu")
                    Sparkline(values: cpuHistory).frame(width: 42, height: 18)
                    Text("\(Int(snapshot.cpu.usage.rounded()))%").fontWeight(.semibold)
                        .foregroundStyle(hot ? Palette.amberText : .primary)
                }
                .foregroundStyle(hot ? AnyShapeStyle(Palette.amberText) : AnyShapeStyle(.secondary))
                .help("Processor, \(snapshot.cpu.coreCount) cores")
                Divider().frame(height: 16)
                Vital {
                    Image(systemName: "memorychip")
                    Ring(progress: snapshot.memory.usedPercent / 100)
                    (Text(String(format: "%.1f", Double(snapshot.memory.used) / 1e9)).fontWeight(.semibold).foregroundStyle(.primary)
                     + Text(" / \(ByteText.string(snapshot.memory.total))").font(.system(size: 11)).foregroundStyle(.tertiary))
                }
                .help(memoryHelp)
                if let battery = snapshot.batteries?.first {
                    Divider().frame(height: 16)
                    Vital {
                        Image(systemName: batterySymbol(battery))
                        Text("\(Int(battery.percent.rounded()))%").fontWeight(.semibold).foregroundStyle(.primary)
                    }
                    .help("Battery, \(battery.status.lowercased()), \(battery.cycleCount) cycles")
                }
            }
            .font(.system(size: 13))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(height: 38)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .glass(Capsule())
        .popover(isPresented: $showingHealth, arrowEdge: .bottom) {
            HealthPopover(snapshot: snapshot)
        }
        .accessibilityLabel("Processor \(Int(snapshot.cpu.usage))%, memory \(Int(snapshot.memory.usedPercent))%")
    }

    private var memoryHelp: String {
        let memory = snapshot.memory
        guard memory.swapTotal > 0 else { return "Memory" }
        return "Memory, swap \(ByteText.string(memory.swapUsed)) of \(ByteText.string(memory.swapTotal))"
    }

    private func batterySymbol(_ battery: StatusSnapshot.Battery) -> String {
        if battery.status.lowercased().contains("charg") && !battery.status.lowercased().contains("discharg") {
            return "battery.100percent.bolt"
        }
        switch battery.percent {
        case ..<20: return "battery.0percent"
        case ..<45: return "battery.25percent"
        case ..<70: return "battery.50percent"
        case ..<90: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

private struct Vital<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 7) { content }
            .padding(.horizontal, 10)
            .frame(height: 26)
    }
}

private struct Sparkline: View {
    let values: [Double]

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let points = values.enumerated().map { index, value in
                CGPoint(x: CGFloat(index) / CGFloat(values.count - 1) * size.width,
                        y: size.height - CGFloat(value / 100) * (size.height - 3) - 1.5)
            }
            var line = Path()
            line.addLines(points)
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(Gradient(colors: [Palette.amber.opacity(0.28), Palette.amber.opacity(0)]),
                                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(line, with: .color(Palette.amber), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
    }
}

private struct Ring: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle().stroke(Palette.hairline, lineWidth: 3.5)
            Circle().trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(Palette.amber, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 13, height: 13)
        .animation(.easeOut(duration: 0.4), value: progress)
    }
}

private struct HealthPopover: View {
    let snapshot: StatusSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().stroke(Palette.hairline, lineWidth: 6)
                    Circle().trim(from: 0, to: CGFloat(snapshot.healthScore) / 100)
                        .stroke(Palette.amber, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(snapshot.healthScore)").font(.system(size: 20, weight: .semibold)).monospacedDigit()
                }
                .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(snapshot.healthScoreMsg).font(.system(size: 13, weight: .semibold))
                    Text("\(snapshot.hardware.model) · \(snapshot.hardware.osVersion)").font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("Up \(snapshot.uptime)").font(.system(size: 12)).foregroundStyle(.tertiary)
                }
            }
            if let processes = snapshot.topProcesses, !processes.isEmpty {
                VStack(spacing: 2) {
                    ForEach(processes.prefix(5)) { process in
                        HStack {
                            Text(process.name).lineLimit(1)
                            Spacer()
                            Text("\(Int(process.cpu.rounded()))%").foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                            Text(ByteText.string(process.memoryBytes)).foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
                        }
                        .font(.system(size: 12.5))
                        .monospacedDigit()
                        .frame(height: 24)
                    }
                }
            }
            let interfaces = snapshot.network.filter { !$0.ip.isEmpty }
            if !interfaces.isEmpty || snapshot.trashSize > 0 {
                Divider()
                VStack(spacing: 6) {
                    ForEach(interfaces) { interface in
                        HStack(spacing: 10) {
                            Image(systemName: "network").foregroundStyle(.tertiary)
                            Text(interface.name)
                            Spacer()
                            Label(rate(interface.rxRateMbs), systemImage: "arrow.down")
                            Label(rate(interface.txRateMbs), systemImage: "arrow.up")
                        }
                    }
                    if snapshot.trashSize > 0 {
                        HStack(spacing: 10) {
                            Image(systemName: "trash").foregroundStyle(.tertiary)
                            Text("Trash")
                            Spacer()
                            Text(ByteText.string(snapshot.trashSize)).foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.system(size: 12.5))
                .monospacedDigit()
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func rate(_ megabytesPerSecond: Double) -> String {
        megabytesPerSecond < 1 ? "\(Int((megabytesPerSecond * 1000).rounded())) KB/s" : String(format: "%.1f MB/s", megabytesPerSecond)
    }
}
