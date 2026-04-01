import Foundation

enum CodexCLILauncherError: LocalizedError, Equatable {
    case appleScriptFailed(String)

    var errorDescription: String? {
        switch self {
        case let .appleScriptFailed(message):
            return L10n.tr("通过 Terminal 打开 Codex CLI 失败：%@", message)
        }
    }
}

struct CodexCLILauncher {
    private let fileManager: FileManager
    private let runAppleScript: ([String]) throws -> Void

    init(
        fileManager: FileManager = .default,
        runAppleScript: @escaping ([String]) throws -> Void = Self.runAppleScript
    ) {
        self.fileManager = fileManager
        self.runAppleScript = runAppleScript
    }

    func launchCLI(context: ResolvedCodexCLILaunchContext) throws {
        let command = try command(for: context)
        try runAppleScript(appleScriptLines(for: command))
    }

    private func command(for context: ResolvedCodexCLILaunchContext) throws -> String {
        let prefix = "cd \(shellQuoted(context.workingDirectoryURL.standardizedFileURL.path)) && "

        switch context.mode {
        case .globalCurrentAuth:
            return prefix + executableCommand(arguments: context.arguments)
        case .isolated:
            guard let codexHomeURL = context.codexHomeURL else {
                return prefix + executableCommand(arguments: context.arguments)
            }

            try CodexManagedHomeWriter(fileManager: fileManager).prepareManagedHome(
                codexHomeURL: codexHomeURL,
                authPayload: context.authPayload,
                configFileContents: context.configFileContents,
                modelCatalogSnapshot: context.modelCatalogSnapshot
            )

            var environmentVariables = context.environmentVariables
            environmentVariables["CODEX_HOME"] = codexHomeURL.path
            return prefix + envCommand(
                environmentVariables: environmentVariables,
                executable: executableCommand(arguments: context.arguments)
            )
        }
    }

    private func executableCommand(arguments: [String]) -> String {
        let parts = ["codex"] + arguments.map(shellQuoted)
        return parts.joined(separator: " ")
    }

    private func envCommand(environmentVariables: [String: String], executable: String) -> String {
        let prefixes = environmentVariables
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(shellQuoted($0.value))" }
            .joined(separator: " ")
        if prefixes.isEmpty {
            return executable
        }
        return "env \(prefixes) \(executable)"
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
            let message = stderr.isEmpty ? (stdout.isEmpty ? L10n.tr("未知错误") : stdout) : stderr
            throw CodexCLILauncherError.appleScriptFailed(message)
        }
    }
}

extension CodexCLILauncher: CodexCLILaunching {}
