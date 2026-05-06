import SwiftUI
import AppKit

struct ConflictResolutionView: View {
    @EnvironmentObject var sync: AutoSyncManager
    @Environment(\.dismiss) private var dismiss

    let project: Project

    private var state: SyncState { sync.states[project.id] ?? SyncState() }

    /// True if `.git/rebase-merge` etc still exist on disk.
    @State private var rebaseStillRunning: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if !state.inConflict && !rebaseStillRunning {
                // The badge was stale — disk is clean. One-click recovery.
                alreadyResolvedView
            } else {
                conflictBody
            }

            if let err = state.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.07))
                    .cornerRadius(6)
            }

            buttonRow
        }
        .padding(20)
        .frame(width: 580)
        .task {
            // Always reconcile state with disk when the sheet opens.
            await sync.reconcileConflictState(project)
            rebaseStillRunning = GitService.hasInProgressRebaseOrMerge(at: project.localURL)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Sync conflict in “\(project.name)”")
                    .font(.title3.bold())
                Text("Overleaf and your local copy both changed the same lines.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var alreadyResolvedView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Looks like this was already resolved.")
                    .font(.headline)
            }
            Text("Git reports no rebase in progress and no unmerged files. The badge was likely left over from an external resolution. Click **Clear Status** to remove it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.08))
        .cornerRadius(6)
    }

    private var conflictBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("Conflicted files") {
                if state.conflictedFiles.isEmpty {
                    Text("Git reports no unmerged files, but a rebase is still in progress. You can probably **Mark Resolved & Continue** to finish it, or **Abort Pull** to back out.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(state.conflictedFiles, id: \.self) { file in
                            HStack {
                                Text(file)
                                    .font(.system(.body, design: .monospaced))
                                Spacer()
                                Button("Open") { openFile(file) }
                                    .controlSize(.small)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(8)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("How to resolve").font(.headline)
                Text("""
                1. Click **Open** next to each file (or **Open Folder** below) to edit it.
                2. Look for `<<<<<<<`, `=======`, `>>>>>>>` markers. Above `=======` is Overleaf's version, below is your local version.
                3. Edit the file to the version you want, remove the markers, and save.
                4. When all files are resolved, click **Mark Resolved & Continue**.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var buttonRow: some View {
        if !state.inConflict && !rebaseStillRunning {
            HStack {
                Button("Open Folder") { openFolder() }
                Spacer()
                Button("Close") { dismiss() }
                Button("Clear Status") {
                    sync.clearConflict(project)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        } else {
            HStack {
                Button("Open Folder") { openFolder() }
                Menu {
                    Button("Recheck Status") {
                        Task {
                            await sync.reconcileConflictState(project)
                            rebaseStillRunning = GitService.hasInProgressRebaseOrMerge(at: project.localURL)
                        }
                    }
                    Button("Force Clear (disk is fine, badge is stuck)") {
                        sync.clearConflict(project)
                        dismiss()
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 70)
                Spacer()
                Button("Abort Pull", role: .destructive) {
                    Task {
                        await sync.abortRebase(project)
                        if !sync.states[project.id, default: SyncState()].inConflict {
                            dismiss()
                        }
                    }
                }
                Button("Mark Resolved & Continue") {
                    Task {
                        await sync.continueRebase(project)
                        if !sync.states[project.id, default: SyncState()].inConflict {
                            dismiss()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(state.busy)
            }
        }
    }

    private func openFolder() {
        NSWorkspace.shared.open(project.localURL)
    }

    private func openFile(_ relative: String) {
        let fileURL = project.localURL.appendingPathComponent(relative)
        NSWorkspace.shared.open(fileURL)
    }
}
