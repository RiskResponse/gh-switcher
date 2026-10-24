import GHSwitchCore
import SwiftUI

struct ManageView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("Accounts") {
                ForEach(model.accounts) { account in
                    AccountEditor(account: account)
                }
                HStack {
                    Button("Add Account…") { model.addAccount() }
                    Button("Refresh Names & Avatars") { model.refreshAvatars() }
                }
            }

            Section("Behavior") {
                Toggle("Set global git user.name and user.email when switching", isOn: binding(\.updateGitIdentity))
                Toggle("Show active account in the menu bar", isOn: binding(\.showLoginInMenuBar))
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
            }

            Section("Claude") {
                LabeledContent("Claude Code") {
                    HStack {
                        InstallStatus(installed: model.claudeInstalled)
                        Button(model.claudeInstalled == true ? "Reinstall" : "Install") { model.installClaude() }
                    }
                }
                LabeledContent("Claude app (chat and Cowork)") {
                    HStack {
                        InstallStatus(installed: model.desktopInstalled)
                        Button(model.desktopInstalled == true ? "Reinstall" : "Install") { model.installDesktop() }
                    }
                }
                Text("Once installed, ask Claude things like “switch to my acme GitHub account” or “which GitHub account am I using?” Restart the Claude app after installing.")
                    .font(.callout).foregroundStyle(.secondary)
                if let cli = model.cliPath {
                    Text("CLI: \(cli)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .frame(minHeight: 420)
        .onAppear {
            model.refresh()
            model.refreshClaudeStatus()
        }
    }

    private func binding(_ keyPath: WritableKeyPath<Config, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.config[keyPath: keyPath] },
            set: { model.config[keyPath: keyPath] = $0; model.saveConfig() }
        )
    }
}

private struct InstallStatus: View {
    let installed: Bool?

    var body: some View {
        switch installed {
        case .some(true): Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .some(false): Text("Not installed").foregroundStyle(.secondary)
        case .none: ProgressView().controlSize(.small)
        }
    }
}

private struct AccountEditor: View {
    @EnvironmentObject private var model: AppModel
    let account: AccountInfo

    @State private var label = ""
    @State private var gitName = ""
    @State private var gitEmail = ""
    @State private var confirmingRemove = false

    var body: some View {
        DisclosureGroup {
            TextField("Label", text: $label, prompt: Text("e.g. Work, Personal"))
            TextField("Git name", text: $gitName, prompt: Text(account.displayName ?? account.login))
            TextField("Git email", text: $gitEmail, prompt: Text(defaultEmail))
            HStack {
                Button("Remove…", role: .destructive) { confirmingRemove = true }
                Spacer()
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
            .confirmationDialog("Remove \(account.login)?", isPresented: $confirmingRemove) {
                Button("Remove", role: .destructive) { model.remove(account) }
            } message: {
                Text("Logs \(account.login) out of the gh CLI on this Mac. The token isn’t revoked on \(account.host); run `gh auth login` to add it back."
                    + (account.active ? " gh and the global git identity will switch to another account on \(account.host)." : ""))
            }
        } label: {
            HStack(spacing: 10) {
                Avatar(url: account.avatarURL, login: account.login, size: 24)
                Text(account.title)
                if account.label != nil { Text(account.login).foregroundStyle(.secondary) }
                Spacer()
                if account.active {
                    Text("Active").font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.green.opacity(0.2)))
                } else {
                    Button("Switch") { model.switchTo(account) }.controlSize(.small)
                }
            }
        }
        .onAppear(perform: load)
        .onSubmit(save)
    }

    private var defaultEmail: String {
        AccountInfo(account: GHAccount(host: account.host, login: account.login, active: false),
                    profile: AccountProfile(userID: model.config.profiles[account.key]?.userID)).gitEmail ?? "you@example.com"
    }

    private func load() {
        let profile = model.config.profiles[account.key]
        label = profile?.label ?? ""
        gitName = profile?.gitName ?? ""
        gitEmail = profile?.gitEmail ?? ""
    }

    private func save() {
        func cleaned(_ value: String) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        model.updateProfile(account.key) {
            $0.label = cleaned(label)
            $0.gitName = cleaned(gitName)
            $0.gitEmail = cleaned(gitEmail)
        }
    }
}
