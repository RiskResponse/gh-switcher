import Foundation

public struct GHClient: Sendable {
    public let path: String

    public init(path: String? = nil) throws {
        guard let resolved = path ?? Shell.find("gh") else { throw GHSwitchError.toolNotFound("gh") }
        self.path = resolved
    }

    public func accounts() throws -> [GHAccount] {
        // Exits non-zero if any account has a problem, but still prints JSON.
        let result = try Shell.run(path, ["auth", "status", "--json", "hosts"])
        guard !result.stdout.trimmed.isEmpty else {
            throw GHSwitchError.commandFailed("gh auth status", result.stderr)
        }
        return try GHAccount.parseAuthStatus(Data(result.stdout.utf8))
    }

    public func switchAccount(host: String, login: String) throws {
        let result = try Shell.run(path, ["auth", "switch", "--hostname", host, "--user", login])
        guard result.ok else { throw GHSwitchError.commandFailed("gh auth switch --user \(login)", result.stderr) }
    }

    public func logout(host: String, login: String) throws {
        let result = try Shell.run(path, ["auth", "logout", "--hostname", host, "--user", login])
        guard result.ok else { throw GHSwitchError.commandFailed("gh auth logout --user \(login)", result.stderr) }
    }

    public func user(host: String, login: String) throws -> GHUser {
        let token = try Shell.run(path, ["auth", "token", "--hostname", host, "--user", login])
        guard token.ok else { throw GHSwitchError.commandFailed("gh auth token --user \(login)", token.stderr) }
        let env = ["GH_TOKEN": token.stdout.trimmed, "GH_ENTERPRISE_TOKEN": token.stdout.trimmed, "GH_HOST": host]
        let result = try Shell.run(path, ["api", "--hostname", host, "user"], env: env)
        guard result.ok else { throw GHSwitchError.commandFailed("gh api user", result.stderr) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(GHUser.self, from: Data(result.stdout.utf8))
    }

    public static var configDirectory: URL {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["GH_CONFIG_DIR"] { return URL(fileURLWithPath: dir) }
        if let xdg = env["XDG_CONFIG_HOME"] { return URL(fileURLWithPath: xdg).appendingPathComponent("gh") }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/gh")
    }
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
}

public struct ConfigStore: Sendable {
    public let url: URL

    public init(url: URL? = nil) {
        if let url {
            self.url = url
        } else {
            let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config")
            self.url = base.appendingPathComponent("gh-switch/config.json")
        }
    }

    public func load() -> Config {
        guard let data = try? Data(contentsOf: url) else { return Config() }
        return (try? JSONDecoder().decode(Config.self, from: data)) ?? Config()
    }

    public func save(_ config: Config) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: url, options: .atomic)
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

    /// Adds or replaces our `mcpServers` entry, leaving the rest of the file alone. Requires the app to be installed.
    public static func install(cliPath: String, configURL: URL = configURL) throws {
        guard FileManager.default.fileExists(atPath: configURL.deletingLastPathComponent().path) else {
            throw GHSwitchError.toolNotFound("Claude desktop app")
        }
        var config = try readConfig(configURL) ?? [:]
        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        servers[ClaudeIntegration.serverName] = ["command": cliPath, "args": ["mcp"]]
        config["mcpServers"] = servers

        if FileManager.default.fileExists(atPath: configURL.path) {
            let backup = configURL.appendingPathExtension("gh-switch.bak")
            try? FileManager.default.removeItem(at: backup)
            try FileManager.default.copyItem(at: configURL, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (data + Data("\n".utf8)).write(to: configURL, options: .atomic)
    }

    private static func readConfig(_ url: URL) throws -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GHSwitchError.commandFailed("read \(url.lastPathComponent)", "not a JSON object")
        }
        return object
    }
}
