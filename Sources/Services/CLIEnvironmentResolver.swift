import Foundation

enum CLIEnvironmentResolverError: LocalizedError, Equatable {
    case missingCodexPayload
    case missingProviderCredential
    case missingClaudeCredential
    case invalidProviderConfiguration
    case codexCLINotSupported
    case providerResponsesAPINotSupported

    var errorDescription: String? {
        switch self {
        case .missingCodexPayload:
            return L10n.tr("当前账号缺少可用的 Codex 凭据。")
        case .missingProviderCredential:
            return L10n.tr("当前账号缺少可用的 Provider API Key。")
        case .missingClaudeCredential:
            return L10n.tr("当前账号缺少可用的 Claude 凭据。")
        case .invalidProviderConfiguration:
            return L10n.tr("当前账号的供应商配置不完整。")
        case .codexCLINotSupported:
            return L10n.tr("当前账号不支持打开 Codex CLI。")
        case .providerResponsesAPINotSupported:
            return L10n.tr("当前供应商不支持 OpenAI Responses API，无法用于启动 Codex CLI 或 Claude Code。")
        }
    }
}

struct CLIEnvironmentResolver: @unchecked Sendable {
    private struct ClaudeResolvedProvider {
        let source: ClaudeProviderSource
        let model: String
        let modelProvider: String?
        let baseURL: String
        let apiKeyEnvName: String
        let apiKey: String
    }

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func resolveCodexContext(
        for account: ManagedAccount,
        workingDirectoryURL: URL,
        appPaths: AppPaths,
        authPayload: CodexAuthPayload?,
        providerAPIKeyCredential: ProviderAPIKeyCredential?,
        openAICompatibleProviderCodexBridgeManager: any OpenAICompatibleProviderCodexBridgeManaging,
        claudeProviderCodexBridgeManager: any ClaudeProviderCodexBridgeManaging
    ) async throws -> ResolvedCodexCLILaunchContext {
        switch account.providerRule {
        case .chatgptOAuth:
            guard let authPayload else {
                throw CLIEnvironmentResolverError.missingCodexPayload
            }
            if account.isActive {
                return ResolvedCodexCLILaunchContext(
                    accountID: account.id,
                    workingDirectoryURL: workingDirectoryURL,
                    mode: .globalCurrentAuth,
                    codexHomeURL: nil,
                    authPayload: nil,
                    configFileContents: nil,
                    environmentVariables: [:],
                    arguments: []
                )
            }

            let codexHomeURL = isolatedCodexHomeURL(
                for: account.id,
                target: .codex,
                appSupportDirectoryURL: appPaths.appSupportDirectoryURL
            )
            return ResolvedCodexCLILaunchContext(
                accountID: account.id,
                workingDirectoryURL: workingDirectoryURL,
                mode: .isolated,
                codexHomeURL: codexHomeURL,
                authPayload: authPayload,
                configFileContents: nil,
                environmentVariables: [:],
                arguments: []
            )
        case .openAICompatible:
            guard let credential = providerAPIKeyCredential else {
                throw CLIEnvironmentResolverError.missingProviderCredential
            }
            let provider = try resolvedProviderConfig(for: account)
            let resolvedProvider: (baseURL: String, apiKeyEnvName: String, apiKey: String)
            if account.supportsResponsesAPI {
                resolvedProvider = (
                    baseURL: provider.baseURL,
                    apiKeyEnvName: provider.apiKeyEnvName,
                    apiKey: credential.apiKey
                )
            } else {
                let bridge = try await openAICompatibleProviderCodexBridgeManager.prepareBridge(
                    accountID: account.id,
                    baseURL: provider.baseURL,
                    apiKeyEnvName: provider.apiKeyEnvName,
                    apiKey: credential.apiKey,
                    model: account.resolvedDefaultModel
                )
                resolvedProvider = (
                    baseURL: bridge.baseURL,
                    apiKeyEnvName: bridge.apiKeyEnvName,
                    apiKey: bridge.apiKey
                )
            }
            let codexHomeURL = isolatedCodexHomeURL(
                for: account.id,
                target: .codex,
                appSupportDirectoryURL: appPaths.appSupportDirectoryURL
            )
            return ResolvedCodexCLILaunchContext(
                accountID: account.id,
                workingDirectoryURL: workingDirectoryURL,
                mode: .isolated,
                codexHomeURL: codexHomeURL,
                authPayload: nil,
                configFileContents: codexConfigContents(
                    model: account.resolvedDefaultModel,
                    modelProvider: provider.identifier,
                    providerIdentifier: provider.identifier,
                    providerDisplayName: provider.displayName,
                    baseURL: resolvedProvider.baseURL,
                    envKey: resolvedProvider.apiKeyEnvName
                ),
                environmentVariables: [resolvedProvider.apiKeyEnvName: resolvedProvider.apiKey],
                arguments: []
            )
        case .claudeCompatible:
            guard account.supportsCodexCLI else {
                throw CLIEnvironmentResolverError.codexCLINotSupported
            }
            guard let credential = providerAPIKeyCredential else {
                throw CLIEnvironmentResolverError.missingProviderCredential
            }
            let provider = try resolvedProviderConfig(for: account)
            let bridge = try await claudeProviderCodexBridgeManager.prepareBridge(
                accountID: account.id,
                baseURL: provider.baseURL,
                apiKeyEnvName: provider.apiKeyEnvName,
                apiKey: credential.apiKey,
                model: account.resolvedDefaultModel
            )
            let codexHomeURL = isolatedCodexHomeURL(
                for: account.id,
                target: .codex,
                appSupportDirectoryURL: appPaths.appSupportDirectoryURL
            )
            return ResolvedCodexCLILaunchContext(
                accountID: account.id,
                workingDirectoryURL: workingDirectoryURL,
                mode: .isolated,
                codexHomeURL: codexHomeURL,
                authPayload: nil,
                configFileContents: codexConfigContents(
                    model: account.resolvedDefaultModel,
                    modelProvider: provider.identifier,
                    providerIdentifier: provider.identifier,
                    providerDisplayName: provider.displayName,
                    baseURL: bridge.baseURL,
                    envKey: bridge.apiKeyEnvName
                ),
                environmentVariables: [bridge.apiKeyEnvName: bridge.apiKey],
                arguments: []
            )
        case .claudeProfile:
            throw CLIEnvironmentResolverError.codexCLINotSupported
        }
    }

