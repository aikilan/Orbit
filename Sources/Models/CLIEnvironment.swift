import Foundation

enum CLIEnvironmentTarget: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex
    case claude

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex:
            return "Codex CLI"
        case .claude:
            return "Claude Code"
        }
    }

    var defaultProfileID: String {
        switch self {
        case .codex:
            return CLIEnvironmentProfile.builtInCodexProfileID
        case .claude:
            return CLIEnvironmentProfile.builtInClaudeProfileID
        }
    }
}

enum CodexProviderWireAPI: String, Codable, CaseIterable, Sendable {
    case responses
}

struct CodexCustomProviderConfig: Codable, Equatable, Hashable, Sendable {
    var identifier: String
    var displayName: String
    var baseURL: String
    var envKey: String
    var apiKey: String
    var wireAPI: CodexProviderWireAPI

    init(
        identifier: String = "",
        displayName: String = "",
        baseURL: String = "",
        envKey: String = "",
        apiKey: String = "",
        wireAPI: CodexProviderWireAPI = .responses
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.baseURL = baseURL
        self.envKey = envKey
        self.apiKey = apiKey
        self.wireAPI = wireAPI
    }

    var trimmedIdentifier: String {
        identifier.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedDisplayName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedBaseURL: String {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedEnvKey: String {
        envKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedAPIKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isEffectivelyEmpty: Bool {
        trimmedIdentifier.isEmpty
            && trimmedDisplayName.isEmpty
            && trimmedBaseURL.isEmpty
            && trimmedEnvKey.isEmpty
            && trimmedAPIKey.isEmpty
    }

    var resolvedIdentifier: String {
        if !trimmedIdentifier.isEmpty {
            return trimmedIdentifier
        }
        return trimmedDisplayName
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
    }

    var resolvedDisplayName: String {
        if !trimmedDisplayName.isEmpty {
            return trimmedDisplayName
        }
        return resolvedIdentifier
    }
}

struct CodexCLIEnvironmentConfiguration: Codable, Equatable, Hashable, Sendable {
    var model: String
    var modelProvider: String
    var useAccountCredentials: Bool
    var customProvider: CodexCustomProviderConfig?

    init(
        model: String = "",
        modelProvider: String = "",
        useAccountCredentials: Bool = true,
        customProvider: CodexCustomProviderConfig? = nil
    ) {
        self.model = model
        self.modelProvider = modelProvider
        self.useAccountCredentials = useAccountCredentials
        self.customProvider = customProvider
    }

    var trimmedModel: String {
        model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedModelProvider: String {
        modelProvider.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedCustomProvider: CodexCustomProviderConfig? {
        guard let customProvider, !customProvider.isEffectivelyEmpty else { return nil }
        return customProvider
    }

    var resolvedModelProvider: String {
        if !trimmedModelProvider.isEmpty {
            return trimmedModelProvider
        }
        if let normalizedCustomProvider {
            return normalizedCustomProvider.resolvedIdentifier
        }
        return ""
    }

    var requiresConfigFile: Bool {
        !trimmedModel.isEmpty || !resolvedModelProvider.isEmpty || normalizedCustomProvider != nil
    }

    var summary: String {
        let parts = [trimmedModel.isEmpty ? nil : trimmedModel,
                     resolvedModelProvider.isEmpty ? nil : resolvedModelProvider]
            .compactMap { $0 }
        return parts.isEmpty ? L10n.tr("系统默认") : parts.joined(separator: " · ")
    }
}

enum ClaudeProviderSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case accountCredentials
    case explicitProvider
    case inheritCodexEnvironment

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .accountCredentials:
            return L10n.tr("Claude 凭据")
        case .explicitProvider:
            return L10n.tr("显式供应商")
        case .inheritCodexEnvironment:
            return L10n.tr("继承 Codex 环境")
        }
    }
}

struct ClaudeCLIEnvironmentConfiguration: Codable, Equatable, Hashable, Sendable {
    var providerSource: ClaudeProviderSource
    var linkedCodexEnvironmentID: String?
    var model: String
    var providerBaseURL: String
    var apiKeyEnvName: String
    var apiKey: String
    var contextLimit: Int?

    init(
        providerSource: ClaudeProviderSource = .accountCredentials,
        linkedCodexEnvironmentID: String? = nil,
        model: String = "",
        providerBaseURL: String = "",
        apiKeyEnvName: String = "ANTHROPIC_API_KEY",
        apiKey: String = "",
        contextLimit: Int? = nil
    ) {
        self.providerSource = providerSource
        self.linkedCodexEnvironmentID = linkedCodexEnvironmentID
        self.model = model
        self.providerBaseURL = providerBaseURL
        self.apiKeyEnvName = apiKeyEnvName
        self.apiKey = apiKey
        self.contextLimit = contextLimit
    }

    private enum CodingKeys: String, CodingKey {
        case providerSource
        case linkedCodexEnvironmentID
        case model
        case providerBaseURL
        case apiKeyEnvName
        case apiKey
        case contextLimit
        case useAccountCredentials
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerSource = try container.decodeIfPresent(ClaudeProviderSource.self, forKey: .providerSource)
            ?? ((try container.decodeIfPresent(Bool.self, forKey: .useAccountCredentials)) ?? true
                ? .accountCredentials
                : .explicitProvider)
        linkedCodexEnvironmentID = try container.decodeIfPresent(String.self, forKey: .linkedCodexEnvironmentID)
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
        providerBaseURL = try container.decodeIfPresent(String.self, forKey: .providerBaseURL) ?? ""
        apiKeyEnvName = try container.decodeIfPresent(String.self, forKey: .apiKeyEnvName) ?? "ANTHROPIC_API_KEY"
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        contextLimit = try container.decodeIfPresent(Int.self, forKey: .contextLimit)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(providerSource, forKey: .providerSource)
        try container.encodeIfPresent(linkedCodexEnvironmentID, forKey: .linkedCodexEnvironmentID)
        try container.encode(model, forKey: .model)
        try container.encode(providerBaseURL, forKey: .providerBaseURL)
        try container.encode(apiKeyEnvName, forKey: .apiKeyEnvName)
        try container.encode(apiKey, forKey: .apiKey)
        try container.encodeIfPresent(contextLimit, forKey: .contextLimit)
    }

    var trimmedModel: String {
        model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedLinkedCodexEnvironmentID: String? {
        let trimmed = linkedCodexEnvironmentID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    var trimmedProviderBaseURL: String {
        providerBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedAPIKeyEnvName: String {
        let value = apiKeyEnvName.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "ANTHROPIC_API_KEY" : value
    }

    var trimmedAPIKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var usesAccountCredentials: Bool {
        providerSource == .accountCredentials
    }

    var requiresPatchedRuntime: Bool {
        providerSource != .accountCredentials
    }

    var summary: String {
        switch providerSource {
        case .accountCredentials:
            return ClaudeProviderSource.accountCredentials.displayName
        case .explicitProvider:
            var parts = [String]()
            if !trimmedModel.isEmpty {
                parts.append(trimmedModel)
            }
            if !trimmedProviderBaseURL.isEmpty {
                parts.append(trimmedProviderBaseURL)
            }
            return parts.isEmpty ? ClaudeProviderSource.explicitProvider.displayName : parts.joined(separator: " · ")
        case .inheritCodexEnvironment:
            return ClaudeProviderSource.inheritCodexEnvironment.displayName
        }
    }
}

struct CLIEnvironmentProfile: Codable, Equatable, Hashable, Identifiable, Sendable {
    static let builtInCodexProfileID = "builtin.codex.default"
    static let builtInClaudeProfileID = "builtin.claude.default"

    var id: String
    var displayName: String
    var target: CLIEnvironmentTarget
    var isBuiltIn: Bool
    var codex: CodexCLIEnvironmentConfiguration?
    var claude: ClaudeCLIEnvironmentConfiguration?

    init(
        id: String = UUID().uuidString,
        displayName: String,
        target: CLIEnvironmentTarget,
        isBuiltIn: Bool = false,
        codex: CodexCLIEnvironmentConfiguration? = nil,
        claude: ClaudeCLIEnvironmentConfiguration? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.target = target
        self.isBuiltIn = isBuiltIn
        self.codex = codex
        self.claude = claude
    }

    var resolvedCodex: CodexCLIEnvironmentConfiguration {
        codex ?? CodexCLIEnvironmentConfiguration()
    }

    var resolvedClaude: ClaudeCLIEnvironmentConfiguration {
        claude ?? ClaudeCLIEnvironmentConfiguration()
    }

    var launchSummary: String {
        switch target {
        case .codex:
            return resolvedCodex.summary
        case .claude:
            return resolvedClaude.summary
        }
    }

    var sanitizedDisplayName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return target.displayName
    }

    static var builtInProfiles: [CLIEnvironmentProfile] {
        [
            CLIEnvironmentProfile(
                id: builtInCodexProfileID,
                displayName: L10n.tr("Codex CLI（系统默认）"),
                target: .codex,
                isBuiltIn: true,
                codex: CodexCLIEnvironmentConfiguration()
            ),
            CLIEnvironmentProfile(
                id: builtInClaudeProfileID,
                displayName: L10n.tr("Claude Code（系统默认）"),
                target: .claude,
                isBuiltIn: true,
                claude: ClaudeCLIEnvironmentConfiguration()
            ),
        ]
    }

    static func defaultProfileID(for platform: PlatformKind) -> String {
        switch platform {
        case .codex:
            return builtInCodexProfileID
        case .claude:
            return builtInClaudeProfileID
        }
    }
}

struct CLILaunchRecord: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: UUID
    var path: String
    var target: CLIEnvironmentTarget
    var lastUsedAt: Date

    init(
        id: UUID = UUID(),
        path: String,
        target: CLIEnvironmentTarget,
        lastUsedAt: Date = Date()
    ) {
        self.id = id
        self.path = path
        self.target = target
        self.lastUsedAt = lastUsedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case path
        case target
        case lastUsedAt
        case environmentTarget
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        path = try container.decode(String.self, forKey: .path)
        target = try container.decodeIfPresent(CLIEnvironmentTarget.self, forKey: .target)
            ?? container.decodeIfPresent(CLIEnvironmentTarget.self, forKey: .environmentTarget)
            ?? .codex
        lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt) ?? Date()
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(path, forKey: .path)
        try container.encode(target, forKey: .target)
        try container.encode(lastUsedAt, forKey: .lastUsedAt)
    }
}

struct ResolvedCodexCLILaunchContext: Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        case globalCurrentAuth
        case isolated
    }

