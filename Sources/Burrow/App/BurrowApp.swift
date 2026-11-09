import AppKit
import SwiftUI

@main
struct BurrowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ViewState private var model = AppModel()
    @AppStorage(AccentPalette.storageKey) private var palette = AccentPalette.moonlight

    var body: some Scene {
        Window("Burrow", id: "main") {
            RootView()
                .environment(model)
                .environment(\.accent, palette.accent)
                .frame(minWidth: 980, minHeight: 640)
                .background(WindowChrome())
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.showingSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
                    .disabled(model.runner == nil)
            }
            CommandMenu("Go") {
                ForEach(Array(Section.allCases.enumerated()), id: \.element) { index, section in
                    Button(section.title) { model.section = section }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