    func resolveClaudeContext(
        for account: ManagedAccount,
        workingDirectoryURL: URL,
        appPaths: AppPaths,
        codexAuthPayload: CodexAuthPayload?,
        credential: StoredCredential?,
        claudeProfileManager: any ClaudeProfileManaging,
        claudePatchedRuntimeManager: any ClaudePatchedRuntimeManaging,
        codexOAuthClaudeBridgeManager: any CodexOAuthClaudeBridgeManaging
    ) async throws -> ResolvedClaudeCLILaunchContext {
        switch account.providerRule {
        case .claudeProfile:
            let rootURL = try claudeAccountRootURL(
                for: account,
                credential: credential,
                claudeProfileManager: claudeProfileManager
            )
            return ResolvedClaudeCLILaunchContext(
                accountID: account.id,
                workingDirectoryURL: workingDirectoryURL,
                rootURL: rootURL,
                configDirectoryURL: rootURL?.appendingPathComponent(".claude", isDirectory: true),
                patchedExecutableURL: nil,
                providerSnapshot: nil,
                environmentVariables: [:],
                arguments: []
            )
        case .claudeCompatible:
            guard let providerCredential = credential?.providerAPIKeyCredential ?? credential?.anthropicAPIKeyCredential.map({ ProviderAPIKeyCredential(apiKey: $0.apiKey) }) else {
                throw CLIEnvironmentResolverError.missingProviderCredential
            }
            let provider = try resolvedProviderConfig(for: account)
            let rootURL = managedClaudeRootURL(
                for: account.id,
                target: .claude,
                appSupportDirectoryURL: appPaths.appSupportDirectoryURL
            )
            let resolvedProvider = ClaudeResolvedProvider(
                source: .explicitProvider,
                model: account.resolvedDefaultModel,
                modelProvider: nil,
                baseURL: provider.baseURL,
                apiKeyEnvName: provider.apiKeyEnvName,
                apiKey: providerCredential.apiKey
            )
            return ResolvedClaudeCLILaunchContext(
                accountID: account.id,
                workingDirectoryURL: workingDirectoryURL,
                rootURL: rootURL,
                configDirectoryURL: rootURL.appendingPathComponent(".claude", isDirectory: true),
                patchedExecutableURL: try claudePatchedRuntimeManager.preparePatchedRuntime(
                    model: resolvedProvider.model,
                    appSupportDirectoryURL: appPaths.appSupportDirectoryURL
                ),
                providerSnapshot: ResolvedClaudeProviderSnapshot(
                    source: resolvedProvider.source,
                    model: resolvedProvider.model,
                    modelProvider: resolvedProvider.modelProvider,
                    baseURL: resolvedProvider.baseURL,
                    apiKeyEnvName: resolvedProvider.apiKeyEnvName
                ),
                environmentVariables: claudeProviderEnvironmentVariables(for: resolvedProvider),
                arguments: ["--model", resolvedProvider.model]
            )
        case .chatgptOAuth:
            guard let codexAuthPayload else {
                throw CLIEnvironmentResolverError.missingCodexPayload
            }
            let model = account.resolvedDefaultModel.isEmpty ? "gpt-5.4" : account.resolvedDefaultModel
            let bridge = try await codexOAuthClaudeBridgeManager.prepareBridge(
                accountID: account.id,
                source: .codexAuthPayload(codexAuthPayload),
                model: model
            )
            return try resolvedBridgedClaudeContext(
                for: account,
                workingDirectoryURL: workingDirectoryURL,
                appPaths: appPaths,
                claudePatchedRuntimeManager: claudePatchedRuntimeManager,
                provider: ClaudeResolvedProvider(
                    source: .inheritCodexEnvironment,
                    model: model,
                    modelProvider: nil,
                    baseURL: bridge.baseURL,
                    apiKeyEnvName: bridge.apiKeyEnvName,
                    apiKey: bridge.apiKey
                )
            )
        case .openAICompatible:
            guard let providerCredential = credential?.providerAPIKeyCredential else {
                throw CLIEnvironmentResolverError.missingProviderCredential
            }
            let provider = try resolvedProviderConfig(for: account)
            let bridge = try await codexOAuthClaudeBridgeManager.prepareBridge(
                accountID: account.id,
                source: .provider(
                    baseURL: provider.baseURL,
                    apiKeyEnvName: provider.apiKeyEnvName,
                    apiKey: providerCredential.apiKey,
                    supportsResponsesAPI: account.supportsResponsesAPI
                ),
                model: account.resolvedDefaultModel
            )
            return try resolvedBridgedClaudeContext(
                for: account,
                workingDirectoryURL: workingDirectoryURL,
                appPaths: appPaths,
                claudePatchedRuntimeManager: claudePatchedRuntimeManager,
                provider: ClaudeResolvedProvider(
                    source: .inheritCodexEnvironment,
                    model: account.resolvedDefaultModel,
                    modelProvider: provider.identifier,
                    baseURL: bridge.baseURL,
                    apiKeyEnvName: bridge.apiKeyEnvName,
                    apiKey: bridge.apiKey
                )
            )
        }
    }

