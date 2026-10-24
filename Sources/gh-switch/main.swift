import Foundation
import GHSwitchCore

let usage = """
usage: gh-switch [command]

  list [--json]       List accounts (default)
  current [--json]    Show the active account and git identity
  switch <account>    Switch by login, label, or unique substring
  remove <account>    Log an account out of gh (exact login, label, or host/login)
  mcp                 Run as an MCP server over stdio (used by Claude)
  install-claude      Register the MCP server with Claude Code (user scope)
  install-desktop     Register the MCP server with the Claude desktop app (chat and Cowork)
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("gh-switch: \(message)\n".utf8))
    exit(1)
}

func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

func describe(_ a: AccountInfo) -> String {
    let marker = a.active ? "*" : " "
    let label = a.label.map { " [\($0)]" } ?? ""
    return "\(marker) \(a.login)\(label)  \(a.host)  \(a.gitName) <\(a.gitEmail ?? "?")>"
}

var selfPath: String {
    URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath().path
}

var args = Array(CommandLine.arguments.dropFirst())
let command = args.isEmpty ? "list" : args.removeFirst()
let wantsJSON = args.contains("--json")

do {
    switch command {
    case "list", "ls":
        let accounts = try Switcher().listAccounts()
        if wantsJSON { try printJSON(accounts) } else { accounts.forEach { print(describe($0)) } }
    case "current", "status":
        let status = try Switcher().currentStatus()
        if wantsJSON {
            try printJSON(status)
        } else {
            print("account: \(status.account.map { "\($0.login) (\($0.host))" } ?? "none")")
            print("git:     \(status.gitName ?? "?") <\(status.gitEmail ?? "?")>")
        }
    case "switch", "use":
        guard let query = args.first else { fail("switch needs an account, e.g. `gh-switch switch acme`") }
        let outcome = try Switcher().switchTo(query)
        let a = outcome.account
        print(outcome.alreadyActive ? "Already on \(a.login)" : "Switched to \(a.login) (\(a.host))")
        if outcome.gitIdentityUpdated { print("git identity: \(a.gitName) <\(a.gitEmail ?? "unchanged")>") }
    case "remove", "rm":
        guard let query = args.first else { fail("remove needs an account, e.g. `gh-switch remove octo`") }
        let outcome = try Switcher().remove(query)
        print("Removed \(outcome.removed.login) (\(outcome.removed.host))")
        if let next = outcome.newActive { print("Now active: \(next.login) (\(next.host))") }
    case "mcp":
        MCPServer(service: { try Switcher() }).run()
    case "install-claude":
        try ClaudeIntegration.install(cliPath: selfPath)
        print("Registered MCP server `\(ClaudeIntegration.serverName)` -> \(selfPath) mcp")
    case "install-desktop":
        try ClaudeDesktopIntegration.install(cliPath: selfPath)
        print("Added `\(ClaudeIntegration.serverName)` to \(ClaudeDesktopIntegration.configURL.path)")
        print("Quit and reopen Claude to load it.")
    case "help", "-h", "--help":
        print(usage)
    default:
        fail("unknown command `\(command)`\n\n\(usage)")
    }
} catch {
    fail(error.localizedDescription)
}
