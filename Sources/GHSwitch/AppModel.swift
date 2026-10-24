import AppKit
import Foundation
import GHSwitchCore
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var accounts: [AccountInfo] = []
    @Published private(set) var gitIdentity: String?
    @Published private(set) var switching: String?
    @Published private(set) var claudeInstalled: Bool?
    @Published private(set) var desktopInstalled: Bool?
    @Published var config: Config
    @Published var errorMessage: String?

    private let store = ConfigStore()
    private var watcher: DirectoryWatcher?
    private var timer: Timer?

    var active: AccountInfo? { accounts.first(where: \.active) }

    var menuBarTitle: String? {
        guard config.showLoginInMenuBar else { return nil }
        return active?.title
    }

    /// The CLI ships inside the app bundle next to the app binary.
    var cliPath: String? {
        Bundle.main.url(forAuxiliaryExecutable: "gh-switch")?.path
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                errorMessage = "Launch at login: \(error.localizedDescription)"
            }
            objectWillChange.send()
        }
    }

    init() {
        do {
            config = try store.load()
        } catch {
            config = Config()
            errorMessage = error.localizedDescription
        }
        // gh rewrites hosts.yml on `gh auth switch`, including switches made from the CLI or Claude.
        watcher = DirectoryWatcher(url: GHClient.configDirectory) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
        refreshClaudeStatus()
    }

    func refresh() {
        Task {
            do {
                let (accounts, git) = try await Task.detached {
                    let switcher = try Switcher()
                    let accounts = try switcher.listAccounts()
                    let name = switcher.git.get("user.name")
                    let email = switcher.git.get("user.email")
                    let git = name.map { n in email.map { "\(n) <\($0)>" } ?? n }
                    return (accounts, git)
                }.value
                self.accounts = accounts
                self.gitIdentity = git
                self.config = try store.load()
                self.errorMessage = nil
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func switchTo(_ account: AccountInfo) {
        guard switching == nil, !account.active else { return }
        switching = account.key
        Task {
            defer { switching = nil }
            do {
                _ = try await Task.detached { try Switcher().switchTo(account.key) }.value
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            refresh()
        }
    }

    func remove(_ account: AccountInfo) {
        Task {
            do {
                _ = try await Task.detached { try Switcher().remove(account.key) }.value
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            refresh()
        }
    }

    func updateProfile(_ key: String, _ change: (inout AccountProfile) -> Void) {
        var profile = config.profiles[key] ?? AccountProfile()
        change(&profile)
        config.profiles[key] = profile
        saveConfig()
    }

    func saveConfig() {
        do {
            // Merge onto disk, under the config lock, so cached API details written by the CLI aren't lost.
            try store.update { [config] onDisk in
                onDisk.updateGitIdentity = config.updateGitIdentity
                onDisk.showLoginInMenuBar = config.showLoginInMenuBar
                for (key, profile) in config.profiles {
                    var merged = onDisk.profiles[key] ?? profile
                    merged.label = profile.label
                    merged.gitName = profile.gitName
                    merged.gitEmail = profile.gitEmail
                    onDisk.profiles[key] = merged
                }
            }
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshAvatars() {
        Task {
            _ = try? await Task.detached {
                let switcher = try Switcher()
                try switcher.enrichProfiles(for: try switcher.gh.accounts(), force: true)
            }.value
            refresh()
        }
    }

    func refreshClaudeStatus() {
        Task {
            desktopInstalled = ClaudeDesktopIntegration.isInstalled()
            claudeInstalled = await Task.detached { ClaudeIntegration.isInstalled() }.value
        }
    }

    func installClaude() {
        guard let cliPath else {
            errorMessage = "The gh-switch CLI isn't bundled. Build the app with scripts/build-app.sh."
            return
        }
        Task {
            do {
                try await Task.detached { try ClaudeIntegration.install(cliPath: cliPath) }.value
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            refreshClaudeStatus()
        }
    }

    func installDesktop() {
        guard let cliPath else {
            errorMessage = "The gh-switch CLI isn't bundled. Build the app with scripts/build-app.sh."
            return
        }
        do {
            try ClaudeDesktopIntegration.install(cliPath: cliPath)
            errorMessage = ClaudeDesktopIntegration.isRunning
                ? "Added to Claude's config. Quit and reopen Claude to load it." : nil
        } catch {
            errorMessage = error.localizedDescription
        }
        refreshClaudeStatus()
    }

    /// `gh auth login` is interactive, so run it in Terminal via a temporary .command file.
    func addAccount() {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("gh-switch-add-account.command")
        let gh = Shell.find("gh") ?? "gh"
        let contents = "#!/bin/zsh\n'\(gh)' auth login --web --git-protocol https\necho\necho 'Done. You can close this window.'\n"
        do {
            try contents.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject?

    init(url: URL, onChange: @escaping () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { source = nil; return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    deinit { source?.cancel() }
}