    private func resolvedBridgedClaudeContext(
        for account: ManagedAccount,
        workingDirectoryURL: URL,
        appPaths: AppPaths,
        claudePatchedRuntimeManager: any ClaudePatchedRuntimeManaging,
        provider: ClaudeResolvedProvider
    ) throws -> ResolvedClaudeCLILaunchContext {
        let rootURL = managedClaudeRootURL(
            for: account.id,
            target: .claude,
            appSupportDirectoryURL: appPaths.appSupportDirectoryURL
        )
        return ResolvedClaudeCLILaunchContext(
            accountID: account.id,
            workingDirectoryURL: workingDirectoryURL,
            rootURL: rootURL,
            configDirectoryURL: rootURL.appendingPathComponent(".claude", isDirectory: true),
            patchedExecutableURL: try claudePatchedRuntimeManager.preparePatchedRuntime(
                model: provider.model,
                appSupportDirectoryURL: appPaths.appSupportDirectoryURL
            ),
            providerSnapshot: ResolvedClaudeProviderSnapshot(
                source: provider.source,
                model: provider.model,
                modelProvider: provider.modelProvider,
                baseURL: provider.baseURL,
                apiKeyEnvName: provider.apiKeyEnvName
            ),
            environmentVariables: claudeProviderEnvironmentVariables(for: provider),
            arguments: ["--model", provider.model]
        )
    }

    private func claudeAccountRootURL(
        for account: ManagedAccount,
        credential: StoredCredential?,
        claudeProfileManager: any ClaudeProfileManaging
    ) throws -> URL? {
        guard let credential else {
            throw CLIEnvironmentResolverError.missingClaudeCredential
        }
        switch credential {
        case let .claudeProfile(snapshotRef):
            if account.isActive {
                return nil
            }
            return try claudeProfileManager.prepareIsolatedProfileRoot(for: account.id, snapshotRef: snapshotRef)
        case .anthropicAPIKey(_), .providerAPIKey(_):
            return try claudeProfileManager.prepareIsolatedAPIKeyRoot(for: account.id)
        case .codex:
            throw CLIEnvironmentResolverError.missingClaudeCredential
        }
    }