    let accountID: UUID
    let workingDirectoryURL: URL
    let mode: Mode
    let codexHomeURL: URL?
    let authPayload: CodexAuthPayload?
    let modelCatalogSnapshot: ResolvedCodexModelCatalogSnapshot?
    let configFileContents: String?
    let environmentVariables: [String: String]
    let arguments: [String]
}

struct ResolvedCodexDesktopLaunchContext: Equatable, Sendable {
    let accountID: UUID
    let codexHomeURL: URL
    let authPayload: CodexAuthPayload?
    let modelCatalogSnapshot: ResolvedCodexModelCatalogSnapshot?
    let configFileContents: String?
    let environmentVariables: [String: String]
}

struct ResolvedCodexModelCatalogSnapshot: Equatable, Sendable {
    let availableModels: [String]
}

struct ResolvedClaudeProviderSnapshot: Equatable, Sendable {
    let source: ClaudeProviderSource
    let model: String
    let modelProvider: String?
    let baseURL: String
    let apiKeyEnvName: String
    let availableModels: [String]?
}

struct ResolvedClaudeCLILaunchContext: Equatable, Sendable {
    let accountID: UUID
    let workingDirectoryURL: URL
    let rootURL: URL?
    let configDirectoryURL: URL?
    let executableOverrideURL: URL?
    let providerSnapshot: ResolvedClaudeProviderSnapshot?
    let environmentVariables: [String: String]
    let arguments: [String]
}
