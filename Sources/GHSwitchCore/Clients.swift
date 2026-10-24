import Foundation

public struct GHClient: Sendable {
    public let path: String

    public init(path: String? = nil) throws {
        guard let resolved = path ?? Shell.find("gh") else { throw GHSwitchError.toolNotFound("gh") }
        self.path = resolved
    }

    /// Variables that make gh use a token other than the stored one for the requested account.
    static let tokenOverrides = ["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN", "GH_HOST"]

    private func run(_ args: [String], env: [String: String] = [:]) throws -> ShellResult {
        try Shell.run(path, args, env: env, unsetting: Self.tokenOverrides)
    }

    public func accounts() throws -> [GHAccount] {
        // Exits non-zero if any account has a problem, but still prints JSON.
        let result = try run(["auth", "status", "--json", "hosts"])
        guard !result.stdout.trimmed.isEmpty else {
            throw GHSwitchError.commandFailed("gh auth status", result.stderr)
        }
        return try GHAccount.parseAuthStatus(Data(result.stdout.utf8))
    }

    public func switchAccount(host: String, login: String) throws {
        let result = try run(["auth", "switch", "--hostname", host, "--user", login])
        guard result.ok else { throw GHSwitchError.commandFailed("gh auth switch --user \(login)", result.stderr) }
    }

    public func logout(host: String, login: String) throws {
        let result = try run(["auth", "logout", "--hostname", host, "--user", login])
        guard result.ok else { throw GHSwitchError.commandFailed("gh auth logout --user \(login)", result.stderr) }
    }

    public func user(host: String, login: String) throws -> GHUser {
        let token = try run(["auth", "token", "--hostname", host, "--user", login])
        guard token.ok, !token.stdout.trimmed.isEmpty else {
            throw GHSwitchError.commandFailed("gh auth token --user \(login)", token.stderr)
        }
        let env = ["GH_TOKEN": token.stdout.trimmed, "GH_ENTERPRISE_TOKEN": token.stdout.trimmed, "GH_HOST": host]
        let result = try run(["api", "--hostname", host, "user"], env: env)
        guard result.ok else { throw GHSwitchError.commandFailed("gh api user", result.stderr) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let user = try decoder.decode(GHUser.self, from: Data(result.stdout.utf8))
        guard user.login.caseInsensitiveCompare(login) == .orderedSame else {
            throw GHSwitchError.loginMismatch(expected: login, actual: user.login)
        }
        return user
    }

    public static var configDirectory: URL {
        let env = ProcessInfo.processInfo.environment
        if let dir = absolutePath(env["GH_CONFIG_DIR"]) { return URL(fileURLWithPath: dir) }
        if let xdg = absolutePath(env["XDG_CONFIG_HOME"]) { return URL(fileURLWithPath: xdg).appendingPathComponent("gh") }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/gh")
    }
}

/// Per the XDG spec, an empty or relative directory variable is ignored rather than resolved against the cwd.
func absolutePath(_ value: String?) -> String? {
    guard let value, value.hasPrefix("/") else { return nil }
    return value
}

public struct GitConfig: Sendable {
    public let path: String

    public init(path: String? = nil) throws {
        guard let resolved = path ?? Shell.find("git") else { throw GHSwitchError.toolNotFound("git") }
        self.path = resolved
    }

    public func get(_ key: String) -> String? {
        guard let result = try? Shell.run(path, ["config", "--global", "--get", key]), result.ok else { return nil }
        return result.stdout.trimmed.nilIfBlank
    }

    public func set(_ key: String, _ value: String) throws {
        let result = try Shell.run(path, ["config", "--global", key, value])
        guard result.ok else { throw GHSwitchError.commandFailed("git config --global \(key)", result.stderr) }
    }

    public func unset(_ key: String) throws {
        let result = try Shell.run(path, ["config", "--global", "--unset", key])
        // Exit 5 means the key wasn't set.
        guard result.ok || result.status == 5 else {
            throw GHSwitchError.commandFailed("git config --global --unset \(key)", result.stderr)
        }
    }
}

public struct ConfigStore: Sendable {
    public let url: URL

    public init(url: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let url {
            self.url = url
        } else {
            let base = absolutePath(environment["XDG_CONFIG_HOME"]).map { URL(fileURLWithPath: $0) }
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config")
            self.url = base.appendingPathComponent("gh-switch/config.json")
        }
    }

