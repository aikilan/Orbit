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
        let availableModels: [String]?
    }

    private let fileManager: FileManager
    private let session: URLSession

    init(fileManager: FileManager = .default, session: URLSession = .shared) {
        self.fileManager = fileManager
        self.session = session
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
                    modelCatalogSnapshot: nil,
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
                modelCatalogSnapshot: nil,
                configFileContents: nil,
                environmentVariables: [:],
                arguments: []
            )
        case .openAICompatible:
            guard let credential = providerAPIKeyCredential else {
                throw CLIEnvironmentResolverError.missingProviderCredential
            }
            let provider = try resolvedProviderConfig(for: account)
            let shouldManageModelCatalog = shouldManageCodexModelCatalog(
                for: account,
                providerIdentifier: provider.identifier
            )
            let availableModels = shouldManageModelCatalog || !account.supportsResponsesAPI
                ? await availableModelsForBridge(
                    account: account,
                    providerBaseURL: provider.baseURL,
                    apiKey: credential.apiKey
                )
                : []
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
                    model: account.resolvedDefaultModel,
                    availableModels: availableModels
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
                modelCatalogSnapshot: shouldManageModelCatalog
                    ? ResolvedCodexModelCatalogSnapshot(availableModels: availableModels)
                    : nil,
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
            let availableModels = await availableModelsForBridge(
                account: account,
                providerBaseURL: provider.baseURL,
                apiKey: credential.apiKey
            )
            let bridge = try await claudeProviderCodexBridgeManager.prepareBridge(
                accountID: account.id,
                baseURL: provider.baseURL,
                apiKeyEnvName: provider.apiKeyEnvName,
                apiKey: credential.apiKey,
                model: account.resolvedDefaultModel,
                availableModels: availableModels
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
                modelCatalogSnapshot: ResolvedCodexModelCatalogSnapshot(availableModels: availableModels),
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
            let runtimeBaseURL = normalizedMiniMaxAnthropicBaseURL(provider.baseURL, includeVersion: false) ?? provider.baseURL
            let rootURL = managedClaudeRootURL(
                for: account.id,
                target: .claude,
                appSupportDirectoryURL: appPaths.appSupportDirectoryURL
            )
            let resolvedProvider = ClaudeResolvedProvider(
                source: .explicitProvider,
                model: account.resolvedDefaultModel,
                modelProvider: nil,
                baseURL: runtimeBaseURL,
                apiKeyEnvName: provider.apiKeyEnvName,
                apiKey: providerCredential.apiKey,
                availableModels: nil
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
                    apiKeyEnvName: resolvedProvider.apiKeyEnvName,
                    availableModels: resolvedProvider.availableModels
                ),
                environmentVariables: claudeProviderEnvironmentVariables(for: resolvedProvider),
                arguments: ["--model", resolvedProvider.model]
            )
        case .chatgptOAuth:
            guard let codexAuthPayload else {
                throw CLIEnvironmentResolverError.missingCodexPayload
            }
            let model = account.resolvedDefaultModel.isEmpty ? "gpt-5.4" : account.resolvedDefaultModel
            let availableModels = codexOAuthBridgeAvailableModels(defaultModel: model)
            let bridge = try await codexOAuthClaudeBridgeManager.prepareBridge(
                accountID: account.id,
                source: .codexAuthPayload(codexAuthPayload),
                model: model,
                availableModels: availableModels
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
                    apiKey: bridge.apiKey,
                    availableModels: availableModels
                )
            )
        case .openAICompatible:
            guard let providerCredential = credential?.providerAPIKeyCredential else {
                throw CLIEnvironmentResolverError.missingProviderCredential
            }
            let provider = try resolvedProviderConfig(for: account)
            let availableModels = await availableModelsForBridge(
                account: account,
                providerBaseURL: provider.baseURL,
                apiKey: providerCredential.apiKey
            )
            let bridge = try await codexOAuthClaudeBridgeManager.prepareBridge(
                accountID: account.id,
                source: .provider(
                    baseURL: provider.baseURL,
                    apiKeyEnvName: provider.apiKeyEnvName,
                    apiKey: providerCredential.apiKey,
                    supportsResponsesAPI: account.supportsResponsesAPI
                ),
                model: account.resolvedDefaultModel,
                availableModels: availableModels
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
                    apiKey: bridge.apiKey,
                    availableModels: availableModels
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
                apiKeyEnvName: provider.apiKeyEnvName,
                availableModels: provider.availableModels
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
        let usesMiniMaxAuthToken = normalizedMiniMaxAnthropicBaseURL(provider.baseURL, includeVersion: false) != nil
        let primaryEnvName = usesMiniMaxAuthToken ? "ANTHROPIC_AUTH_TOKEN" : "ANTHROPIC_API_KEY"

        var variables = [primaryEnvName: provider.apiKey]
        if provider.apiKeyEnvName != primaryEnvName,
           !(usesMiniMaxAuthToken && provider.apiKeyEnvName == "ANTHROPIC_API_KEY")
        {
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

    private func availableModelsForBridge(
        account: ManagedAccount,
        providerBaseURL: String,
        apiKey: String
    ) async -> [String] {
        let fallbackModels = fallbackAvailableModels(defaultModel: account.resolvedDefaultModel)
        guard shouldPrefetchModels(for: account) else {
            return fallbackModels
        }

        do {
            let modelIDs = try await fetchModelIDs(
                for: account.providerRule,
                baseURL: providerBaseURL,
                apiKey: apiKey
            )
            return mergedAvailableModels(modelIDs, defaultModel: account.resolvedDefaultModel)
        } catch {
            return fallbackModels
        }
    }

    private func shouldPrefetchModels(for account: ManagedAccount) -> Bool {
        guard
            let presetID = account.providerPresetID?.trimmingCharacters(in: .whitespacesAndNewlines),
            !presetID.isEmpty,
            let preset = ProviderCatalog.preset(id: presetID)
        else {
            return false
        }

        return !preset.isCustom
    }

    private func shouldManageCodexModelCatalog(
        for account: ManagedAccount,
        providerIdentifier: String
    ) -> Bool {
        switch account.providerRule {
        case .chatgptOAuth, .claudeProfile:
            return false
        case .claudeCompatible:
            return true
        case .openAICompatible:
            return providerIdentifier != "openai"
        }
    }

    private func codexOAuthBridgeAvailableModels(defaultModel: String) -> [String] {
        mergedAvailableModels(
            [
                "gpt-5.3-codex",
                "gpt-5.4",
                "gpt-5.2-codex",
                "gpt-5.1-codex-max",
                "gpt-5.2",
                "gpt-5.1-codex-mini",
            ],
            defaultModel: defaultModel
        )
    }

    private func fetchModelIDs(
        for rule: ProviderRule,
        baseURL: String,
        apiKey: String
    ) async throws -> [String] {
        switch rule {
        case .openAICompatible:
            return try await fetchOpenAICompatibleModelIDs(baseURL: baseURL, apiKey: apiKey)
        case .claudeCompatible:
            return try await fetchClaudeCompatibleModelIDs(baseURL: baseURL, apiKey: apiKey)
        case .chatgptOAuth, .claudeProfile:
            return []
        }
    }

    private func fetchOpenAICompatibleModelIDs(baseURL: String, apiKey: String) async throws -> [String] {
        let normalizedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let url = try validURL("\(normalizedBaseURL)/models")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        try validateModelListResponse(response, data: data)
        return parseModelIDs(from: data)
    }

    private func fetchClaudeCompatibleModelIDs(baseURL: String, apiKey: String) async throws -> [String] {
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestURL: URL

        if let minimaxBaseURL = normalizedMiniMaxAnthropicBaseURL(trimmedBaseURL, includeVersion: true) {
            requestURL = try validURL("\(minimaxBaseURL)/models")
        } else {
            let normalizedBaseURL = trimmedBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            requestURL = try validURL("\(normalizedBaseURL)/models")
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        if normalizedMiniMaxAnthropicBaseURL(trimmedBaseURL, includeVersion: false) != nil {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        } else {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }

        let (data, response) = try await session.data(for: request)
        try validateModelListResponse(response, data: data)
        return parseModelIDs(from: data)
    }

    private func validateModelListResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw NSError(
                domain: "CLIEnvironmentResolver",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? ""]
            )
        }
    }

    private func parseModelIDs(from data: Data) -> [String] {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawModels = object["data"] as? [[String: Any]]
        else {
            return []
        }

        return rawModels.compactMap { model in
            let trimmedID = (model["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmedID.isEmpty ? nil : trimmedID
        }
    }

    private func fallbackAvailableModels(defaultModel: String) -> [String] {
        let trimmedModel = defaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedModel.isEmpty ? [] : [trimmedModel]
    }

    private func mergedAvailableModels(_ models: [String], defaultModel: String) -> [String] {
        var normalized = [String]()
        var seen = Set<String>()

        for model in models {
            let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedModel.isEmpty, seen.insert(trimmedModel).inserted else { continue }
            normalized.append(trimmedModel)
        }

        let trimmedDefaultModel = defaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDefaultModel.isEmpty, seen.insert(trimmedDefaultModel).inserted {
            normalized.append(trimmedDefaultModel)
        }

        return normalized
    }

    private func validURL(_ value: String) throws -> URL {
        guard let url = URL(string: value) else {
            throw CLIEnvironmentResolverError.invalidProviderConfiguration
        }
        return url
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
