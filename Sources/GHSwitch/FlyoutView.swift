import GHSwitchCore
import SwiftUI

struct FlyoutView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("GitHub Accounts").font(.headline)
                Spacer()
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh")
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            VStack(spacing: 2) {
                ForEach(Array(model.accounts.enumerated()), id: \.element.id) { index, account in
                    AccountRow(account: account, index: index, isSwitching: model.switching == account.key) {
                        model.switchTo(account)
                    }
                }
            }
            .padding(.horizontal, 6)

            if model.accounts.isEmpty && model.errorMessage == nil {
                Text("No accounts. Use Add Account… to log in with gh.")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(12)
            }

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
            }

            if let git = model.gitIdentity {
                Label(git, systemImage: "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .help("Global git identity")
            }

            Divider().padding(.vertical, 8)

            VStack(spacing: 2) {
                MenuButton(title: "Manage Accounts…", systemImage: "gearshape", shortcut: ",") {
                    NSApp.activate()
                    openWindow(id: "manage")
                }
                MenuButton(title: "Add Account…", systemImage: "plus.circle") { model.addAccount() }
                MenuButton(title: "Quit GH Switch", systemImage: "power", shortcut: "q") { NSApp.terminate(nil) }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 8)
        }
        .frame(width: 320)
        .onAppear { model.refresh() }
    }
}

private struct AccountRow: View {
    let account: AccountInfo
    let index: Int
    let isSwitching: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Avatar(url: account.avatarURL, login: account.login, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.title).fontWeight(account.active ? .semibold : .regular)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if isSwitching {
                    ProgressView().controlSize(.small)
                } else if account.active {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else if index < 9 {
                    Text("⌘\(index + 1)").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.08) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .keyboardShortcut(index < 9 ? KeyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command) : nil)
        .help(account.active ? "Active account" : "Switch to \(account.login)")
    }

    private var subtitle: String {
        var parts: [String] = []
        if account.label != nil { parts.append(account.login) }
        if account.host != "github.com" { parts.append(account.host) }
        parts.append(account.gitEmail ?? account.gitName)
        return parts.joined(separator: " · ")
    }
}

private struct MenuButton: View {
    let title: String
    let systemImage: String
    var shortcut: KeyEquivalent?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.08) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .keyboardShortcut(shortcut.map { KeyboardShortcut($0, modifiers: .command) })
    }
}

struct Avatar: View {
    let url: String?
    let login: String
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url.flatMap(URL.init(string:))) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.25))
                Text(login.prefix(1).uppercased()).font(.system(size: size * 0.45, weight: .semibold))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
