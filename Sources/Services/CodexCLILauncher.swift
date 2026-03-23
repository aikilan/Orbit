import Foundation

enum CodexCLILauncherError: LocalizedError, Equatable {
    case appleScriptFailed(String)

    var errorDescription: String? {
        switch self {
        case let .appleScriptFailed(message):
            return "通过 Terminal 打开 Codex CLI 失败：\(message)"
        }
    }
}

struct CodexCLILauncher {
    private static let instancesDirectoryName = "isolated-codex-instances"

    private let fileManager: FileManager
    private let runAppleScript: ([String]) throws -> Void

    init(
        fileManager: FileManager = .default,
        runAppleScript: @escaping ([String]) throws -> Void = Self.runAppleScript
    ) {
        self.fileManager = fileManager
        self.runAppleScript = runAppleScript
    }

    func launchCLI(
        for account: ManagedAccount,
        mode: CodexCLILaunchMode,
        appSupportDirectoryURL: URL
    ) throws {
        let command: String

        switch mode {
        case .globalCurrentAuth:
            command = "codex"
        case let .isolatedAccount(payload):
            let codexHomeURL = isolatedCodexHomeURL(for: account, appSupportDirectoryURL: appSupportDirectoryURL)
            try fileManager.createDirectory(at: codexHomeURL, withIntermediateDirectories: true)
            let authFileURL = codexHomeURL.appendingPathComponent("auth.json")
            try AuthFileManager(authFileURL: authFileURL, fileManager: fileManager).activate(payload)
            command = "env CODEX_HOME=\(shellQuoted(codexHomeURL.path)) codex"
        }

        try runAppleScript(appleScriptLines(for: command))
    }

    private func isolatedCodexHomeURL(
        for account: ManagedAccount,
        appSupportDirectoryURL: URL
    ) -> URL {
        appSupportDirectoryURL
            .appendingPathComponent(Self.instancesDirectoryName, isDirectory: true)
            .appendingPathComponent(account.id.uuidString, isDirectory: true)
            .appendingPathComponent("codex-home", isDirectory: true)
    }

    private func appleScriptLines(for command: String) -> [String] {
        [
            "tell application \"Terminal\"",
            "activate",
            "do script \"\(appleScriptEscaped(command))\"",
            "end tell",
        ]
    }

    private func shellQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
        return "\"\(escaped)\""
    }

    private func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func runAppleScript(_ lines: [String]) throws {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript", isDirectory: false)
        process.arguments = lines.flatMap { ["-e", $0] }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let message = stderr.isEmpty ? (stdout.isEmpty ? "未知错误" : stdout) : stderr
            throw CodexCLILauncherError.appleScriptFailed(message)
        }
    }
}

extension CodexCLILauncher: CodexCLILaunching {}
