import AppKit
import BurrowCore
import SwiftUI

@MainActor
@Observable
final class SlimModel {
    private(set) var apps: [SlimCandidate] = []
    private(set) var scanning = false
    private(set) var scanned = false
    private(set) var failure: String?
    private weak var app: AppModel?

    func attach(to app: AppModel) { self.app = app }

    var total: Int64 { apps.compactMap(\.bytes).reduce(0, +) }

    func scan() async {
        guard let runner = app?.runner, !scanning else { return }
        scanning = true
        failure = nil
        do {
            apps = try await SlimWorkflow.scan(with: runner)
            scanned = true
        } catch {
            failure = error.localizedDescription
        }
        scanning = false
    }

    func chooseInTerminal() {
        guard let executable = app?.runner?.installation.executable else { return }
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-slim-\(UUID().uuidString).command")
        do {
            try SlimWorkflow.terminalScript(moleExecutable: executable).write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
            app?.history.markStale()
        } catch {
            failure = "Terminal could not be opened. \(error.localizedDescription)"
        }
    }
}

struct SlimView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.slim
        VStack(spacing: 0) {
            ModuleHeader(module: .slim) {
                if model.scanned {
                    Button("Scan again") { Task { await model.scan() } }.disabled(model.scanning)
                }
            }
            if let failure = model.failure {
                OutcomeBanner(tone: .failure, title: "Nothing was changed", lines: [failure])
                    .padding(.horizontal, 28).padding(.bottom, 12)
            }
            HStack(alignment: .top, spacing: 28) {
                StrataColumn(layers: model.apps.map { StrataLayer(id: $0.name, title: $0.name, bytes: $0.bytes ?? 0) })
                    .frame(width: 54)
                    .frame(maxHeight: .infinity)
                content(model)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 16)
            HStack(spacing: 16) {
                if model.apps.isEmpty {
                    Text("Mole lists universal apps here after the scan").foregroundStyle(.secondary)
                } else {
                    Text("\(model.apps.count) apps").font(.headline)
                    SizeLabel(text: "\(ByteSize.format(model.total)) of Intel code")
                }
                Spacer()
                Button("Choose apps in Terminal…") { model.chooseInTerminal() }
                    .buttonStyle(.accent)
                    .disabled(model.apps.isEmpty)
                    .help("Opens Mole's own picker in Terminal, where you choose and confirm each app")
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .task { if !model.scanned { await model.scan() } }
    }

    @ViewBuilder
    private func content(_ model: SlimModel) -> some View {
        if model.scanning && model.apps.isEmpty {
            VStack { WorkingStrip(title: "Scanning apps", detail: nil); Spacer() }
        } else if model.apps.isEmpty && model.scanned {
            EmptyPrompt(symbol: Module.slim.symbol, title: "Nothing to slim",
                        message: "Every app on this Mac is already Apple Silicon only, or this Mac has an Intel processor.") {
                EmptyView()
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                List(model.apps) { candidate in
                    HStack(spacing: 10) {
                        AppIcon(name: candidate.name)
                        Text(candidate.name)
                        Spacer()
                        SizeLabel(text: candidate.sizeLabel)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                Text("Mole slims each app on a copy that must pass code signing and Gatekeeper checks before it replaces the original, which goes to the Trash. App updates bring the Intel code back.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct AppIcon: View {
    let name: String

    var body: some View {
        let path = "/Applications/\(name).app"
        if FileManager.default.fileExists(atPath: path) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 22, height: 22)
        } else {
            Image(systemName: "app").frame(width: 22, height: 22).foregroundStyle(.secondary)
        }
    }
}
