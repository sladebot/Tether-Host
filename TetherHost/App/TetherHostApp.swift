import SwiftUI

@main
struct TetherHostApp: App {
    @StateObject private var model = AppViewModel(provider: LiveHostStatusProvider())

    var body: some Scene {
        WindowGroup("Tether Host for Mac") {
            HostRootView()
                .environmentObject(model)
                .frame(minWidth: 1040, minHeight: 700)
        }
        .defaultSize(width: 1320, height: 820)
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
