import Foundation

/// Minimal MCP server (newline-delimited JSON-RPC over stdio) exposing account tools to Claude.
public final class MCPServer {
    static let defaultProtocolVersion = "2025-06-18"

    private let service: () throws -> AccountService

    public init(service: @escaping () throws -> AccountService) {
        self.service = service
    }

    public func run() {
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let response = handle(message),
                  let out = try? JSONSerialization.data(withJSONObject: response) else { continue }
            FileHandle.standardOutput.write(out + Data("\n".utf8))
        }
    }

    /// Returns the response for a request, or nil for notifications.
    public func handle(_ message: [String: Any]) -> [String: Any]? {
        guard let id = message["id"], let method = message["method"] as? String else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            return result(id, [
                "protocolVersion": params["protocolVersion"] as? String ?? Self.defaultProtocolVersion,
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": "gh-switch", "version": "1.0.0"],
                "instructions": "Use these tools to see and change which GitHub account the gh CLI and git use on this Mac. Switching is global: it affects every terminal and future git push/gh command.",
            ])
        case "ping":
            return result(id, [:])
        case "tools/list":
            return result(id, ["tools": Self.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            return result(id, callTool(name, args))
        default:
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]]
        }
    }

    private func result(_ id: Any, _ value: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": value]
    }

    private func callTool(_ name: String, _ args: [String: Any]) -> [String: Any] {
        do {
            let service = try service()
            switch name {
            case "list_github_accounts":
                return text(try json(service.listAccounts()))
            case "get_active_github_account":
                return text(try json(service.currentStatus()))
            case "switch_github_account":
                guard let query = args["account"] as? String, !query.trimmed.isEmpty else {
                    return text("Missing required argument `account`.", isError: true)
                }
                let outcome = try service.switchTo(query)
                let a = outcome.account
                var message = outcome.alreadyActive
                    ? "\(a.login) (\(a.host)) was already the active GitHub account."
                    : "Switched active GitHub account to \(a.login) (\(a.host))."
                if outcome.gitIdentityUpdated {
                    message += " Global git identity: \(a.gitName) <\(a.gitEmail ?? "unchanged")>."
                }
                return text(message)
            default:
                return text("Unknown tool: \(name)", isError: true)
            }
        } catch {
            return text(error.localizedDescription, isError: true)
        }
    }

    private func text(_ string: String, isError: Bool = false) -> [String: Any] {
        ["content": [["type": "text", "text": string]], "isError": isError]
    }

    private func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static let tools: [[String: Any]] = [
        [
            "name": "list_github_accounts",
            "description": "List the GitHub accounts logged in to the gh CLI, with labels, which one is active, and the git name/email each one uses.",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
            "annotations": ["title": "List GitHub accounts", "readOnlyHint": true, "openWorldHint": false],
        ],
        [
            "name": "get_active_github_account",
            "description": "Get the currently active GitHub account and the current global git user.name/user.email.",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
            "annotations": ["title": "Get active GitHub account", "readOnlyHint": true, "openWorldHint": false],
        ],
        [
            "name": "switch_github_account",
            "description": "Switch the active GitHub account for gh and git (git uses gh as its credential helper) and update the global git identity. Accepts a login, a label, or a unique part of either.",
            "inputSchema": [
                "type": "object",
                "properties": ["account": ["type": "string", "description": "Login, label, or unique substring, e.g. \"acme\" or \"work\"."]],
                "required": ["account"],
            ],
            "annotations": [
                "title": "Switch GitHub account", "readOnlyHint": false, "destructiveHint": false,
                "idempotentHint": true, "openWorldHint": false,
            ],
        ],
    ]
}
