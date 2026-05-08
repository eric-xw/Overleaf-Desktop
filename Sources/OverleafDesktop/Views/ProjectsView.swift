import SwiftUI
import AppKit

struct ProjectsView: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var sync: AutoSyncManager
    @Binding var showAdd: Bool
    @Binding var showSettings: Bool
    @Binding var conflictProject: Project?

    @State private var statuses: [UUID: GitStatus] = [:]
    @State private var alertMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            globalStatusBanner
            Divider()
            if store.projects.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(store.projects) { project in
                        ProjectRow(
                            project: project,
                            status: statuses[project.id],
                            syncState: sync.states[project.id] ?? SyncState(),
                            onPull: { Task { await sync.pull(project); await refreshStatus(project) } },
                            onPush: { Task { await sync.push(project); await refreshStatus(project) } },
                            onOpenConflict: { conflictProject = project },
                            onOpenFolder: { openInFinder(project) },
                            onOpenEditor: { openInEditor(project) },
                            onOpenWeb: { openWeb(project) },
                            onRecheck: { Task { await sync.reconcileConflictState(project); await refreshStatus(project) } },
                            onForceClear: { sync.clearConflict(project) },
                            onClearError: { sync.clearLastError(project) },
                            onRemove: { remove(project) }
                        )
                    }
                }
                .listStyle(.inset)
            }
        }
        .task {
            await refreshAllStatuses()
            for project in store.projects {
                sync.refreshConflictState(project)
            }
        }
        .alert("Git Error", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
        .onChange(of: sync.states) { _, _ in
            // When sync state changes, refresh git status to reflect ahead/behind/dirty.
            Task { await refreshAllStatuses() }
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

    @ViewBuilder
    private var globalStatusBanner: some View {
        if store.autoPullOnInterval || store.autoPushOnSave {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
                Group {
                    if store.autoPullOnInterval && store.autoPushOnSave {
                        Text("Auto-sync on. Pulls every \(Int(store.autoPullIntervalSeconds))s; pushes ~3s after each save.")
                    } else if store.autoPullOnInterval {
                        Text("Auto-pull on. Pulling every \(Int(store.autoPullIntervalSeconds))s.")
                    } else {
                        Text("Auto-push on. Pushing ~3s after each save.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.06))
        }
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
        let fm = FileManager.default
        if let contents = try? fm.contentsOfDirectory(atPath: project.localPath) {
            let candidates = ["main.tex", "Main.tex", "manuscript.tex"]
            for name in candidates where contents.contains(name) {
                NSWorkspace.shared.open(project.localURL.appendingPathComponent(name))
                return
            }
            if let firstTex = contents.first(where: { $0.hasSuffix(".tex") }) {
                NSWorkspace.shared.open(project.localURL.appendingPathComponent(firstTex))
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
    let syncState: SyncState
    let onPull: () -> Void
    let onPush: () -> Void
    let onOpenConflict: () -> Void
    let onOpenFolder: () -> Void
    let onOpenEditor: () -> Void
    let onOpenWeb: () -> Void
    let onRecheck: () -> Void
    let onForceClear: () -> Void
    let onClearError: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(project.name).font(.headline)
                        statusBadge
                        if syncState.inConflict {
                            conflictBadge
                        }
                    }
                    Text(project.localPath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(lastEventText)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if syncState.busy {
                    ProgressView().controlSize(.small)
                }
                actionMenu
            }
            if let err = syncState.lastError, !syncState.inConflict {
                errorBanner(err)
            }
        }
        .padding(.vertical, 6)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                onClearError()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .padding(8)
        .background(Color.red.opacity(0.07))
        .cornerRadius(6)
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
                    if s.ahead > 0 { Text("↑\(s.ahead)").foregroundStyle(.blue) }
                    if s.behind > 0 { Text("↓\(s.behind)").foregroundStyle(.purple) }
                }
                .font(.caption)
            } else {
                Text("missing").font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var conflictBadge: some View {
        Button(action: onOpenConflict) {
            Label("conflict", systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption.bold())
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)
        .controlSize(.mini)
    }

    private var lastEventText: String {
        if let event = syncState.lastEvent, let date = syncState.lastEventAt {
            let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
            return "\(event) \(f.localizedString(for: date, relativeTo: Date()))"
        }
        if let date = project.lastSync {
            let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
            return "Last sync " + f.localizedString(for: date, relativeTo: Date())
        }
        return "Not synced yet"
    }

    private var actionMenu: some View {
        HStack(spacing: 8) {
            Button(action: onPull) {
                Label("Pull", systemImage: "arrow.down")
            }
            .disabled(syncState.busy || syncState.inConflict)

            Button(action: onPush) {
                Label("Push", systemImage: "arrow.up")
            }
            .disabled(syncState.busy || syncState.inConflict)

            Menu {
                Button("Open Folder", action: onOpenFolder)
                Button("Open Main .tex", action: onOpenEditor)
                Button("Open in Browser", action: onOpenWeb)
                Divider()
                Button("Recheck Status", action: onRecheck)
                if syncState.inConflict {
                    Button("Resolve Conflict…", action: onOpenConflict)
                    Button("Force Clear Conflict Badge", action: onForceClear)
                }
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
