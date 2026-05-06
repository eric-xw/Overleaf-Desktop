import SwiftUI
import AppKit

struct ConflictResolutionView: View {
    @EnvironmentObject var sync: AutoSyncManager
    @Environment(\.dismiss) private var dismiss

    let project: Project

    private var state: SyncState { sync.states[project.id] ?? SyncState() }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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

            GroupBox("Conflicted files") {
                if state.conflictedFiles.isEmpty {
                    Text("No unresolved files. You can mark this resolved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(8)
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

            HStack {
                Button("Open Folder") { openFolder() }
                Spacer()
                Button("Abort Pull", role: .destructive) {
                    Task {
                        await sync.abortRebase(project)
                        dismiss()
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
        .padding(20)
        .frame(width: 560)
    }

    private func openFolder() {
        NSWorkspace.shared.open(project.localURL)
    }

    private func openFile(_ relative: String) {
        let fileURL = project.localURL.appendingPathComponent(relative)
        NSWorkspace.shared.open(fileURL)
    }
}
