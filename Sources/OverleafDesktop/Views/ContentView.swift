import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var store: ProjectStore
    @State private var showAddProject = false
    @State private var showSettings = false
    @State private var didAutoPull = false

    var body: some View {
        ProjectsView(showAdd: $showAddProject, showSettings: $showSettings)
            .sheet(isPresented: $showAddProject) {
                AddProjectView().environmentObject(store)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView().environmentObject(store)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showAddProject)) { _ in
                showAddProject = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .showSettings)) { _ in
                showSettings = true
            }
            .task {
                if !didAutoPull, store.autoPullOnLaunch {
                    didAutoPull = true
                    await pullAll()
                }
            }
    }

    private func pullAll() async {
        for project in store.projects {
            await Task.detached(priority: .userInitiated) {
                _ = try? GitService.pull(at: project.localURL)
            }.value
            store.touchSync(project)
        }
    }
}
