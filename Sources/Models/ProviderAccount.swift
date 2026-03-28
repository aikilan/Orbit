import Foundation

enum ProviderRule: String, Codable, CaseIterable, Identifiable, Sendable {
    case chatgptOAuth = "chatgpt_oauth"
    case claudeProfile = "claude_profile"
    case openAICompatible = "openai_compatible"
    case claudeCompatible = "claude_compatible"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chatgptOAuth:
            return "ChatGPT OAuth"
        case .claudeProfile:
            return L10n.tr("Claude Profile")
        case .openAICompatible:
            return L10n.tr("OpenAI 兼容")
        case .claudeCompatible:
            return L10n.tr("Claude 兼容")
        }
    }

    var defaultTarget: CLIEnvironmentTarget {
        switch self {
        case .chatgptOAuth, .openAICompatible:
            return .codex
        case .claudeProfile, .claudeCompatible:
            return .claude
        }
    }
}

struct ProviderPreset: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let rule: ProviderRule
    let baseURL: String
    let apiKeyEnvName: String
    let defaultModel: String
    let supportsResponsesAPI: Bool
    let isCustom: Bool

    init(
        id: String,
        displayName: String,
        rule: ProviderRule,
        baseURL: String,
        apiKeyEnvName: String,
        defaultModel: String,
        supportsResponsesAPI: Bool = true,
        isCustom: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.rule = rule
        self.baseURL = baseURL
        self.apiKeyEnvName = apiKeyEnvName
        self.defaultModel = defaultModel
        self.supportsResponsesAPI = supportsResponsesAPI
        self.isCustom = isCustom
    }
}

enum ProviderCatalog {
    static let customPresetID = "custom"

    static let presets: [ProviderPreset] = [
        ProviderPreset(
            id: "openai",
            displayName: "OpenAI",
            rule: .openAICompatible,
            baseURL: "https://api.openai.com/v1",
            apiKeyEnvName: "OPENAI_API_KEY",
            defaultModel: "gpt-5.4"
        ),
        ProviderPreset(
            id: "deepseek",
            displayName: "DeepSeek",
            rule: .openAICompatible,
            baseURL: "https://api.deepseek.com/v1",
            apiKeyEnvName: "DEEPSEEK_API_KEY",
            defaultModel: "deepseek-chat",
            supportsResponsesAPI: false
        ),
        ProviderPreset(
            id: "moonshot",
            displayName: "Moonshot AI (Kimi)",
            rule: .openAICompatible,
            baseURL: "https://api.moonshot.cn/v1",
            apiKeyEnvName: "MOONSHOT_API_KEY",
            defaultModel: "kimi-k2-0711-preview",
            supportsResponsesAPI: false
        ),
        ProviderPreset(
            id: "minimax",
            displayName: "MiniMax",
            rule: .openAICompatible,
            baseURL: "https://api.minimax.io/v1",
            apiKeyEnvName: "MINIMAX_API_KEY",
            defaultModel: "MiniMax-M2.7",
            supportsResponsesAPI: false
        ),
        ProviderPreset(
            id: "minimax_cn",
            displayName: "MiniMax (CN)",
            rule: .openAICompatible,
            baseURL: "https://api.minimaxi.com/v1",
            apiKeyEnvName: "MINIMAX_API_KEY",
            defaultModel: "MiniMax-M2.7",
            supportsResponsesAPI: false
        ),
        ProviderPreset(
            id: "zai",
            displayName: "Z.AI (GLM)",
            rule: .openAICompatible,
            baseURL: "https://api.z.ai/api/coding/paas/v4",
            apiKeyEnvName: "ZAI_API_KEY",
            defaultModel: "glm-5",
            supportsResponsesAPI: false
        ),
        ProviderPreset(
            id: "bigmodel",
            displayName: "智谱 AI (BigModel CN)",
            rule: .openAICompatible,
            baseURL: "https://open.bigmodel.cn/api/coding/paas/v4",
            apiKeyEnvName: "ZHIPUAI_API_KEY",
            defaultModel: "glm-5",
            supportsResponsesAPI: false
        ),
        ProviderPreset(
            id: "anthropic",
            displayName: "Anthropic",
            rule: .claudeCompatible,
            baseURL: "https://api.anthropic.com/v1",
            apiKeyEnvName: "ANTHROPIC_API_KEY",
            defaultModel: "claude-sonnet-4.5"
        ),
        ProviderPreset(
            id: "minimax_claude",
            displayName: "MiniMax",
            rule: .claudeCompatible,
            baseURL: "https://api.minimax.io/anthropic",
            apiKeyEnvName: "ANTHROPIC_AUTH_TOKEN",
            defaultModel: "MiniMax-M2.7"
        ),
        ProviderPreset(
            id: "minimax_claude_cn",
            displayName: "MiniMax (CN)",
            rule: .claudeCompatible,
            baseURL: "https://api.minimaxi.com/anthropic",
            apiKeyEnvName: "ANTHROPIC_AUTH_TOKEN",
            defaultModel: "MiniMax-M2.7"
        ),
        ProviderPreset(
            id: customPresetID,
            displayName: L10n.tr("自定义"),
            rule: .openAICompatible,
            baseURL: "",
            apiKeyEnvName: "",
            defaultModel: "",
            isCustom: true
        ),
    ]