    private func claudeProviderEnvironmentVariables(
        for provider: ClaudeResolvedProvider
    ) -> [String: String] {
        var variables = ["ANTHROPIC_API_KEY": provider.apiKey]
        if provider.apiKeyEnvName != "ANTHROPIC_API_KEY" {
            variables[provider.apiKeyEnvName] = provider.apiKey
        }
        variables["ANTHROPIC_BASE_URL"] = provider.baseURL
        variables["ANTHROPIC_MODEL"] = provider.model
        variables["ANTHROPIC_CUSTOM_MODEL_OPTION"] = provider.model
        variables["ANTHROPIC_CUSTOM_MODEL_OPTION_NAME"] = provider.model
        variables["ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION"] = provider.model
        variables["CLAUDE_CODE_SUBAGENT_MODEL"] = provider.model
        return variables
    }

    private func resolvedProviderConfig(for account: ManagedAccount) throws -> (identifier: String, displayName: String, baseURL: String, apiKeyEnvName: String) {
        let displayName = account.resolvedProviderDisplayName
        let identifier = providerIdentifier(for: account)
        let baseURL = account.resolvedProviderBaseURL
        let apiKeyEnvName = account.resolvedProviderAPIKeyEnvName

        guard !identifier.isEmpty, !displayName.isEmpty, !baseURL.isEmpty, !apiKeyEnvName.isEmpty else {
            throw CLIEnvironmentResolverError.invalidProviderConfiguration
        }
        return (identifier, displayName, baseURL, apiKeyEnvName)
    }

    private func providerIdentifier(for account: ManagedAccount) -> String {
        if let presetID = account.providerPresetID?.trimmingCharacters(in: .whitespacesAndNewlines), !presetID.isEmpty, presetID != ProviderCatalog.customPresetID {
            return presetID
        }
        let source = account.resolvedProviderDisplayName
        let lowered = source.lowercased()
        let sanitized = lowered.unicodeScalars.map { scalar -> Character in
            switch scalar {
            case "a"..."z", "0"..."9":
                return Character(scalar)
            default:
                return "-"
            }
        }
        let identifier = String(sanitized)
            .replacingOccurrences(of: "--", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return identifier.isEmpty ? "custom-provider" : identifier
    }

    private func codexConfigContents(
        model: String,
        modelProvider: String,
        providerIdentifier: String,
        providerDisplayName: String,
        baseURL: String,
        envKey: String
    ) -> String {
        var lines = [String]()
        if !model.isEmpty {
            lines.append("model = \"\(tomlEscaped(model))\"")
        }
        if !modelProvider.isEmpty {
            lines.append("model_provider = \"\(tomlEscaped(modelProvider))\"")
        }
        lines.append("")
        lines.append("[model_providers.\(providerIdentifier)]")
        lines.append("name = \"\(tomlEscaped(providerDisplayName))\"")
        lines.append("base_url = \"\(tomlEscaped(baseURL))\"")
        lines.append("env_key = \"\(tomlEscaped(envKey))\"")
        lines.append("wire_api = \"responses\"")
        return lines.joined(separator: "\n") + "\n"
    }

    private func isolatedCodexHomeURL(
        for accountID: UUID,
        target: CLIEnvironmentTarget,
        appSupportDirectoryURL: URL
    ) -> URL {
        appSupportDirectoryURL
            .appendingPathComponent("account-cli", isDirectory: true)
            .appendingPathComponent(target.rawValue, isDirectory: true)
            .appendingPathComponent(accountID.uuidString, isDirectory: true)
            .appendingPathComponent("codex-home", isDirectory: true)
    }

    private func managedClaudeRootURL(
        for accountID: UUID,
        target: CLIEnvironmentTarget,
        appSupportDirectoryURL: URL
    ) -> URL {
        appSupportDirectoryURL
            .appendingPathComponent("account-cli", isDirectory: true)
            .appendingPathComponent(target.rawValue, isDirectory: true)
            .appendingPathComponent(accountID.uuidString, isDirectory: true)
            .appendingPathComponent("root", isDirectory: true)
    }

    private func tomlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

extension CLIEnvironmentResolver: CLIEnvironmentResolving {}
