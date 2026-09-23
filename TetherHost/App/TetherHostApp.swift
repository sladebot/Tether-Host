import SwiftUI

@main
struct TetherHostApp: App {
    @StateObject private var model = AppViewModel(provider: LiveHostStatusProvider())

    var body: some Scene {
        WindowGroup("Tether Host for Mac") {
            HostRootView()
                .environmentObject(model)
                .frame(minWidth: 680, minHeight: 620)
        }
        .defaultSize(width: 840, height: 700)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh Status") { Task { await model.refresh() } }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
        Settings {
            HostSettingsView()
                .environmentObject(model)
                .frame(width: 520, height: 260)
        }
    }
}
