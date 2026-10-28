import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var sync: AutoSyncManager
    @Environment(\.openWindow) private var openWindow
    @State private var showAddProject = false
    @State private var showSettings = false
    @State private var conflictProject: Project?
    /// Set by the menu bar's "Settings…" when it has to open a new window.
    static var showSettingsOnAppear = false

    var body: some View {
        ProjectsView(
            showAdd: $showAddProject,
            showSettings: $showSettings,
            conflictProject: $conflictProject
        )
        .sheet(isPresented: $showAddProject) {
            AddProjectView().environmentObject(store)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(store)
        }
        .sheet(item: $conflictProject) { project in
            ConflictResolutionView(project: project).environmentObject(sync)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAddProject)) { _ in
            showAddProject = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showSettings)) { _ in
            showSettings = true
        }
        .onAppear {
            MainWindow.openWindow = openWindow
            if Self.showSettingsOnAppear {
                Self.showSettingsOnAppear = false
                showSettings = true
            }
        }
    }
}
