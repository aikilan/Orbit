import Foundation

struct AnthropicAPIKeyCredential: Codable, Equatable, Sendable {
    let apiKey: String

    init(apiKey: String) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func validated() throws -> AnthropicAPIKeyCredential {
        guard !apiKey.isEmpty else {
            throw AnthropicAPIKeyCredentialError.missingAPIKey
        }
        return AnthropicAPIKeyCredential(apiKey: apiKey)
    }

    var accountIdentifier: String {
        Self.apiKeyAccountIdentifier(for: apiKey)
    }

    var credentialSummary: String {
        let tail = String(apiKey.suffix(6))
        return tail.isEmpty ? L10n.tr("Anthropic API Key") : "sk-ant-...\(tail)"
    }

    private static func apiKeyAccountIdentifier(for apiKey: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in apiKey.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "ant_%016llx", hash)
    }
}

struct ProviderAPIKeyCredential: Codable, Equatable, Sendable {
    let apiKey: String

    init(apiKey: String) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func validated() throws -> ProviderAPIKeyCredential {
        guard !apiKey.isEmpty else {
            throw ProviderAPIKeyCredentialError.missingAPIKey
        }
        return ProviderAPIKeyCredential(apiKey: apiKey)
    }

    var credentialSummary: String {
        let tail = String(apiKey.suffix(6))
        return tail.isEmpty ? L10n.tr("Provider API Key") : "sk-...\(tail)"
    }
}

enum ProviderAPIKeyCredentialError: LocalizedError, Equatable {
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return L10n.tr("请输入 API Key。")
        }
    }
}

enum AnthropicAPIKeyCredentialError: LocalizedError, Equatable {
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return L10n.tr("请输入 Anthropic API Key。")
        }
    }
}

struct ClaudeProfileSnapshotRef: Codable, Equatable, Sendable {
    let snapshotID: String
}

enum StoredCredential: Codable, Equatable, Sendable {
    case codex(CodexAuthPayload)
    case claudeProfile(ClaudeProfileSnapshotRef)
    case anthropicAPIKey(AnthropicAPIKeyCredential)
    case providerAPIKey(ProviderAPIKeyCredential)

    private enum CodingKeys: String, CodingKey {
        case kind
        case codex
        case claudeProfile
        case anthropicAPIKey
        case providerAPIKey
    }

    private enum StoredCredentialKind: String, Codable {
        case codex
        case claudeProfile = "claude_profile"
        case anthropicAPIKey = "anthropic_api_key"
        case providerAPIKey = "provider_api_key"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(StoredCredentialKind.self, forKey: .kind)

        switch kind {
        case .codex:
            self = .codex(try container.decode(CodexAuthPayload.self, forKey: .codex).validated())
        case .claudeProfile:
            self = .claudeProfile(try container.decode(ClaudeProfileSnapshotRef.self, forKey: .claudeProfile))
        case .anthropicAPIKey:
            self = .anthropicAPIKey(try container.decode(AnthropicAPIKeyCredential.self, forKey: .anthropicAPIKey).validated())
        case .providerAPIKey:
            self = .providerAPIKey(try container.decode(ProviderAPIKeyCredential.self, forKey: .providerAPIKey).validated())
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .codex(payload):
            try container.encode(StoredCredentialKind.codex, forKey: .kind)
            try container.encode(try payload.validated(), forKey: .codex)
        case let .claudeProfile(snapshotRef):
            try container.encode(StoredCredentialKind.claudeProfile, forKey: .kind)
            try container.encode(snapshotRef, forKey: .claudeProfile)
        case let .anthropicAPIKey(credential):
            try container.encode(StoredCredentialKind.anthropicAPIKey, forKey: .kind)
            try container.encode(try credential.validated(), forKey: .anthropicAPIKey)
        case let .providerAPIKey(credential):
            try container.encode(StoredCredentialKind.providerAPIKey, forKey: .kind)
            try container.encode(try credential.validated(), forKey: .providerAPIKey)
        }
    }

    var authKind: ManagedAuthKind {
        switch self {
        case let .codex(payload):
            return payload.authMode
        case .claudeProfile:
            return .claudeProfile
        case .anthropicAPIKey:
            return .anthropicAPIKey
        case .providerAPIKey:
            return .providerAPIKey
        }
    }

    var accountIdentifier: String {
        switch self {
        case let .codex(payload):
            return payload.accountIdentifier
        case let .claudeProfile(snapshotRef):
            return "claude_profile_\(snapshotRef.snapshotID)"
        case let .anthropicAPIKey(credential):
            return credential.accountIdentifier
        case let .providerAPIKey(credential):
            return ProviderAPIKeyCredential.accountIdentifier(for: credential.apiKey)
        }
    }

    var codexPayload: CodexAuthPayload? {
        guard case let .codex(payload) = self else { return nil }
        return payload
    }

    var claudeProfileSnapshotRef: ClaudeProfileSnapshotRef? {
        guard case let .claudeProfile(snapshotRef) = self else { return nil }
        return snapshotRef
    }

    var anthropicAPIKeyCredential: AnthropicAPIKeyCredential? {
        guard case let .anthropicAPIKey(credential) = self else { return nil }
        return credential
    }

    var providerAPIKeyCredential: ProviderAPIKeyCredential? {
        guard case let .providerAPIKey(credential) = self else { return nil }
        return credential
    }
}

extension ProviderAPIKeyCredential {
    static func accountIdentifier(for apiKey: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in apiKey.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "provider_%016llx", hash)
    }

    var accountIdentifier: String {
        Self.accountIdentifier(for: apiKey)
    }
}
