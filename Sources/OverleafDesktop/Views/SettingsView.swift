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
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Pull all projects on launch", isOn: $store.autoPullOnLaunch)

                    Toggle("Pull automatically in the background", isOn: $store.autoPullOnInterval)

                    if store.autoPullOnInterval {
                        HStack {
                            Text("Every")
                                .font(.callout)
                            Stepper(value: $store.autoPullIntervalSeconds, in: 10...600, step: 5) {
                                Text("\(Int(store.autoPullIntervalSeconds)) seconds")
                                    .font(.callout)
                                    .frame(minWidth: 110, alignment: .leading)
                            }
                            Spacer()
                        }
                        .padding(.leading, 22)
                    }

                    Toggle("Push automatically a few seconds after each save", isOn: $store.autoPushOnSave)

                    if store.autoPushOnSave || store.autoPullOnInterval {
                        Text("With both toggles on, your local edits and your coauthors' web edits stay in sync within ~30 seconds. Conflicts will appear inline on each project — open the resolve sheet from the orange badge.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                }
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
        .frame(width: 540, height: 460)
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
