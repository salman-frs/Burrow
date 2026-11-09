import AppKit
import BurrowCore
import SwiftUI

struct SettingsSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @ViewState private var adding = false
    @ViewState private var newPattern = ""
    @ViewState private var problem: String?

    var body: some View {
        let model = app.settings
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings").font(.system(size: 16, weight: .semibold))
            Text("Keep lists and project folders are shared with the Mole command line.")
                .foregroundStyle(.secondary)
                .padding(.top, 4)
                .padding(.bottom, 20)

            Group(label: "Palette", symbol: "paintpalette") {
                PalettePicker()
            }

            Group(label: "Always keep", symbol: "shield.lefthalf.filled") {
                ScrollView {
                    FlowLayout(spacing: 6) {
                        ForEach(model.protectedPaths, id: \.self) { pattern in
                            Chip(text: pattern == "FINDER_METADATA" ? "Finder metadata (.DS_Store)" : pattern) {
                                do {
                                    try model.removeProtectedPath(pattern)
                                    problem = nil
                                } catch {
                                    problem = error.localizedDescription
                                }
                            }
                        }
                        if adding {
                            PatternField(text: $newPattern, add: addPattern, choose: choosePattern) { adding = false }
                        } else {
                            AddChip { adding = true }
                        }
                    }
                }
                .frame(maxHeight: 150)
                .scrollBounceBehavior(.basedOnSize)
                if let problem {
                    Text(problem).font(.caption).foregroundStyle(Palette.danger).padding(.top, 6)
                }
                if !model.usingMoleDefaults {
                    Button("Restore Mole's defaults") { model.restoreMoleDefaults() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.accentText)
                        .padding(.top, 8)
                }
            }

            Group(label: "Project folders", symbol: "folder") {
                FlowLayout(spacing: 6) {
                    if model.projectFolders.isEmpty {
                        Text("~/Projects, ~/Code, ~/Developer")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .help("Mole's usual folders. Adding one replaces this list.")
                    }
                    ForEach(model.projectFolders, id: \.self) { folder in
                        Chip(text: folder) { model.removeProjectFolder(folder) }
                    }
                    AddChip { chooseFolder { model.addProjectFolder($0) } }
                }
            }

            HStack {
                Label {
                    Text("Use Touch ID for admin tasks")
                } icon: {
                    Image(systemName: "touchid").foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Use Touch ID for admin tasks", isOn: Binding(
                    get: { model.touchID == .enabled },
                    set: { enabled in Task { await model.setTouchID(enabled: enabled) } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Palette.accent)
                .disabled(model.touchID == .unknown || model.touchIDBusy)
            }
            .padding(.top, 14)
            .padding(.bottom, 4)
            .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
            .help("macOS shows its own Touch ID prompt instead of Burrow's password sheet. This changes how sudo works everywhere on this Mac.")

            if let failure = model.failure {
                Text(failure).font(.caption).foregroundStyle(Palette.danger).padding(.top, 8)
            }

            HStack(alignment: .center) {
                Link(destination: URL(string: "https://github.com/tw93/Mole")!) {
                    Text("Burrow \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") · Mole \(app.moleVersion ?? "")")
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .help("Free software under the GNU GPL v3. Every scan and cleanup runs through Mole by tw93.")
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(AccentButtonStyle(height: 36))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 18)
        }
        .padding(.horizontal, 24)
        .padding(.top, 26)
        .padding(.bottom, 20)
        .frame(width: 470)
        .task {
            model.reload()
            await model.refreshTouchID()
        }
    }

    private func addPattern() {
        do {
            try app.settings.addProtectedPath(newPattern.trimmingCharacters(in: .whitespaces))
            newPattern = ""
            problem = nil
            adding = false
        } catch {
            problem = error.localizedDescription
        }
    }

    private func choosePattern() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Keep"
        if panel.runModal() == .OK, let url = panel.url {
            newPattern = Paths.abbreviatingHome(url.path)
            addPattern()
        }
    }

    private func chooseFolder(then use: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add"
        if panel.runModal() == .OK, let url = panel.url { use(url.path) }
    }
}

private struct Group<Content: View>: View {
    let label: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(label, systemImage: symbol)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(.bottom, 18)
    }
}

private struct PalettePicker: View {
    @AppStorage(AccentPalette.storageKey) private var palette = AccentPalette.moonlight

    var body: some View {
        HStack(spacing: 6) {
            ForEach(AccentPalette.allCases) { choice in
                let picked = palette == choice
                Button { palette = choice } label: {
                    HStack(spacing: 7) {
                        Circle().fill(choice.accent.fill.color).frame(width: 12, height: 12)
                        Text(choice.name).foregroundStyle(picked ? .primary : .secondary)
                    }
                    .font(.system(size: 12.5, weight: picked ? .semibold : .regular))
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Capsule().fill(picked ? Palette.selected : Palette.hover))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .accessibilityAddTraits(picked ? .isSelected : [])
            }
        }
    }
}

private struct Chip: View {
    let text: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(text).lineLimit(1).truncationMode(.middle)
            Button(action: remove) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(IconButtonStyle(size: 20))
                .accessibilityLabel("Remove \(text)")
        }
        .font(.system(size: 12.5))
        .padding(.leading, 12)
        .padding(.trailing, 5)
        .frame(height: 30)
        .frame(maxWidth: 400)
        .background(Capsule().fill(Palette.hover))
        .help(text)
    }
}

private struct AddChip: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Add", systemImage: "plus")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Capsule().fill(Palette.hover))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct PatternField: View {
    @Binding var text: String
    let add: () -> Void
    let choose: () -> Void
    let cancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            TextField("~/path or pattern", text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(add)
                .onExitCommand(perform: cancel)
                .frame(width: 220)
            Button(action: choose) { Image(systemName: "folder") }
                .buttonStyle(IconButtonStyle(size: 22))
                .help("Choose a file or folder")
        }
        .font(.system(size: 12.5))
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(height: 30)
        .background(Capsule().fill(Palette.hover))
        .overlay(Capsule().strokeBorder(Palette.accent, lineWidth: 1))
        .onAppear { focused = true }
    }
}
