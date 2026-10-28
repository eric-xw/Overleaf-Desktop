import SwiftUI
import AppKit

@main
struct OverleafDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: ProjectStore
    @StateObject private var sync: AutoSyncManager

    init() {
        let s = ProjectStore()
        _store = StateObject(wrappedValue: s)
        _sync = StateObject(wrappedValue: AutoSyncManager(store: s))
    }

    var body: some Scene {
        WindowGroup("Overleaf Desktop", id: "main") {
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

        // Only inserted in menu bar mode. The binding is deliberately one-way:
        // SwiftUI writes the status item's system-managed visibility back into
        // `isInserted`, which would switch the setting on by itself (and, via
        // @Published, re-evaluate this body in a loop until the stack overflows).
        MenuBarExtra(isInserted: .constant(store.menuBarOnly)) {
            MenuBarMenu()
        } label: {
            MenuBarIcon()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Set before launch finishes so the Dock icon doesn't flash in menu bar mode.
        // (Not via MenuBarMode.apply: activating here would steal focus with no window.)
        if UserDefaults.standard.bool(forKey: "menuBarOnly") {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar mode starts in the background. SwiftUI has created the launch
        // window by now but not yet sized or shown it, so closing it here avoids a flash.
        guard UserDefaults.standard.bool(forKey: "menuBarOnly") else { return }
        for window in NSApp.windows where window.canBecomeMain {
            window.close()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Implementing this replaces SwiftUI's default reopen, which also never covered
        // menu bar (accessory) apps. Clicking the Dock icon, or launching the app again
        // from Finder or Spotlight when the menu bar icon is hidden behind the notch,
        // brings the window back.
        if !flag { MainWindow.show() }
        return false
    }
}

enum MenuBarMode {
    /// `.accessory` hides the Dock icon and app menu; `.regular` is a normal app.
    static func apply(_ menuBarOnly: Bool) {
        let policy: NSApplication.ActivationPolicy = menuBarOnly ? .accessory : .regular
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        // Changing policy deactivates the app; bring the window back to the front.
        NSApp.activate()
    }
}

/// Shows the main window from outside its view hierarchy (menu bar menu, reopen).
@MainActor
enum MainWindow {
    /// Captured from the main window and the menu bar icon (the one view that's
    /// alive in menu bar mode while no window is).
    static var openWindow: OpenWindowAction?

    /// Focus the existing window if there is one; `openWindow` on a WindowGroup
    /// would always create a second window.
    static func show(openingSettings: Bool = false) {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && ($0.isVisible || $0.isMiniaturized) }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            if openingSettings {
                NotificationCenter.default.post(name: .showSettings, object: nil)
            }
        } else {
            // A new window isn't listening for .showSettings yet; hand it the request.
            ContentView.showSettingsOnAppear = openingSettings
            openWindow?(id: "main")
        }
    }
}

private struct MenuBarIcon: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: "leaf")
            .accessibilityLabel("Overleaf Desktop")
            .onAppear { MainWindow.openWindow = openWindow }
    }
}

private struct MenuBarMenu: View {
    var body: some View {
        Button("Open Overleaf") { MainWindow.show() }
        Button("Settings…") { MainWindow.show(openingSettings: true) }
        Divider()
        Button("Quit Overleaf") { NSApp.terminate(nil) }
    }
}

extension Notification.Name {
    static let showAddProject = Notification.Name("showAddProject")
    static let showSettings = Notification.Name("showSettings")
}
