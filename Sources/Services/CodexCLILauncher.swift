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
    private static let managedModelCatalogFileName = "model-catalog.json"
    private static let managedBaseInstructions = """
    You are Codex, a coding agent. You share the user's workspace and collaborate to achieve the user's goals.

    Be pragmatic, direct, and concise. Prefer making the requested change over describing it at length. State assumptions and blockers clearly when they matter.

    Read the relevant code before editing. Prefer fast search tools such as rg or rg --files when available. Keep changes tightly scoped to the user's request.

    Do not revert unrelated user changes. Avoid destructive commands unless the user explicitly asks for them. Prefer non-interactive git commands.

    When the user clearly wants code or file changes, make them instead of only outlining a plan. If something blocks the requested change, explain the blocker precisely.

    Share short commentary updates while working and provide a concise final answer when finished. Mention important verification you completed and any notable remaining risk.

    Use Markdown when it improves readability, but keep responses compact and easy to scan.
    """
    private static let managedReasoningLevels: [[String: String]] = [
        [
            "effort": "low",
            "description": "Fast responses with lighter reasoning",
        ],
        [
            "effort": "medium",
            "description": "Balances speed and reasoning depth for everyday tasks",
        ],
        [
            "effort": "high",
            "description": "Greater reasoning depth for complex problems",
        ],
        [
            "effort": "xhigh",
            "description": "Extra high reasoning depth for complex problems",
        ],
    ]

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
            try fileManager.createDirectory(at: codexHomeURL, withIntermediateDirectories: true)
            if let payload = context.authPayload {
                let authFileURL = codexHomeURL.appendingPathComponent("auth.json")
                try AuthFileManager(authFileURL: authFileURL, fileManager: fileManager).activate(payload)
            }
            let managedConfigContents = try managedConfigContents(
                from: context,
                codexHomeURL: codexHomeURL
            )
            if let managedConfigContents {
                let configURL = codexHomeURL.appendingPathComponent("config.toml")
                try managedConfigContents.write(to: configURL, atomically: true, encoding: .utf8)
            }

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

    private func managedConfigContents(
        from context: ResolvedCodexCLILaunchContext,
        codexHomeURL: URL
    ) throws -> String? {
        var configContents = context.configFileContents ?? ""

        if let snapshot = context.modelCatalogSnapshot {
            let modelCatalogURL = codexHomeURL.appendingPathComponent(Self.managedModelCatalogFileName)
            let catalogContents = try modelCatalogContents(from: snapshot)
            try catalogContents.write(to: modelCatalogURL, atomically: true, encoding: .utf8)
            if !configContents.isEmpty, !configContents.hasSuffix("\n") {
                configContents.append("\n")
            }
            configContents.append("model_catalog_json = \"\(tomlEscaped(modelCatalogURL.path))\"\n")
        }

        return configContents.isEmpty ? nil : configContents
    }

    private func modelCatalogContents(from snapshot: ResolvedCodexModelCatalogSnapshot) throws -> String {
        let models = normalizedAvailableModels(snapshot.availableModels)
        let catalog = [
            "models": models.enumerated().map { index, model in
                modelCatalogEntry(for: model, priority: index)
            },
        ]
        let data = try JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    private func modelCatalogEntry(for model: String, priority: Int) -> [String: Any] {
        [
            "apply_patch_tool_type": "freeform",
            "availability_nux": NSNull(),
            "base_instructions": Self.managedBaseInstructions,
            "context_window": 272000,
            "default_reasoning_level": "medium",
            "default_reasoning_summary": "none",
            "default_verbosity": "low",
            "description": model,
            "display_name": model,
            "experimental_supported_tools": [],
            "input_modalities": ["text", "image"],
            "priority": priority,
            "shell_type": "shell_command",
            "slug": model,
            "support_verbosity": true,
            "supported_in_api": true,
            "supported_reasoning_levels": Self.managedReasoningLevels,
            "supports_image_detail_original": true,
            "supports_parallel_tool_calls": true,
            "supports_reasoning_summaries": true,
            "truncation_policy": [
                "limit": 10000,
                "mode": "tokens",
            ],
            "upgrade": NSNull(),
            "visibility": "list",
        ]
    }

    private func normalizedAvailableModels(_ availableModels: [String]) -> [String] {
        var normalized = [String]()
        var seen = Set<String>()

        for model in availableModels {
            let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedModel.isEmpty, seen.insert(trimmedModel).inserted else { continue }
            normalized.append(trimmedModel)
        }

        return normalized
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

    private func tomlEscaped(_ value: String) -> String {
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
