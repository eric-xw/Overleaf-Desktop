import SwiftUI
import AppKit

struct AddProjectView: View {
    @EnvironmentObject var store: ProjectStore
    @Environment(\.dismiss) private var dismiss

    @State private var urlText: String = ""
    @State private var name: String = ""
    @State private var parentDir: String = AddProjectView.defaultParent()
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Overleaf Project").font(.title2.bold())

            VStack(alignment: .leading, spacing: 6) {
                Text("Overleaf project URL or ID").font(.caption).foregroundStyle(.secondary)
                TextField("https://www.overleaf.com/project/65abc…", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: urlText) { _, newValue in
                        if name.isEmpty, let id = OverleafURLParser.extractProjectID(from: newValue) {
                            name = "overleaf-\(id.prefix(8))"
                        }
                    }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Local folder name").font(.caption).foregroundStyle(.secondary)
                TextField("my-paper", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Clone into").font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("", text: $parentDir)
                        .textFieldStyle(.roundedBorder)
                        .disabled(true)
                    Button("Choose…") { chooseDirectory() }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(busy ? "Cloning…" : "Clone") {
                    clone()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(busy || urlText.isEmpty || name.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private static func defaultParent() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Overleaf", isDirectory: true).path
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            parentDir = url.path
        }
    }

    private func clone() {
        errorMessage = nil
        guard let projectID = OverleafURLParser.extractProjectID(from: urlText) else {
            errorMessage = "Couldn't extract a project ID from that URL. Expected something like https://www.overleaf.com/project/<24-char id>."
            return
        }
        guard KeychainService.loadToken() != nil else {
            errorMessage = "No Overleaf Git token saved. Open Settings to add one."
            return
        }

        let parent = URL(fileURLWithPath: parentDir)
        let folderName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let remote = "https://git@git.overleaf.com/\(projectID)"

        busy = true
        Task.detached(priority: .userInitiated) {
            do {
                let cloned = try GitService.clone(remote: remote, into: parent, name: folderName)
                let project = Project(
                    overleafID: projectID,
                    name: folderName,
                    localPath: cloned.path,
                    lastSync: Date()
                )
                await MainActor.run {
                    store.add(project)
                    busy = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    busy = false
                    errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }
}
