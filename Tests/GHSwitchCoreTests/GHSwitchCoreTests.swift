import Foundation
@testable import GHSwitchCore
import Testing

let statusJSON = """
{"hosts":{"github.com":[
  {"state":"success","active":true,"host":"github.com","login":"octocat","tokenSource":"keyring","scopes":"repo","gitProtocol":"https"},
  {"state":"success","active":false,"host":"github.com","login":"octocat-acme","tokenSource":"keyring","scopes":"repo","gitProtocol":"https"},
  {"state":"success","active":false,"host":"github.com","login":"hubot-ops","tokenSource":"keyring","scopes":"repo","gitProtocol":"https"}
]}}
"""

func sampleAccounts() throws -> [GHAccount] {
    try GHAccount.parseAuthStatus(Data(statusJSON.utf8))
}

@Test func parsesAuthStatus() throws {
    let accounts = try sampleAccounts()
    #expect(accounts.map(\.login) == ["octocat", "octocat-acme", "hubot-ops"])
    #expect(accounts.filter(\.active).map(\.login) == ["octocat"])
    #expect(accounts[0].key == "github.com/octocat")
}

@Test(arguments: [
    ("octocat", "octocat"),
    ("@Octocat", "octocat"),
    ("acme", "octocat-acme"),
    ("hubot", "hubot-ops"),
    ("ops", "hubot-ops"),
    ("work", "hubot-ops"),
    ("github.com/octocat-acme", "octocat-acme"),
])
func resolvesQueries(query: String, expected: String) throws {
    var config = Config()
    config.profiles["github.com/hubot-ops"] = AccountProfile(label: "Work")
    let match = try Switcher.resolve(query, accounts: try sampleAccounts(), config: config)
    #expect(match.login == expected)
}

@Test func ambiguousQueryThrows() throws {
    #expect(throws: GHSwitchError.ambiguous("octo", candidates: ["octocat", "octocat-acme"])) {
        try Switcher.resolve("octo", accounts: try sampleAccounts(), config: Config())
    }
}

@Test func unknownQueryThrows() throws {
    #expect(throws: GHSwitchError.self) {
        try Switcher.resolve("nobody", accounts: try sampleAccounts(), config: Config())
    }
}

@Test func gitIdentityDefaults() {
    let account = GHAccount(host: "github.com", login: "octo", active: true)
    let bare = AccountInfo(account: account, profile: nil)
    #expect(bare.gitName == "octo")
    #expect(bare.gitEmail == nil)

    let cached = AccountInfo(account: account, profile: AccountProfile(userID: 42, displayName: "Octo Cat"))
    #expect(cached.gitName == "Octo Cat")
    #expect(cached.gitEmail == "42+octo@users.noreply.github.com")

    let custom = AccountInfo(account: account, profile: AccountProfile(label: " ", gitName: "Me", gitEmail: "me@work.com", userID: 42))
    #expect(custom.gitName == "Me")
    #expect(custom.gitEmail == "me@work.com")
    #expect(custom.title == "octo")
}

@Test func enterpriseHostHasNoNoreplyDefault() {
    let account = GHAccount(host: "ghe.example.com", login: "octo", active: false)
    #expect(AccountInfo(account: account, profile: AccountProfile(userID: 1)).gitEmail == nil)
}

@Test func configDecodesWithMissingKeys() throws {
    let config = try JSONDecoder().decode(Config.self, from: Data(#"{"profiles":{}}"#.utf8))
    #expect(config.updateGitIdentity)
    #expect(config.showLoginInMenuBar)
}

@Test func configStoreRoundTrips() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID())/config.json")
    let store = ConfigStore(url: url)
    var config = Config()
    config.updateGitIdentity = false
    config.profiles["github.com/octo"] = AccountProfile(label: "Personal")
    try store.save(config)
    #expect(try store.load() == config)
}

final class FakeService: AccountService {
    let accounts: [AccountInfo]
    var lastAllowPartial: Bool?

    init(accounts: [AccountInfo]) { self.accounts = accounts }

    func listAccounts() throws -> [AccountInfo] { accounts }
    func currentStatus() throws -> CurrentStatus {
        CurrentStatus(account: accounts.first(where: \.active), gitName: "Octo", gitEmail: "o@x.com")
    }
    func switchTo(_ query: String, allowPartial: Bool) throws -> SwitchOutcome {
        lastAllowPartial = allowPartial
        guard let match = accounts.first(where: { $0.login == query }) else {
            throw GHSwitchError.noMatch(query, available: accounts.map(\.login))
        }
        return SwitchOutcome(account: match, alreadyActive: match.active, gitIdentityUpdated: true)
    }
}

