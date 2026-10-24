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
    #expect(store.load() == config)
}

struct FakeService: AccountService {
    let accounts: [AccountInfo]

    func listAccounts() throws -> [AccountInfo] { accounts }
    func currentStatus() throws -> CurrentStatus {
        CurrentStatus(account: accounts.first(where: \.active), gitName: "Octo", gitEmail: "o@x.com")
    }
    func switchTo(_ query: String) throws -> SwitchOutcome {
        guard let match = accounts.first(where: { $0.login == query }) else {
            throw GHSwitchError.noMatch(query, available: accounts.map(\.login))
        }
        return SwitchOutcome(account: match, alreadyActive: match.active, gitIdentityUpdated: true)
    }
}

func makeServer() -> MCPServer {
    let accounts = [
        AccountInfo(account: GHAccount(host: "github.com", login: "octo", active: true), profile: nil),
        AccountInfo(account: GHAccount(host: "github.com", login: "hubot", active: false), profile: AccountProfile(userID: 7)),
    ]
    return MCPServer(service: { FakeService(accounts: accounts) })
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
    let server = makeServer()
    let (text, isError) = toolText(server.handle([
        "jsonrpc": "2.0", "id": 2, "method": "tools/call",
        "params": ["name": "switch_github_account", "arguments": ["account": "hubot"]],
    ]))
    #expect(!isError)
    #expect(text.contains("Switched active GitHub account to hubot"))
    #expect(text.contains("7+hubot@users.noreply.github.com"))

    let (missing, missingIsError) = toolText(server.handle([
        "jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "switch_github_account", "arguments": [:]],
    ]))
    #expect(missingIsError)
    #expect(missing.contains("account"))

    let (_, noMatchIsError) = toolText(server.handle([
        "jsonrpc": "2.0", "id": 4, "method": "tools/call",
        "params": ["name": "switch_github_account", "arguments": ["account": "nobody"]],
    ]))
    #expect(noMatchIsError)
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
    try ClaudeDesktopIntegration.install(cliPath: "/Apps/gh-switch", configURL: url)
    #expect(ClaudeDesktopIntegration.isInstalled(configURL: url))

    let config = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    let servers = config?["mcpServers"] as? [String: [String: Any]]
    #expect(servers?["other"]?["command"] as? String == "x")
    #expect(servers?["gh-switch"]?["command"] as? String == "/Apps/gh-switch")
    #expect(servers?["gh-switch"]?["args"] as? [String] == ["mcp"])
    #expect(config?["preferences"] != nil)
    #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("gh-switch.bak").path))
}

@Test func desktopInstallRequiresApp() {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID())/claude_desktop_config.json")
    #expect(throws: GHSwitchError.self) { try ClaudeDesktopIntegration.install(cliPath: "/x", configURL: url) }
}
