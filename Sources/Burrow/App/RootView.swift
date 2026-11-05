import BurrowCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        @Bindable var admin = model.admin
        Group {
            if model.runner == nil {
                MissingEngineView()
            } else {
                NavigationSplitView {
                    Sidebar(selection: $model.selection, busyModule: model.busyModule)
                        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
                } detail: {
                    ModuleView(module: model.selection)
                        .environment(\.moduleAccent, model.selection.accent)
                        .tint(model.selection.accent)
                }
            }
        }
        .sheet(item: $admin.request) { request in
            PasswordSheet(request: request) { admin.answer($0) }
                .interactiveDismissDisabled()
        }
    }
}

private struct Sidebar: View {
    @Binding var selection: Module
    let busyModule: Module?

    var body: some View {
        List(selection: $selection) {
            ForEach(Module.sidebarGroups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.modules) { module in
                        Label {
                            HStack {
                                Text(module.title)
                                Spacer()
                                if busyModule == module {
                                    ProgressView().controlSize(.mini)
                                }
                            }
                        } icon: {
                            Image(systemName: module.symbol).foregroundStyle(module.accent)
                        }
                        .tag(module)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

private struct ModuleView: View {
    let module: Module

    var body: some View {
        switch module {
        case .overview: OverviewView()
        case .cleanup: CleanupView()
        case .optimize: OptimizeView()
        case .uninstaller: UninstallerView()
        case .slim: SlimView()
        case .spaceLens: SpaceLensView()
        case .projects: ProjectsView()
        case .installers: InstallersView()
        case .history: HistoryView()
        case .settings: SettingsView()
        }
    }
}

private struct MissingEngineView: View {
    var body: some View {
        EmptyPrompt(
            symbol: "exclamationmark.triangle",
            title: "Mole is missing from this copy of Burrow",
            message: "Burrow runs every scan and cleanup through the copy of Mole inside the app. Download Burrow again, or build it with scripts/build-app.sh."
        ) { EmptyView() }
    }
}

struct PasswordSheet: View {
    let request: AdminBroker.Request
    let onAnswer: (String?) -> Void
    @ViewState private var password = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Burrow needs your administrator password").font(.headline)
                    Text(request.reason).font(.callout).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                SecureField("Password for \(NSFullUserName())", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(allow)
                if request.attempt > 1 {
                    Text("That password didn't work. Try again.")
                        .font(.caption)
                        .foregroundStyle(Mineral.garnet)
                }
                Text("Mole uses it once with sudo for this task. Burrow never stores it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onAnswer(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Allow", action: allow)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 420)
        .onAppear { focused = true }
    }

    private func allow() {
        guard !password.isEmpty else { return }
        let answer = password
        password = ""
        onAnswer(answer)
    }
}