func makeServer(_ service: FakeService = makeService()) -> MCPServer {
    MCPServer(service: { service })
}

func makeService() -> FakeService {
    FakeService(accounts: [
        AccountInfo(account: GHAccount(host: "github.com", login: "octo", active: true), profile: nil),
        AccountInfo(account: GHAccount(host: "github.com", login: "hubot", active: false), profile: AccountProfile(userID: 7)),
    ])
}

func toolText(_ response: [String: Any]?) -> (String, Bool) {
    let result = response?["result"] as? [String: Any]
    let content = result?["content"] as? [[String: Any]]
    return (content?.first?["text"] as? String ?? "", result?["isError"] as? Bool ?? false)
}

@Test func mcpInitializeEchoesProtocolVersion() {
    let response = makeServer().handle(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-03-26"]])
    let result = response?["result"] as? [String: Any]
    #expect(result?["protocolVersion"] as? String == "2025-03-26")
    #expect(response?["id"] as? Int == 1)
}

@Test func mcpIgnoresNotifications() {
    #expect(makeServer().handle(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)
}

@Test func mcpListsTools() {
    let response = makeServer().handle(["jsonrpc": "2.0", "id": "a", "method": "tools/list"])
    let tools = (response?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
    #expect(tools?.compactMap { $0["name"] as? String } == ["list_github_accounts", "get_active_github_account", "switch_github_account"])
    let readOnly = tools?.map { ($0["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool }
    #expect(readOnly == [true, true, false])
}

@Test func mcpSwitchTool() {
    let service = makeService()
    let server = makeServer(service)
    let (text, isError) = toolText(server.handle([
        "jsonrpc": "2.0", "id": 2, "method": "tools/call",
        "params": ["name": "switch_github_account", "arguments": ["account": "hubot"]],
    ]))
    #expect(!isError)
    #expect(text.contains("Switched active GitHub account to hubot"))
    #expect(text.contains("7+hubot@users.noreply.github.com"))
    #expect(service.lastAllowPartial == false)

    let (missing, missingIsError) = toolText(server.handle([
        "jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "switch_github_account", "arguments": [:]],
    ]))
    #expect(missingIsError)
    #expect(missing.contains("account"))

    let (noMatch, noMatchIsError) = toolText(server.handle([
        "jsonrpc": "2.0", "id": 4, "method": "tools/call",
        "params": ["name": "switch_github_account", "arguments": ["account": "nobody"]],
    ]))
    #expect(noMatchIsError)
    #expect(noMatch.contains("list_github_accounts"))
    #expect(!noMatch.contains("hubot"))
}

@Test func mcpSwitchIsMarkedDestructive() {
    let switchTool = MCPServer.tools.first { $0["name"] as? String == "switch_github_account" }
    let annotations = switchTool?["annotations"] as? [String: Any]
    #expect(annotations?["destructiveHint"] as? Bool == true)
}

@Test func mcpUnknownMethodErrors() {
    let response = makeServer().handle(["jsonrpc": "2.0", "id": 5, "method": "resources/list"])
    #expect((response?["error"] as? [String: Any])?["code"] as? Int == -32601)
}

@Test func exactOnlyRejectsSubstrings() throws {
    var config = Config()
    config.profiles["github.com/hubot-ops"] = AccountProfile(label: "Work")
    let accounts = try sampleAccounts()
    #expect(try Switcher.resolve("work", accounts: accounts, config: config, allowPartial: false).login == "hubot-ops")
    #expect(try Switcher.resolve("github.com/octocat", accounts: accounts, config: config, allowPartial: false).login == "octocat")
    #expect(throws: GHSwitchError.self) {
        try Switcher.resolve("acme", accounts: accounts, config: config, allowPartial: false)
    }
}

@Test func desktopInstallPreservesOtherServers() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("claude_desktop_config.json")
    try Data(#"{"mcpServers":{"other":{"command":"x"}},"preferences":{"a":1}}"#.utf8).write(to: url)

    #expect(!ClaudeDesktopIntegration.isInstalled(configURL: url))
    let backup = try ClaudeDesktopIntegration.install(cliPath: "/Apps/gh-switch", configURL: url)
    #expect(ClaudeDesktopIntegration.isInstalled(configURL: url))

    let config = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    let servers = config?["mcpServers"] as? [String: [String: Any]]
    #expect(servers?["other"]?["command"] as? String == "x")
    #expect(servers?["gh-switch"]?["command"] as? String == "/Apps/gh-switch")
    #expect(servers?["gh-switch"]?["args"] as? [String] == ["mcp"])
    #expect(config?["preferences"] != nil)
    #expect(backup.map { FileManager.default.fileExists(atPath: $0.path) } == true)
}

@Test func desktopInstallRequiresApp() {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID())/claude_desktop_config.json")
    #expect(throws: GHSwitchError.self) { try ClaudeDesktopIntegration.install(cliPath: "/x", configURL: url) }
}

@Test func emptyQueryNeverMatchesBlankLabel() throws {
    var config = Config()
    config.profiles["github.com/octocat"] = AccountProfile(label: "  ")
    #expect(throws: GHSwitchError.self) {
        try Switcher.resolve("@", accounts: try sampleAccounts(), config: config)
    }
}

@Test func configStoreDefaultsOnlyWhenMissing() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID())/config.json")
    #expect(try ConfigStore(url: url).load() == Config())

    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"updateGitIdentity": "no"}"#.utf8).write(to: url)
    #expect(throws: GHSwitchError.self) { try ConfigStore(url: url).load() }
}

