import AppKit
import SwiftUI

@main
struct BurrowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ViewState private var model = AppModel()

    var body: some Scene {
        Window("Burrow", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Go") {
                ForEach(Array(Module.allCases.enumerated()), id: \.element) { index, module in
                    Button(module.title) { model.selection = module }
                        .keyboardShortcut(index < 9 ? KeyEquivalent(Character("\(index + 1)")) : "0", modifiers: .command)
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
