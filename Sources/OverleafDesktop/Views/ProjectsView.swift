import SwiftUI
import AppKit

struct ProjectsView: View {
    @EnvironmentObject var store: ProjectStore
    @Binding var showAdd: Bool
    @Binding var showSettings: Bool
    @State private var statuses: [UUID: GitStatus] = [:]
    @State private var busy: Set<UUID> = []
    @State private var alertMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if store.projects.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(store.projects) { project in
                        ProjectRow(
                            project: project,
                            status: statuses[project.id],
                            isBusy: busy.contains(project.id),
                            onPull: { perform(project, action: .pull) },
                            onPush: { perform(project, action: .push) },
                            onCommitAndPush: { perform(project, action: .commitAndPush) },
                            onOpenFolder: { openInFinder(project) },
                            onOpenEditor: { openInEditor(project) },
                            onOpenWeb: { openWeb(project) },
                            onRemove: { remove(project) }
                        )
                    }
                }
                .listStyle(.inset)
            }
        }
        .task {
            await refreshAllStatuses()
        }
        .alert("Git Error", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private var toolbar: some View {
        HStack {
            Text("Projects").font(.title2.bold())
            Spacer()
            Button {
                Task { await refreshAllStatuses() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            Button {
                showSettings = true
            } label: {
                Label("Settings", systemImage: "gear")
            }
            Button {
                showAdd = true
            } label: {
                Label("Add Project", systemImage: "plus")
            }
            .keyboardShortcut("n", modifiers: [.command])
        }
        .padding(12)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No projects yet")
                .font(.headline)
            Text("Click **Add Project** and paste an Overleaf project URL to get started.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if KeychainService.loadToken() == nil {
                Text("First, open **Settings** and paste your Overleaf Git authentication token.")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(.top, 8)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private enum Action { case pull, push, commitAndPush }

    private func perform(_ project: Project, action: Action) {
        busy.insert(project.id)
        Task.detached(priority: .userInitiated) {
            do {
                switch action {
                case .pull:
                    _ = try GitService.pull(at: project.localURL)
                case .push:
                    _ = try GitService.push(at: project.localURL)
                case .commitAndPush:
                    _ = try GitService.commitAll(at: project.localURL, message: "Update from Overleaf Desktop")
                    _ = try GitService.push(at: project.localURL)
                }
                await MainActor.run {
                    store.touchSync(project)
                }
            } catch {
                await MainActor.run {
                    alertMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
            await MainActor.run {
                _ = busy.remove(project.id)
            }
            await refreshStatus(project)
        }
    }

    private func refreshAllStatuses() async {
        for project in store.projects {
            await refreshStatus(project)
        }
    }

    private func refreshStatus(_ project: Project) async {
        let status = await Task.detached(priority: .userInitiated) {
            GitService.status(at: project.localURL)
        }.value
        statuses[project.id] = status
    }

    private func openInFinder(_ project: Project) {
        NSWorkspace.shared.open(project.localURL)
    }

    private func openInEditor(_ project: Project) {
        // Try to open the main .tex (or the folder) in the user's default editor.
        let fm = FileManager.default
        if let contents = try? fm.contentsOfDirectory(atPath: project.localPath) {
            let candidates = ["main.tex", "Main.tex", "manuscript.tex"]
            for name in candidates {
                if contents.contains(name) {
                    let fileURL = project.localURL.appendingPathComponent(name)
                    NSWorkspace.shared.open(fileURL)
                    return
                }
            }
            if let firstTex = contents.first(where: { $0.hasSuffix(".tex") }) {
                let fileURL = project.localURL.appendingPathComponent(firstTex)
                NSWorkspace.shared.open(fileURL)
                return
            }
        }
        NSWorkspace.shared.open(project.localURL)
    }

    private func openWeb(_ project: Project) {
        if let url = URL(string: project.webURL) {
            NSWorkspace.shared.open(url)
        }
    }

    private func remove(_ project: Project) {
        let alert = NSAlert()
        alert.messageText = "Remove “\(project.name)” from this app?"
        alert.informativeText = "The local folder at \(project.localPath) will NOT be deleted. You can re-add the project later."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            store.remove(project)
            statuses.removeValue(forKey: project.id)
        }
    }
}

struct ProjectRow: View {
    let project: Project
    let status: GitStatus?
    let isBusy: Bool
    let onPull: () -> Void
    let onPush: () -> Void
    let onCommitAndPush: () -> Void
    let onOpenFolder: () -> Void
    let onOpenEditor: () -> Void
    let onOpenWeb: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(project.name)
                        .font(.headline)
                    statusBadge
                }
                Text(project.localPath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(lastSyncText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if isBusy {
                ProgressView().controlSize(.small)
            }
            actionMenu
        }
        .padding(.vertical, 6)
    }

    private var statusBadge: some View {
        Group {
            if let s = status, s.isRepo {
                HStack(spacing: 6) {
                    if s.dirty {
                        Label("uncommitted", systemImage: "pencil.circle.fill")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.orange)
                    } else {
                        Label("clean", systemImage: "checkmark.circle.fill")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.green)
                    }
                    if s.ahead > 0 {
                        Text("↑\(s.ahead)").foregroundStyle(.blue)
                    }
                    if s.behind > 0 {
                        Text("↓\(s.behind)").foregroundStyle(.purple)
                    }
                }
                .font(.caption)
            } else {
                Text("missing").font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var lastSyncText: String {
        guard let date = project.lastSync else { return "Not synced yet" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "Last sync " + formatter.localizedString(for: date, relativeTo: Date())
    }

    private var actionMenu: some View {
        HStack(spacing: 8) {
            Button(action: onPull) {
                Label("Pull", systemImage: "arrow.down")
            }
            .disabled(isBusy)
            Button(action: onCommitAndPush) {
                Label("Push", systemImage: "arrow.up")
            }
            .disabled(isBusy)
            Menu {
                Button("Open Folder", action: onOpenFolder)
                Button("Open Main .tex", action: onOpenEditor)
                Button("Open in Browser", action: onOpenWeb)
                Divider()
                Button("Push (no commit)", action: onPush)
                Divider()
                Button("Remove…", role: .destructive, action: onRemove)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