@Test func desktopInstallWritesThroughSymlink() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let real = dir.appendingPathComponent("dotfiles.json")
    try Data("{}".utf8).write(to: real)
    let link = dir.appendingPathComponent("claude_desktop_config.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

    try ClaudeDesktopIntegration.install(cliPath: "/x", configURL: link)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == real.path)
    #expect(ClaudeDesktopIntegration.isInstalled(configURL: real))
}

@Test func shellRunTimesOut() {
    #expect(throws: GHSwitchError.self) { try Shell.run("/bin/sleep", ["5"], timeout: 0.3) }
}

@Test func shellRunUnsetsVariables() throws {
    setenv("GHS_TEST_SECRET", "leak", 1)
    let result = try Shell.run("/usr/bin/env", [], unsetting: ["GHS_TEST_SECRET"])
    #expect(!result.stdout.contains("GHS_TEST_SECRET"))
}

/// Writes fake `gh` and `git` scripts. `gh` serves `status.json` and logs its calls; `git` logs its calls.
struct FakeTools {
    let dir: URL
    var gh: String { dir.appendingPathComponent("gh").path }
    var git: String { dir.appendingPathComponent("git").path }
    var log: String { (try? String(contentsOf: dir.appendingPathComponent("calls.log"), encoding: .utf8)) ?? "" }

    init(status: String, gitFails: Bool = false) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try status.write(to: dir.appendingPathComponent("status.json"), atomically: true, encoding: .utf8)
        let d = dir.path
        try write("gh", """
        #!/bin/bash
        echo "gh $* token=${GH_TOKEN:-}" >> '\(d)/calls.log'
        case "$1 $2" in
          "auth status") cat '\(d)/status.json' 2>/dev/null ;;
          "auth token") if [ "$6" = "renamed" ]; then echo "stored-other"; else echo "stored-${6}"; fi ;;
          "auth logout") rm '\(d)/status.json' ;;
          "api --hostname") login="${GH_TOKEN#stored-}"; echo "{\\"id\\": 9, \\"login\\": \\"$login\\", \\"name\\": \\"N\\"}" ;;
        esac
        """)
        try write("git", "#!/bin/bash\necho \"git $*\" >> '\(d)/calls.log'\n" + (gitFails ? "echo locked >&2; exit 1\n" : ""))
    }

    private func write(_ name: String, _ script: String) throws {
        let url = dir.appendingPathComponent(name)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func switcher() throws -> Switcher {
        try Switcher(gh: GHClient(path: gh), git: GitConfig(path: git), store: ConfigStore(url: dir.appendingPathComponent("config.json")))
    }
}

let enterpriseStatus = """
{"hosts":{"ghe.example.com":[{"state":"success","active":false,"host":"ghe.example.com","login":"octo"}],
"github.com":[{"state":"success","active":true,"host":"github.com","login":"me"}]}}
"""

@Test func switchToEnterpriseUnsetsStaleEmail() throws {
    let tools = try FakeTools(status: enterpriseStatus)
    let outcome = try tools.switcher().switchTo("ghe.example.com/octo")
    #expect(outcome.account.gitEmail == nil)
    #expect(tools.log.contains("gh auth switch --hostname ghe.example.com --user octo"))
    #expect(tools.log.contains("git config --global --unset user.email"))
}

