import SwiftUI

@main
struct BergamotaApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Bergamota") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1100, minHeight: 640)
                .task { model.start() }
        }
        .defaultSize(width: 1180, height: 760)
        Window("Control Plane", id: "control-plane") {
            ControlPlaneView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 520)
                .task { model.start() }
        }
        .defaultSize(width: 1500, height: 950)
        .commands { ControlPlaneCommands() }
        Settings {
            SettingsView().environment(model).frame(width: 560)
        }
    }
}

struct ControlPlaneCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button("Control Plane") { openWindow(id: "control-plane") }.keyboardShortcut("c", modifiers: [.command, .shift])
        }
    }
}