    /// Loads, changes and saves the config while holding an exclusive lock, so the app, CLI and MCP server
    /// don't overwrite each other's changes. Keep slow work (subprocesses, network) out of `change`.
    @discardableResult
    public func update(_ change: (inout Config) throws -> Void) throws -> Config {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lockPath = url.resolvingSymlinksInPath().path + ".lock"
        let fd = open(lockPath, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { throw GHSwitchError.invalidConfig(lockPath, reason: String(cString: strerror(errno))) }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }

        var config = try load()
        let before = config
        try change(&config)
        if config != before { try save(config) }
        return config
    }

    /// Returns defaults only when the file doesn't exist. An unreadable or invalid file throws, so callers never
    /// act on, or save over, defaults the user didn't choose.
    public func load() throws -> Config {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return Config()
        } catch {
            throw GHSwitchError.invalidConfig(url.path, reason: error.localizedDescription)
        }
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            throw GHSwitchError.invalidConfig(url.path, reason: "not valid gh-switch JSON")
        }
    }

    public func save(_ config: Config) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Write through a symlink (e.g. a dotfiles-managed config) instead of replacing it.
        try encoder.encode(config).write(to: url.resolvingSymlinksInPath(), options: .atomic)
    }
}

/// Registers the `gh-switch mcp` server with Claude Code.
public enum ClaudeIntegration {
    public static let serverName = "gh-switch"

    public static func isInstalled() -> Bool {
        guard let claude = Shell.find("claude"),
              let result = try? Shell.run(claude, ["mcp", "get", serverName]) else { return false }
        return result.ok
    }

    public static func install(cliPath: String) throws {
        guard let claude = Shell.find("claude") else { throw GHSwitchError.toolNotFound("claude") }
        _ = try? Shell.run(claude, ["mcp", "remove", "--scope", "user", serverName])
        let result = try Shell.run(claude, ["mcp", "add", "--scope", "user", serverName, "--", cliPath, "mcp"])
        guard result.ok else { throw GHSwitchError.commandFailed("claude mcp add", result.stderr + result.stdout) }
    }
}

/// Registers the `gh-switch mcp` server with the Claude desktop app, which Cowork also uses.
public enum ClaudeDesktopIntegration {
    public static var configURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }

    public static func isInstalled(configURL: URL = configURL) -> Bool {
        guard let servers = (try? readConfig(configURL))?["mcpServers"] as? [String: Any] else { return false }
        return servers[ClaudeIntegration.serverName] != nil
    }

    /// Claude rewrites its config when it quits, which can drop an entry added while it was running.
    public static var isRunning: Bool {
        (try? Shell.run("/usr/bin/pgrep", ["-x", "Claude"]))?.ok ?? false
    }

    /// Adds or replaces our `mcpServers` entry, leaving the rest of the file alone. Requires the app to be installed.
    /// Returns the backup of the previous file, if there was one.
    @discardableResult
    public static func install(cliPath: String, configURL: URL = configURL) throws -> URL? {
        guard FileManager.default.fileExists(atPath: configURL.deletingLastPathComponent().path) else {
            throw GHSwitchError.toolNotFound("Claude desktop app")
        }
        // Write through a symlink (e.g. a dotfiles-managed config) instead of replacing it.
        let target = configURL.resolvingSymlinksInPath()
        let existing = try readConfig(target)
        var config = existing ?? [:]
        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        servers[ClaudeIntegration.serverName] = ["command": cliPath, "args": ["mcp"]]
        config["mcpServers"] = servers

        var backup: URL?
        if existing != nil {
            let stamp = ISO8601DateFormatter.string(
                from: Date(), timeZone: .current, formatOptions: [.withYear, .withMonth, .withDay, .withTime, .withFractionalSeconds])
            let url = target.appendingPathExtension("gh-switch-\(stamp).bak")
            try FileManager.default.copyItem(at: target, to: url)
            backup = url
            pruneBackups(of: target)
        }
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (data + Data("\n".utf8)).write(to: target, options: .atomic)
        return backup
    }

    static let backupsKept = 5

    /// Each backup is a full copy of the config, which can hold other servers' secrets, so keep only the newest few.
    private static func pruneBackups(of target: URL) {
        let dir = target.deletingLastPathComponent()
        let prefix = target.lastPathComponent + ".gh-switch-"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        let backups = names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".bak") }.sorted()
        for name in backups.dropLast(backupsKept) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    /// Returns nil only when the file doesn't exist.
    private static func readConfig(_ url: URL) throws -> [String: Any]? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GHSwitchError.commandFailed("read \(url.lastPathComponent)", "not a JSON object")
        }
        return object
    }
}
