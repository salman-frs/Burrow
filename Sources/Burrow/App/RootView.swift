import AppKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        @Bindable var admin = app.admin
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Palette.windowTop, Palette.windowBottom], startPoint: .top, endPoint: .bottom)
            if app.runner == nil {
                MissingEngineView()
            } else {
                ZStack {
                    switch app.section {
                    case .dig: DigView()
                    case .apps: AppsView()
                    case .space: SpaceView()
                    case .log: LogView()
                    }
                }
                .id(app.section)
                .transition(.opacity)
                Sidebar()
            }
            if let toast = app.toast {
                ToastView(toast: toast)
                    .id(toast.id)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 18)
                    .transition(.move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.easeOut(duration: 0.3), value: app.section)
        .animation(.spring(duration: 0.45, bounce: 0.3), value: app.toast)
        .ignoresSafeArea()
        .sheet(item: $admin.request) { request in
            PasswordSheet(request: request) { admin.answer($0) }
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $app.showingSettings) {
            SettingsSheet()
        }
    }
}

private struct Sidebar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Color.clear.frame(height: 50)
            ForEach(Section.allCases) { section in
                NavRow(section: section, selected: app.section == section) { app.section = section }
            }
            Spacer(minLength: 0)
            DiskGauge()
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .frame(width: Metrics.sidebarWidth)
        .frame(maxHeight: .infinity)
        .glass()
        .padding(Metrics.inset)
    }
}

private struct NavRow: View {
    let section: Section
    let selected: Bool
    let action: () -> Void
    @Environment(AppModel.self) private var app
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Group {
                    if let symbol = section.symbol {
                        Image(systemName: symbol).font(.system(size: 15, weight: .medium))
                    } else {
                        ShovelIcon(size: 18)
                    }
                }
                .frame(width: 20)
                .foregroundStyle(selected ? AnyShapeStyle(Palette.amber) : AnyShapeStyle(.secondary))
                Text(section.title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(selected || hovering ? .primary : .secondary)
                Spacer(minLength: 0)
                trail
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(selected ? Palette.selected : (hovering ? Palette.hover : .clear),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var trail: some View {
        switch section {
        case .dig:
            switch app.dig.phase {
            case .digging, .clearing:
                Spinner(size: 13)
            case .ready where app.dig.selectedTotal > 0:
                Circle()
                    .fill(Palette.amber)
                    .frame(width: 8, height: 8)
                    .background(Circle().fill(Palette.amber.opacity(0.25)).frame(width: 14, height: 14))
                    .help("\(ByteText.string(app.dig.selectedTotal)) ready to clear")
            case .idle, .ready, .done:
                EmptyView()
            }
        case .apps:
            if !app.apps.apps.isEmpty {
                Text("\(app.apps.apps.count)")
                    .font(.system(size: 11.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        case .space, .log:
            EmptyView()
        }
    }
}

private struct DiskGauge: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let disk = app.disk
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.hairline)
                    Capsule()
                        .fill(.secondary)
                        .frame(width: disk.total > 0 ? proxy.size.width * CGFloat(Double(disk.used) / Double(disk.total)) : 0)
                }
            }
            .frame(height: 5)
            .animation(.easeOut(duration: 1.2), value: disk.free)
            HStack {
                Text("\(ByteText.string(disk.free)) free")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: Double(disk.free)))
                Spacer()
                Button { app.showingSettings = true } label: { Image(systemName: "gearshape") }
                    .buttonStyle(IconButtonStyle())
                    .help("Settings  ⌘,")
                    .accessibilityLabel("Settings")
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 2)
        .help(disk.name)
    }
}

private struct MissingEngineView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Palette.amberText)
            Text("Mole is missing from this copy of Burrow").font(.title3.weight(.semibold))
            Text("Download Burrow again, or build it with scripts/build-app.sh.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PasswordSheet: View {
    let request: AdminBroker.Request
    let onAnswer: (String?) -> Void
    @ViewState private var password = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "lock.fill")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Palette.amberText)
                .frame(width: 52, height: 52)
                .background(Circle().fill(Palette.amber.opacity(0.18)))
            Text("Administrator access")
                .font(.system(size: 16, weight: .semibold))
                .padding(.top, 14)
            Text(request.reason)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            SecureField("Password for \(NSFullUserName())", text: $password)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(allow)
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(Palette.hover, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(focused ? Palette.amber : Palette.hairline, lineWidth: 1)
                }
                .padding(.top, 18)
            Text(request.attempt > 1 ? "That password didn't work. Try again." : "Mole uses it once. Burrow never stores it.")
                .font(.caption)
                .foregroundStyle(request.attempt > 1 ? AnyShapeStyle(Palette.danger) : AnyShapeStyle(.tertiary))
                .padding(.top, 8)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { onAnswer(nil) }
                    .buttonStyle(QuietButtonStyle(height: 36))
                    .keyboardShortcut(.cancelAction)
                Button("Allow", action: allow)
                    .buttonStyle(AmberButtonStyle(height: 36))
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
            }
            .padding(.top, 18)
        }
        .padding(.horizontal, 24)
        .padding(.top, 26)
        .padding(.bottom, 20)
        .frame(width: 360)
        .onAppear { focused = true }
    }

    private func allow() {
        guard !password.isEmpty else { return }
        let answer = password
        password = ""
        onAnswer(answer)
    }
}
