import Foundation

public struct CurrentStatus: Codable, Sendable {
    public let account: AccountInfo?
    public let gitName: String?
    public let gitEmail: String?
}

public struct SwitchOutcome: Codable, Sendable {
    public let account: AccountInfo
    public let alreadyActive: Bool
    public let gitIdentityUpdated: Bool
}

public struct RemoveOutcome: Codable, Sendable {
    public let removed: AccountInfo
    public let newActive: AccountInfo?
    public let gitIdentityUpdated: Bool
}

public protocol AccountService {
    func listAccounts() throws -> [AccountInfo]
    func currentStatus() throws -> CurrentStatus
    /// `allowPartial` also accepts a unique substring of a login or label.
    func switchTo(_ query: String, allowPartial: Bool) throws -> SwitchOutcome
}

extension AccountService {
    public func switchTo(_ query: String) throws -> SwitchOutcome {
        try switchTo(query, allowPartial: true)
    }
}

public struct Switcher: AccountService {
    public let gh: GHClient
    public let git: GitConfig
    public let store: ConfigStore

    public init(gh: GHClient? = nil, git: GitConfig? = nil, store: ConfigStore = ConfigStore()) throws {
        self.gh = try gh ?? GHClient()
        self.git = try git ?? GitConfig()
        self.store = store
    }

    public func listAccounts() throws -> [AccountInfo] {
        let accounts = try gh.accounts()
        let config = try enrichProfiles(for: accounts)
        return accounts.map { AccountInfo(account: $0, profile: config.profiles[$0.key]) }
    }

    public func currentStatus() throws -> CurrentStatus {
        let active = try listAccounts().first(where: \.active)
        return CurrentStatus(account: active, gitName: git.get("user.name"), gitEmail: git.get("user.email"))
    }

    public func switchTo(_ query: String, allowPartial: Bool) throws -> SwitchOutcome {
        let accounts = try gh.accounts()
        let target = try Self.resolve(query, accounts: accounts, config: try store.load(), allowPartial: allowPartial)
        if !target.active {
            try gh.switchAccount(host: target.host, login: target.login)
        }
        let config = try enrichProfiles(for: [target])
        let switched = GHAccount(host: target.host, login: target.login, active: true, state: target.state, scopes: target.scopes, gitProtocol: target.gitProtocol)
        let info = AccountInfo(account: switched, profile: config.profiles[target.key])

        if config.updateGitIdentity {
            do {
                try git.set("user.name", info.gitName)
                // Leaving the previous account's email would pair this account's name with someone else's address.
                if let email = info.gitEmail { try git.set("user.email", email) } else { try git.unset("user.email") }
            } catch where !target.active {
                throw GHSwitchError.partiallySwitched(target.login, reason: error.localizedDescription)
            }
        }
        return SwitchOutcome(account: info, alreadyActive: target.active, gitIdentityUpdated: config.updateGitIdentity)
    }

    /// Logs the account out of gh and forgets its profile. Requires an exact login, label or `host/login`.
    public func remove(_ query: String) throws -> RemoveOutcome {
        let accounts = try gh.accounts()
        let target = try Self.resolve(query, accounts: accounts, config: try store.load(), allowPartial: false)
        try gh.logout(host: target.host, login: target.login)

        // The token is gone now, so report any later failure as a partial removal rather than a plain error.
        do {
            var profile: AccountProfile?
            try store.update { config in
                profile = config.profiles[target.key]
                config.profiles[target.key] = nil
            }
            let removed = AccountInfo(account: target, profile: profile)

            // gh activates another account on the same host when the active one logs out; bring the git identity along.
            guard target.active,
                  let next = try gh.accounts().first(where: { $0.active && $0.host == target.host }) else {
                return RemoveOutcome(removed: removed, newActive: nil, gitIdentityUpdated: false)
            }
            let outcome = try switchTo(next.key, allowPartial: false)
            return RemoveOutcome(removed: removed, newActive: outcome.account, gitIdentityUpdated: outcome.gitIdentityUpdated)
        } catch {
            throw GHSwitchError.partiallyRemoved(target.login, reason: error.localizedDescription)
        }
    }

    /// Fetches name/avatar/id from the GitHub API for accounts not yet cached. Best effort.
    @discardableResult
    public func enrichProfiles(for accounts: [GHAccount], force: Bool = false) throws -> Config {
        let config = try store.load()
        // The API calls are slow, so make them before taking the config lock, then apply only the fetched fields.
        var users: [String: GHUser] = [:]
        for account in accounts where force || config.profiles[account.key]?.userID == nil {
            users[account.key] = try? gh.user(host: account.host, login: account.login)
        }
        guard !users.isEmpty else { return config }
        return (try? store.update { config in
            for (key, user) in users {
                var profile = config.profiles[key] ?? AccountProfile()
                profile.userID = user.id
                profile.displayName = user.name
                profile.avatarURL = user.avatarUrl
                config.profiles[key] = profile
            }
        }) ?? config
    }

    /// Matches by exact login, label or `host/login` first, then by unique substring.
    public static func resolve(_ query: String, accounts: [GHAccount], config: Config, allowPartial: Bool = true) throws -> GHAccount {
        var q = query.trimmed.lowercased()
        if q.hasPrefix("@") { q.removeFirst() }
        guard !q.isEmpty else { throw GHSwitchError.noMatch(query, available: accounts.map(\.login)) }
        let labelled = accounts.map { ($0, config.profiles[$0.key]?.label?.nilIfBlank?.trimmed.lowercased()) }

        let exact = labelled.filter { $0.0.login.lowercased() == q || $0.1 == q || $0.0.key.lowercased() == q }
        if exact.count == 1 { return exact[0].0 }
        if exact.count > 1 { throw GHSwitchError.ambiguous(query, candidates: exact.map(\.0.key)) }
        guard allowPartial else { throw GHSwitchError.noMatch(query, available: accounts.map(\.login)) }

        let partial = labelled.filter { $0.0.login.lowercased().contains(q) || ($0.1?.contains(q) ?? false) }
        if partial.count == 1 { return partial[0].0 }
        if partial.count > 1 { throw GHSwitchError.ambiguous(query, candidates: partial.map(\.0.login)) }
        throw GHSwitchError.noMatch(query, available: accounts.map(\.login))
    }
}
