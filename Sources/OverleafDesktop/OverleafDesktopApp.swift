import SwiftUI

@main
struct OverleafDesktopApp: App {
    @StateObject private var store: ProjectStore
    @StateObject private var sync: AutoSyncManager

    init() {
        let s = ProjectStore()
        _store = StateObject(wrappedValue: s)
        _sync = StateObject(wrappedValue: AutoSyncManager(store: s))
    }

    var body: some Scene {
        WindowGroup("Overleaf Desktop") {
            ContentView()
                .environmentObject(store)
                .environmentObject(sync)
                .frame(minWidth: 760, minHeight: 480)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Project…") {
                    NotificationCenter.default.post(name: .showAddProject, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
            CommandGroup(after: .appSettings) {
                Button("Settings…") {
                    NotificationCenter.default.post(name: .showSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
        }
    }
}

extension Notification.Name {
    static let showAddProject = Notification.Name("showAddProject")
    static let showSettings = Notification.Name("showSettings")
}
