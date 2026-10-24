import Foundation

public struct ShellResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public var ok: Bool { status == 0 }
}

public enum Shell {
    /// GUI apps launch with a minimal PATH, so common install locations are appended.
    static let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "\(NSHomeDirectory())/.local/bin"]

    public static func find(_ name: String) -> String? {
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in pathDirs + extraPaths {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    public static func run(_ executable: String, _ args: [String], env: [String: String] = [:]) throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        let path = environment["PATH"].map { "\($0):" } ?? ""
        environment["PATH"] = path + extraPaths.joined(separator: ":")
        environment.merge(env) { _, new in new }
        process.environment = environment

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        // Never inherit stdin: in MCP mode it carries the JSON-RPC stream.
        process.standardInput = FileHandle.nullDevice
        try process.run()

        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()

        return ShellResult(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
