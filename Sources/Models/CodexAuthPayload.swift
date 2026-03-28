import Foundation

struct CodexTokenBundle: Codable, Equatable, Sendable {
    let idToken: String
    let accessToken: String
    let refreshToken: String
    let accountID: String

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case accountID = "account_id"
    }

    static let empty = CodexTokenBundle(idToken: "", accessToken: "", refreshToken: "", accountID: "")

    var isEmpty: Bool {
        idToken.isEmpty && accessToken.isEmpty && refreshToken.isEmpty && accountID.isEmpty
    }
}

struct CodexAuthPayload: Codable, Equatable, Sendable {
    let authMode: ManagedAuthKind
    let openAIAPIKey: String?
    let tokens: CodexTokenBundle
    let lastRefresh: String

    enum CodingKeys: String, CodingKey {
        case authMode = "auth_mode"
        case openAIAPIKey = "OPENAI_API_KEY"
        case tokens
        case lastRefresh = "last_refresh"
    }

    init(
        authMode: ManagedAuthKind = .chatgpt,
        openAIAPIKey: String? = nil,
        tokens: CodexTokenBundle = .empty,
        lastRefresh: String = ""
    ) {
        self.authMode = authMode
        self.openAIAPIKey = openAIAPIKey
        self.tokens = tokens
        self.lastRefresh = lastRefresh
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let openAIAPIKey = try container.decodeIfPresent(String.self, forKey: .openAIAPIKey)
        let tokens = try container.decodeIfPresent(CodexTokenBundle.self, forKey: .tokens) ?? .empty
        let lastRefresh = try container.decodeIfPresent(String.self, forKey: .lastRefresh) ?? ""
        let authMode = try container.decodeIfPresent(ManagedAuthKind.self, forKey: .authMode)
            ?? ((openAIAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false && tokens.isEmpty) ? .openAIAPIKey : .chatgpt)

        self.init(authMode: authMode, openAIAPIKey: openAIAPIKey, tokens: tokens, lastRefresh: lastRefresh)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch authMode {
        case .chatgpt:
            try container.encode(authMode, forKey: .authMode)
            try container.encode(tokens, forKey: .tokens)
            try container.encode(lastRefresh, forKey: .lastRefresh)
        case .openAIAPIKey:
            try container.encodeIfPresent(openAIAPIKey, forKey: .openAIAPIKey)
        case .claudeProfile, .anthropicAPIKey, .providerAPIKey:
            throw CodexAuthPayloadError.unsupportedAuthMode
        }
    }

    func validated() throws -> CodexAuthPayload {
        switch authMode {
        case .chatgpt:
            guard openAIAPIKey == nil else {
                throw CodexAuthPayloadError.unexpectedAPIKeyForChatGPT
            }
            guard !tokens.idToken.isEmpty, !tokens.accessToken.isEmpty, !tokens.refreshToken.isEmpty, !tokens.accountID.isEmpty else {
                throw CodexAuthPayloadError.missingTokenData
            }
            guard CodexDateCoding.parse(lastRefresh) != nil else {
                throw CodexAuthPayloadError.invalidRefreshTimestamp
            }
        case .openAIAPIKey:
            guard let trimmedAPIKey = openAIAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmedAPIKey.isEmpty else {
                throw CodexAuthPayloadError.missingAPIKey
            }
            return CodexAuthPayload(authMode: .openAIAPIKey, openAIAPIKey: trimmedAPIKey)
        case .claudeProfile, .anthropicAPIKey, .providerAPIKey:
            throw CodexAuthPayloadError.unsupportedAuthMode
        }
        return self
    }

    var accountIdentifier: String {
        switch authMode {
        case .chatgpt:
            return tokens.accountID
        case .openAIAPIKey:
            return Self.apiKeyAccountIdentifier(for: openAIAPIKey ?? "")
        case .claudeProfile, .anthropicAPIKey, .providerAPIKey:
            return ""
        }
    }

    var credentialSummary: String? {
        guard authMode == .openAIAPIKey, let openAIAPIKey, !openAIAPIKey.isEmpty else { return nil }
        let tail = String(openAIAPIKey.suffix(6))
        return tail.isEmpty ? L10n.tr("API Key") : "sk-...\(tail)"
    }

    private static func apiKeyAccountIdentifier(for apiKey: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in apiKey.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "api_%016llx", hash)
    }
}

enum CodexAuthPayloadError: LocalizedError, Equatable {
    case unsupportedAuthMode
    case unexpectedAPIKeyForChatGPT
    case missingAPIKey
    case missingTokenData
    case invalidRefreshTimestamp

    var errorDescription: String? {
        switch self {
        case .unsupportedAuthMode:
            return L10n.tr("不支持当前 auth_mode。")
        case .unexpectedAPIKeyForChatGPT:
            return L10n.tr("ChatGPT 认证模式下不应包含 API Key。")
        case .missingAPIKey:
            return L10n.tr("auth.json 缺少 OPENAI_API_KEY。")
        case .missingTokenData:
            return L10n.tr("auth.json 缺少必要的 token 字段。")
        case .invalidRefreshTimestamp:
            return L10n.tr("auth.json 的 last_refresh 不是有效的 ISO8601 时间。")
        }
    }
}

enum CodexDateCoding {
    private static func formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    static func parse(_ value: String) -> Date? {
        formatter().date(from: value)
    }

    static func string(from date: Date) -> String {
        formatter().string(from: date)
    }
}