@Test func ghIgnoresInheritedToken() throws {
    setenv("GH_TOKEN", "stored-someone-else", 1)
    defer { unsetenv("GH_TOKEN") }
    let tools = try FakeTools(status: enterpriseStatus)
    let user = try GHClient(path: tools.gh).user(host: "github.com", login: "me")
    #expect(user.login == "me")
    #expect(tools.log.contains("gh auth token --hostname github.com --user me token=\n"))
}

@Test func mismatchedApiLoginIsRejected() throws {
    let tools = try FakeTools(status: enterpriseStatus)
    // The fake hands "renamed" a token that belongs to "other".
    #expect(throws: GHSwitchError.loginMismatch(expected: "renamed", actual: "other")) {
        _ = try GHClient(path: tools.gh).user(host: "github.com", login: "renamed")
    }
    #expect(try GHClient(path: tools.gh).user(host: "github.com", login: "ME").login == "ME")
}

@Test func removeReportsPartialFailureAfterLogout() throws {
    let tools = try FakeTools(status: enterpriseStatus)
    // The fake logout deletes gh's state, so the follow-up `gh auth status` fails after the token is gone.
    #expect(throws: GHSwitchError.partiallyRemoved("me", reason: "`gh auth status` failed: ")) {
        _ = try tools.switcher().remove("me")
    }
    #expect(tools.log.contains("gh auth logout --hostname github.com --user me"))
}

func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test func concurrentConfigUpdatesAreNotLost() throws {
    let store = ConfigStore(url: try tempDir().appendingPathComponent("config.json"))
    DispatchQueue.concurrentPerform(iterations: 20) { i in
        _ = try? store.update { $0.profiles["github.com/user\(i)"] = AccountProfile(label: "\(i)") }
    }
    #expect(try store.load().profiles.count == 20)
}

@Test func configStoreSavesThroughSymlink() throws {
    let dir = try tempDir()
    let real = dir.appendingPathComponent("dotfiles.json")
    try Data("{}".utf8).write(to: real)
    let link = dir.appendingPathComponent("config.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

    try ConfigStore(url: link).update { $0.showLoginInMenuBar = false }
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == real.path)
    #expect(try ConfigStore(url: real).load().showLoginInMenuBar == false)
}

@Test(arguments: ["", "relative/dir"])
func nonAbsoluteXDGConfigHomeIsIgnored(value: String) {
    let url = ConfigStore(environment: ["XDG_CONFIG_HOME": value]).url
    #expect(url.path == NSHomeDirectory() + "/.config/gh-switch/config.json")
}

@Test func gitIdentityIsTrimmed() {
    let info = AccountInfo(account: GHAccount(host: "github.com", login: "me", active: true),
                           profile: AccountProfile(label: " Work ", gitName: " Me ", gitEmail: "  me@example.com "))
    #expect(info.label == "Work")
    #expect(info.gitName == "Me")
    #expect(info.gitEmail == "me@example.com")
}

@Test func shellRunKillsChildThatIgnoresSigterm() {
    let start = Date()
    #expect(throws: GHSwitchError.self) {
        try Shell.run("/bin/sh", ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.3)
    }
    #expect(Date().timeIntervalSince(start) < Shell.killGrace + 3)
}

@Test func mcpAmbiguousErrorOmitsCandidates() {
    let message = GHSwitchError.ambiguous("work", candidates: ["github.com/alice", "github.com/bob"]).mcpDescription
    #expect(!message.contains("alice"))
}

@Test func mcpInitializeAnswersUnsupportedVersionWithLatest() {
    let response = makeServer().handle(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2099-01-01"]])
    let result = response?["result"] as? [String: Any]
    #expect(result?["protocolVersion"] as? String == MCPServer.defaultProtocolVersion)
}

@Test func switchReportsPartialWhenGitFails() throws {
    let tools = try FakeTools(status: enterpriseStatus, gitFails: true)
    do {
        _ = try tools.switcher().switchTo("ghe.example.com/octo")
        Issue.record("expected an error")
    } catch GHSwitchError.partiallySwitched(let login, _) {
        #expect(login == "octo")
    }
}

@Test func desktopInstallKeepsOnlyRecentBackups() throws {
    let dir = try tempDir()
    let config = dir.appendingPathComponent("claude_desktop_config.json")
    try Data("{}".utf8).write(to: config)
    for _ in 0..<8 { try ClaudeDesktopIntegration.install(cliPath: "/x", configURL: config) }
    let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".bak") }
    #expect(backups.count == ClaudeDesktopIntegration.backupsKept)
}