    static func preset(id: String?) -> ProviderPreset? {
        guard let id else { return nil }
        return presets.first(where: { $0.id == id })
    }

    static func presets(for rule: ProviderRule) -> [ProviderPreset] {
        let filtered = presets.filter { $0.rule == rule || $0.isCustom }
        if filtered.contains(where: { $0.id == customPresetID }) {
            return filtered
        }
        return filtered + [
            ProviderPreset(
                id: customPresetID,
                displayName: L10n.tr("自定义"),
                rule: rule,
                baseURL: "",
                apiKeyEnvName: "",
                defaultModel: "",
                isCustom: true
            ),
        ]
    }

    static func supportsResponsesAPI(presetID: String?, baseURL: String?) -> Bool {
        if let presetID, let preset = preset(id: presetID), !preset.supportsResponsesAPI {
            return false
        }

        let trimmedBaseURL = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedBaseURL.isEmpty else {
            return true
        }

        let host = URL(string: trimmedBaseURL)?.host?.lowercased()
            ?? URL(string: "https://\(trimmedBaseURL)")?.host?.lowercased()
        switch host {
        case "api.deepseek.com", "api.minimax.io", "api.minimaxi.com", "api.moonshot.cn", "api.z.ai", "open.bigmodel.cn":
            return false
        default:
            return true
        }
    }

    static func providerDisplayName(
        presetID: String?,
        fallbackDisplayName: String?,
        fallbackRule: ProviderRule?
    ) -> String {
        if let fallbackDisplayName, !fallbackDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return fallbackDisplayName
        }
        if let preset = preset(id: presetID), !preset.isCustom {
            return preset.displayName
        }
        switch fallbackRule {
        case .openAICompatible:
            return L10n.tr("自定义 OpenAI Provider")
        case .claudeCompatible:
            return L10n.tr("自定义 Claude Provider")
        case .chatgptOAuth:
            return "ChatGPT"
        case .claudeProfile:
            return L10n.tr("Claude Profile")
        case .none:
            return L10n.tr("自定义供应商")
        }
    }
}

func normalizedMiniMaxAnthropicBaseURL(_ baseURL: String, includeVersion: Bool) -> String? {
    let trimmedBaseURL = baseURL
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !trimmedBaseURL.isEmpty else {
        return nil
    }

    let rawURL = URL(string: trimmedBaseURL)
        ?? URL(string: "https://\(trimmedBaseURL)")
    guard
        let rawURL,
        var components = URLComponents(url: rawURL, resolvingAgainstBaseURL: false),
        let host = components.host?.lowercased(),
        host == "api.minimax.io" || host == "api.minimaxi.com"
    else {
        return nil
    }

    let normalizedPath = components.path
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        .lowercased()
    guard normalizedPath == "anthropic" || normalizedPath == "anthropic/v1" else {
        return nil
    }

    components.path = includeVersion ? "/anthropic/v1" : "/anthropic"
    components.query = nil
    components.fragment = nil
    return components.string
}
