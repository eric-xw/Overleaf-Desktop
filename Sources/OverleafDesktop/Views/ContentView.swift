import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var sync: AutoSyncManager
    @State private var showAddProject = false
    @State private var showSettings = false
    @State private var conflictProject: Project?
    @State private var didAutoPullOnLaunch = false

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
        .task {
            if !didAutoPullOnLaunch, store.autoPullOnLaunch {
                didAutoPullOnLaunch = true
                for project in store.projects {
                    await sync.pull(project, source: .auto)
                }
            }
        }
    }
}
