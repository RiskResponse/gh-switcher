import Foundation

public enum GHSwitchError: LocalizedError, Equatable {
    case toolNotFound(String)
    case commandFailed(String, String)
    case noMatch(String, available: [String])
    case ambiguous(String, candidates: [String])

    public var errorDescription: String? {
        switch self {
        case .toolNotFound(let tool):
            return "Could not find `\(tool)`. Install it (e.g. `brew install \(tool)`) and try again."
        case .commandFailed(let command, let stderr):
            return "`\(command)` failed: \(stderr.trimmed)"
        case .noMatch(let query, let available):
            return "No account matches \"\(query)\". Available: \(available.joined(separator: ", "))"
        case .ambiguous(let query, let candidates):
            return "\"\(query)\" matches several accounts: \(candidates.joined(separator: ", ")). Be more specific."
        }
    }
}

/// An account as reported by `gh auth status --json hosts`.
public struct GHAccount: Codable, Hashable, Sendable {
    public let host: String
    public let login: String
    public let active: Bool
    public let state: String
    public let scopes: String?
    public let gitProtocol: String?

    public var key: String { "\(host)/\(login)" }

    public init(host: String, login: String, active: Bool, state: String = "success", scopes: String? = nil, gitProtocol: String? = nil) {
        self.host = host
        self.login = login
        self.active = active
        self.state = state
        self.scopes = scopes
        self.gitProtocol = gitProtocol
    }

    public static func parseAuthStatus(_ data: Data) throws -> [GHAccount] {
        struct AuthStatus: Decodable { let hosts: [String: [GHAccount]] }
        let status = try JSONDecoder().decode(AuthStatus.self, from: data)
        return status.hosts.keys.sorted().flatMap { status.hosts[$0] ?? [] }
    }
}

/// Subset of `GET /user`.
public struct GHUser: Codable, Sendable {
    public let id: Int
    public let login: String
    public let name: String?
    public let avatarUrl: String?
}

/// User-editable and cached details for one account, keyed by `host/login` in `Config`.
public struct AccountProfile: Codable, Hashable, Sendable {
    public var label: String?
    public var gitName: String?
    public var gitEmail: String?
    public var userID: Int?
    public var displayName: String?
    public var avatarURL: String?

    public init(label: String? = nil, gitName: String? = nil, gitEmail: String? = nil, userID: Int? = nil, displayName: String? = nil, avatarURL: String? = nil) {
        self.label = label
        self.gitName = gitName
        self.gitEmail = gitEmail
        self.userID = userID
        self.displayName = displayName
        self.avatarURL = avatarURL
    }
}

public struct Config: Codable, Sendable, Equatable {
    public var updateGitIdentity: Bool = true
    public var showLoginInMenuBar: Bool = true
    public var profiles: [String: AccountProfile] = [:]

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        updateGitIdentity = try c.decodeIfPresent(Bool.self, forKey: .updateGitIdentity) ?? true
        showLoginInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showLoginInMenuBar) ?? true
        profiles = try c.decodeIfPresent([String: AccountProfile].self, forKey: .profiles) ?? [:]
    }
}

/// An account merged with its profile, with git identity defaults resolved.
public struct AccountInfo: Codable, Hashable, Sendable, Identifiable {
    public let key: String
    public let host: String
    public let login: String
    public let active: Bool
    public let label: String?
    public let displayName: String?
    public let avatarURL: String?
    public let gitName: String
    public let gitEmail: String?

    public var id: String { key }
    public var title: String { label.flatMap { $0.isEmpty ? nil : $0 } ?? login }

    public init(account: GHAccount, profile: AccountProfile?) {
        let profile = profile ?? AccountProfile()
        key = account.key
        host = account.host
        login = account.login
        active = account.active
        label = profile.label?.nilIfBlank
        displayName = profile.displayName
        avatarURL = profile.avatarURL
        gitName = profile.gitName?.nilIfBlank ?? profile.displayName?.nilIfBlank ?? account.login
        gitEmail = profile.gitEmail?.nilIfBlank ?? Self.noreplyEmail(host: account.host, login: account.login, userID: profile.userID)
    }

    static func noreplyEmail(host: String, login: String, userID: Int?) -> String? {
        guard host == "github.com", let userID else { return nil }
        return "\(userID)+\(login)@users.noreply.github.com"
    }
}

extension String {
    var nilIfBlank: String? { trimmed.isEmpty ? nil : self }
}
