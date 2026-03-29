import Foundation

enum ClaudeCLILauncherError: LocalizedError, Equatable {
    case appleScriptFailed(String)

    var errorDescription: String? {
        switch self {
        case let .appleScriptFailed(message):
            return L10n.tr("通过 Terminal 打开 Claude CLI 失败：%@", message)
        }
    }
}

struct ClaudeCLILauncher {
    private let fileManager: FileManager
    private let runAppleScript: ([String]) throws -> Void

    init(
        fileManager: FileManager = .default,
        runAppleScript: @escaping ([String]) throws -> Void = Self.runAppleScript
    ) {
        self.fileManager = fileManager
        self.runAppleScript = runAppleScript
    }

    func launchCLI(context: ResolvedClaudeCLILaunchContext) throws {
        let command = try command(for: context)
        try runAppleScript(appleScriptLines(for: command))
    }

    private func command(for context: ResolvedClaudeCLILaunchContext) throws -> String {
        let prefix = "cd \(shellQuoted(context.workingDirectoryURL.standardizedFileURL.path)) && "
        let executable = context.patchedExecutableURL.map { shellQuoted($0.path) } ?? resolvedExecutable()
        let executableCommand = ([executable] + context.arguments.map(shellQuoted)).joined(separator: " ")

        var environmentVariables = context.environmentVariables

        if let rootURL = context.rootURL {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            environmentVariables["HOME"] = rootURL.path
        }
        if let configDirectoryURL = context.configDirectoryURL {
            try fileManager.createDirectory(at: configDirectoryURL, withIntermediateDirectories: true)
            try writeManagedSettingsIfNeeded(
                providerSnapshot: context.providerSnapshot,
                configDirectoryURL: configDirectoryURL
            )
            environmentVariables["CLAUDE_CONFIG_DIR"] = configDirectoryURL.path
        }

        return prefix + envCommand(environmentVariables: environmentVariables, executable: executableCommand)
    }

    private func writeManagedSettingsIfNeeded(
        providerSnapshot: ResolvedClaudeProviderSnapshot?,
        configDirectoryURL: URL
    ) throws {
        guard let providerSnapshot else { return }

        let settingsURL = configDirectoryURL.appendingPathComponent("settings.json", isDirectory: false)
        var settingsObject = [String: Any]()

        if fileManager.fileExists(atPath: settingsURL.path) {
            let data = try Data(contentsOf: settingsURL)
            if let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                settingsObject = existing
            }
        }

        settingsObject["model"] = providerSnapshot.model
        if let availableModels = providerSnapshot.availableModels {
            settingsObject["availableModels"] = normalizedAvailableModels(availableModels, fallbackModel: providerSnapshot.model)
        } else {
            settingsObject.removeValue(forKey: "availableModels")
        }

        let data = try JSONSerialization.data(withJSONObject: settingsObject, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: settingsURL, options: .atomic)
    }

    private func normalizedAvailableModels(_ models: [String], fallbackModel: String) -> [String] {
        var normalized = [String]()
        var seen = Set<String>()

        for model in models {
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            normalized.append(trimmed)
        }

        let trimmedFallback = fallbackModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedFallback.isEmpty, seen.insert(trimmedFallback).inserted {
            normalized.append(trimmedFallback)
        }

        return normalized
    }

    private func resolvedExecutable() -> String {
        let fixedURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("claude")

        if fileManager.isExecutableFile(atPath: fixedURL.path) {
            return shellQuoted(fixedURL.path)
        }

        return "claude"
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
            throw ClaudeCLILauncherError.appleScriptFailed(message)
        }
    }
}

extension ClaudeCLILauncher: ClaudeCLILaunching {}
