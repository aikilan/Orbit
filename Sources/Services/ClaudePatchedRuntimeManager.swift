import CryptoKit
import Foundation

enum ClaudePatchedRuntimeManagerError: LocalizedError, Equatable {
    case executableNotFound
    case invalidInstallation
    case patchFailed(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return L10n.tr("找不到可用的 Claude Code 安装。")
        case .invalidInstallation:
            return L10n.tr("当前 Claude Code 安装结构无法识别。")
        case let .patchFailed(reason):
            return L10n.tr("生成 Claude Code patched runtime 失败：%@", reason)
        }
    }
}

struct ClaudePatchedRuntimeManager: @unchecked Sendable {
    private static let patchVersion = "2026-03-29-model-picker-v1"

    private struct SourceInstallation {
        let originalExecutableURL: URL
        let packageRootURL: URL
        let version: String
        let nodeCommand: String
    }

    private let fileManager: FileManager
    private let resolveClaudeExecutableURL: @Sendable () throws -> URL

    init(
        fileManager: FileManager = .default,
        resolveClaudeExecutableURL: @escaping @Sendable () throws -> URL = Self.resolveClaudeExecutableURL
    ) {
        self.fileManager = fileManager
        self.resolveClaudeExecutableURL = resolveClaudeExecutableURL
    }

    func preparePatchedRuntime(
        model: String,
        appSupportDirectoryURL: URL
    ) throws -> URL {
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedModel.isEmpty else {
            throw ClaudePatchedRuntimeManagerError.patchFailed(L10n.tr("缺少模型配置。"))
        }

        let installation = try sourceInstallation()
        let runtimeRootURL = patchedRuntimeRootURL(
            for: installation,
            model: normalizedModel,
            appSupportDirectoryURL: appSupportDirectoryURL
        )
        let wrapperURL = runtimeRootURL
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("claude", isDirectory: false)

        if fileManager.isExecutableFile(atPath: wrapperURL.path) {
            return wrapperURL
        }

        if fileManager.fileExists(atPath: runtimeRootURL.path) {
            try fileManager.removeItem(at: runtimeRootURL)
        }

        let packageDestinationURL = runtimeRootURL.appendingPathComponent("package", isDirectory: true)
        try fileManager.createDirectory(at: runtimeRootURL, withIntermediateDirectories: true)
        try fileManager.copyItem(at: installation.packageRootURL, to: packageDestinationURL)

        let patchedCLIURL = packageDestinationURL.appendingPathComponent("cli.js", isDirectory: false)
        let originalCLIContents = try String(contentsOf: patchedCLIURL, encoding: .utf8)
        let patchedCLIContents = try patchCLIContents(originalCLIContents, model: normalizedModel)
        try patchedCLIContents.write(to: patchedCLIURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: patchedCLIURL.path)

        let wrapperDirectoryURL = wrapperURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: wrapperDirectoryURL, withIntermediateDirectories: true)
        try wrapperScript(
            nodeCommand: installation.nodeCommand,
            patchedCLIURL: patchedCLIURL
        ).write(to: wrapperURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapperURL.path)

