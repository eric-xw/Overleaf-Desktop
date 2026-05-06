import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var store: ProjectStore
    @Environment(\.dismiss) private var dismiss

    @State private var token: String = ""
    @State private var hasExistingToken: Bool = KeychainService.loadToken() != nil
    @State private var savedMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings").font(.title2.bold())

            GroupBox("Overleaf Git authentication") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Generate a token at:")
                        .font(.caption)
                    Link("overleaf.com → Account Settings → Git authentication tokens",
                         destination: URL(string: "https://www.overleaf.com/user/settings")!)
                        .font(.caption)

                    SecureField(hasExistingToken ? "•••••••• (saved)" : "olp_…", text: $token)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Button("Save Token") { save() }
                            .disabled(token.isEmpty)
                        if hasExistingToken {
                            Button("Remove Saved Token") { removeToken() }
                                .foregroundStyle(.red)
                        }
                        if let savedMessage {
                            Text(savedMessage).font(.caption).foregroundStyle(.green)
                        }
                    }
                }
                .padding(8)
            }

            GroupBox("Sync") {
                Toggle("Pull all projects automatically on launch", isOn: $store.autoPullOnLaunch)
                    .padding(8)
            }

            Spacer()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 360)
    }

    private func save() {
        do {
            try KeychainService.saveToken(token.trimmingCharacters(in: .whitespacesAndNewlines))
            hasExistingToken = true
            token = ""
            savedMessage = "Saved to Keychain."
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { savedMessage = nil }
        } catch {
            savedMessage = "Failed: \(error.localizedDescription)"
        }
    }

    private func removeToken() {
        KeychainService.deleteToken()
        hasExistingToken = false
        savedMessage = "Removed."
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { savedMessage = nil }
    }
}
