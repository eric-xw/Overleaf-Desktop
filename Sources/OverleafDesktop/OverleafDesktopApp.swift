import SwiftUI

@main
struct OverleafDesktopApp: App {
    @StateObject private var store = ProjectStore()

    var body: some Scene {
        WindowGroup("Overleaf Desktop") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 720, minHeight: 460)
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
