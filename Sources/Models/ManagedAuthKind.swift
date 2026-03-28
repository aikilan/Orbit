import Foundation

enum ManagedAuthKind: String, Codable, CaseIterable, Sendable {
    case chatgpt
    case openAIAPIKey = "api_key"
    case claudeProfile = "claude_profile"
    case anthropicAPIKey = "anthropic_api_key"
    case providerAPIKey = "provider_api_key"

    var displayName: String {
        switch self {
        case .chatgpt:
            return "ChatGPT"
        case .openAIAPIKey:
            return L10n.tr("OpenAI API Key")
        case .claudeProfile:
            return L10n.tr("Claude Profile")
        case .anthropicAPIKey:
            return L10n.tr("Anthropic API Key")
        case .providerAPIKey:
            return L10n.tr("Provider API Key")
        }
    }
}