        return wrapperURL
    }

    private func sourceInstallation() throws -> SourceInstallation {
        let originalExecutableURL = try resolveClaudeExecutableURL().standardizedFileURL
        let resolvedExecutableURL = originalExecutableURL.resolvingSymlinksInPath()
        guard let packageRootURL = packageRootURL(containing: resolvedExecutableURL) else {
            throw ClaudePatchedRuntimeManagerError.invalidInstallation
        }

        let packageJSONURL = packageRootURL.appendingPathComponent("package.json", isDirectory: false)
        let packageData = try Data(contentsOf: packageJSONURL)
        guard
            let object = try JSONSerialization.jsonObject(with: packageData) as? [String: Any],
            let version = object["version"] as? String,
            !version.isEmpty
        else {
            throw ClaudePatchedRuntimeManagerError.invalidInstallation
        }

        return SourceInstallation(
            originalExecutableURL: originalExecutableURL,
            packageRootURL: packageRootURL,
            version: version,
            nodeCommand: resolvedNodeCommand(for: originalExecutableURL)
        )
    }

    private func patchedRuntimeRootURL(
        for installation: SourceInstallation,
        model: String,
        appSupportDirectoryURL: URL
    ) -> URL {
        let cacheKeyInput = "\(Self.patchVersion)\n\(installation.version)\n\(installation.packageRootURL.path)\n\(model)"
        let cacheKey = SHA256.hash(data: Data(cacheKeyInput.utf8))
            .compactMap { String(format: "%02x", $0) }
            .joined()

        return appSupportDirectoryURL
            .appendingPathComponent("claude-patched-runtimes", isDirectory: true)
            .appendingPathComponent(installation.version, isDirectory: true)
            .appendingPathComponent(cacheKey, isDirectory: true)
    }

    private func packageRootURL(containing executableURL: URL) -> URL? {
        var currentURL = executableURL.deletingLastPathComponent()

        for _ in 0..<5 {
            let cliURL = currentURL.appendingPathComponent("cli.js", isDirectory: false)
            let packageJSONURL = currentURL.appendingPathComponent("package.json", isDirectory: false)
            if fileManager.fileExists(atPath: cliURL.path), fileManager.fileExists(atPath: packageJSONURL.path) {
                return currentURL
            }
            let parentURL = currentURL.deletingLastPathComponent()
            if parentURL == currentURL {
                break
            }
            currentURL = parentURL
        }

        return nil
    }

    private func resolvedNodeCommand(for originalExecutableURL: URL) -> String {
        let siblingNodeURL = originalExecutableURL
            .deletingLastPathComponent()
            .appendingPathComponent("node", isDirectory: false)
        if fileManager.isExecutableFile(atPath: siblingNodeURL.path) {
            return siblingNodeURL.path
        }

        if let discoveredNodePath = try? Self.shellCommandPath(for: "node"), !discoveredNodePath.isEmpty {
            return discoveredNodePath
        }

        return "node"
    }

    private func patchCLIContents(_ contents: String, model: String) throws -> String {
        var patchedContents = contents
        patchedContents = try patchCustomModelValidation(in: patchedContents)
        patchedContents = try patchModelPickerOptions(in: patchedContents)
        patchedContents = try patchCustomAgentModels(in: patchedContents)
        patchedContents = patchContextLimit(in: patchedContents)
        _ = model
        return patchedContents
    }

    private func patchCustomModelValidation(in contents: String) throws -> String {
        let injectedValidation = """
        if($2&&process.env.ANTHROPIC_CUSTOM_MODEL_OPTION&&String($2).trim().toLowerCase()===process.env.ANTHROPIC_CUSTOM_MODEL_OPTION.trim().toLowerCase())return!0;
        """
        if contents.contains("process.env.ANTHROPIC_CUSTOM_MODEL_OPTION&&String(") {
            return contents
        }

        let patterns = [
            (
                try NSRegularExpression(
                    pattern: #"function\s+([$\w]+)\(([$\w]+)\)\{let\s+([$\w]+)=J7\(\)\|\|\{\},\{availableModels:([$\w]+)\}=\3;if\(!\4\)return!0;"#
                ),
                "function $1($2){\(injectedValidation)let $3=J7()||{},{availableModels:$4}=$3;if(!$4)return!0;"
            ),
            (
                try NSRegularExpression(
                    pattern: #"function\s+([$\w]+)\(([$\w]+)\)\{let\s+([$\w]+)=([$\w]+)\(\)\|\|\{availableModels:\[\]\};"#
                ),
                "function $1($2){\(injectedValidation)let $3=$4()||{availableModels:[]};"
            ),
        ]

        let range = NSRange(contents.startIndex..., in: contents)
        for (pattern, template) in patterns {
            if pattern.firstMatch(in: contents, range: range) != nil {
                return pattern.stringByReplacingMatches(
                    in: contents,
                    range: range,
                    withTemplate: template
                )
            }
        }

        throw ClaudePatchedRuntimeManagerError.patchFailed(L10n.tr("没有找到自定义模型校验入口。"))
    }

    private func patchCustomAgentModels(in contents: String) throws -> String {
        let variableEnumPattern = try NSRegularExpression(
            pattern: #",model:([$\w]+)\.enum\(([$\w]+)\)\.optional\(\)"#
        )
        let inlineEnumPattern = try NSRegularExpression(
            pattern: #",model:([$\w]+)\.enum\(\[[^\]]+\]\)\.optional\(\)"#
        )
        let alreadyPatchedPattern = try NSRegularExpression(
            pattern: #",model:([$\w]+)\.string\(\)\.optional\(\)\.describe\("Optional model override for this agent"#
        )

        if alreadyPatchedPattern.firstMatch(
            in: contents,
            range: NSRange(contents.startIndex..., in: contents)
        ) != nil {
            return contents
        }

        let variableMatch = variableEnumPattern.firstMatch(
            in: contents,
            range: NSRange(contents.startIndex..., in: contents)
        )
        let inlineMatch = inlineEnumPattern.firstMatch(
            in: contents,
            range: NSRange(contents.startIndex..., in: contents)
        )

        guard variableMatch != nil || inlineMatch != nil else {
            throw ClaudePatchedRuntimeManagerError.patchFailed(L10n.tr("没有找到 agent 模型校验补丁点。"))
        }

        var updated = variableEnumPattern.stringByReplacingMatches(
            in: contents,
            range: NSRange(contents.startIndex..., in: contents),
            withTemplate: ",model:$1.string().optional()"
        )
        updated = inlineEnumPattern.stringByReplacingMatches(
            in: updated,
            range: NSRange(updated.startIndex..., in: updated),
            withTemplate: ",model:$1.string().optional()"
        )

        guard
            let variableMatch,
            let modelListRange = Range(variableMatch.range(at: 2), in: contents)
        else {
            return updated
        }

        let modelListVar = String(contents[modelListRange])
        let validPattern = try NSRegularExpression(
            pattern: #"([;)}])let\s+([$\w]+)\s*=\s*([$\w]+)\s*&&\s*typeof\s+\3\s*===\s*"string"\s*&&\s*\#(NSRegularExpression.escapedPattern(for: modelListVar))\.includes\(\3\)"#
        )
        guard let validMatch = validPattern.firstMatch(
            in: updated,
            range: NSRange(updated.startIndex..., in: updated)
        ) else {
            return updated
        }

        let boundary = String(updated[Range(validMatch.range(at: 1), in: updated)!])
        let flagVar = String(updated[Range(validMatch.range(at: 2), in: updated)!])
        let modelVar = String(updated[Range(validMatch.range(at: 3), in: updated)!])
        return updated.replacingCharacters(
            in: Range(validMatch.range, in: updated)!,
            with: "\(boundary)let \(flagVar)=\(modelVar)&&typeof \(modelVar)===\"string\""
        )
    }

    private func patchModelPickerOptions(in contents: String) throws -> String {
        if contents.contains("__managedAvailableModels") {
            return contents
        }

        let pattern = try NSRegularExpression(
            pattern: #"function\s+([$\w]+)\(([$\w]+)\)\{if\(!\(([$\w]+)\(\)\|\|\{\}\)\.availableModels\)return\s+\2;return\s+\2\.filter\(\(([$\w]+)\)=>\4\.value===null\|\|\4\.value!==null&&([$\w]+)\(\4\.value\)\)\}"#
        )
        let range = NSRange(contents.startIndex..., in: contents)
        guard pattern.firstMatch(in: contents, range: range) != nil else {
            throw ClaudePatchedRuntimeManagerError.patchFailed(L10n.tr("没有找到模型菜单补丁点。"))
        }

        return pattern.stringByReplacingMatches(
            in: contents,
            range: range,
            withTemplate: #"function $1($2){let __managedAvailableModels=($3()||{}).availableModels;if(!__managedAvailableModels)return $2;for(let __managedModel of __managedAvailableModels)if(__managedModel&&!$2.some((__managedOption)=>__managedOption.value===__managedModel)){let __managedResolvedOption=typeof _8z==="function"?_8z(__managedModel):null;$2.push(__managedResolvedOption??{value:__managedModel,label:__managedModel,description:"Custom model"})}return $2.filter(($4)=>$4.value===null||$4.value!==null&&$5($4.value))}"#
        )
    }

    private func patchContextLimit(in contents: String) -> String {
        if contents.contains("CLAUDE_CODE_CONTEXT_LIMIT") {
            return contents
        }

        guard let pattern = try? NSRegularExpression(pattern: #"var\s+([$\w]+)=200000,([$\w]+)=20000"#) else {
            return contents
        }
        let range = NSRange(contents.startIndex..., in: contents)
        guard pattern.firstMatch(in: contents, range: range) != nil else {
            return contents
        }

        return pattern.stringByReplacingMatches(
            in: contents,
            range: range,
            withTemplate: "var $1=(+process.env.CLAUDE_CODE_CONTEXT_LIMIT||200000),$2=20000"
        )
    }

    private func wrapperScript(nodeCommand: String, patchedCLIURL: URL) -> String {
        """
        #!/bin/sh
        exec \(shellQuoted(nodeCommand)) \(shellQuoted(patchedCLIURL.path)) "$@"
        """
    }

    private func shellQuoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func resolveClaudeExecutableURL() throws -> URL {
        let homeLocalExecutableURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("claude", isDirectory: false)
        if FileManager.default.isExecutableFile(atPath: homeLocalExecutableURL.path) {
            return homeLocalExecutableURL
        }

        guard let executablePath = try? shellCommandPath(for: "claude"), !executablePath.isEmpty else {
            throw ClaudePatchedRuntimeManagerError.executableNotFound
        }

        return URL(fileURLWithPath: executablePath, isDirectory: false)
    }

    private static func shellCommandPath(for command: String) throws -> String {
        let process = Process()
        let pipe = Pipe()
        let shellPath = ProcessInfo.processInfo.environment["SHELL"].flatMap {
            FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil
        } ?? "/bin/zsh"
        process.executableURL = URL(fileURLWithPath: shellPath, isDirectory: false)
        process.arguments = ["-lic", "command -v \(command)"]
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ClaudePatchedRuntimeManagerError.executableNotFound
        }

        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

extension ClaudePatchedRuntimeManager: ClaudePatchedRuntimeManaging {}
