import Foundation

struct AuthIdentity: Equatable, Sendable {
    let accountID: String
    let displayName: String
    let email: String?
    let planType: String?
}

enum JWTClaimsDecoderError: LocalizedError, Equatable {
    case invalidToken
    case missingAccountID

    var errorDescription: String? {
        switch self {
        case .invalidToken:
            return L10n.tr("JWT 格式无效。")
        case .missingAccountID:
            return L10n.tr("JWT 里没有 chatgpt_account_id。")
        }
    }
}

struct JWTClaimsDecoder {
    func decodeIdentity(from payload: CodexAuthPayload) throws -> AuthIdentity {
        let idClaims = try claims(for: payload.tokens.idToken)
        let accessClaims = try claims(for: payload.tokens.accessToken)

        let authClaims = (idClaims["https://api.openai.com/auth"] as? [String: Any])
            ?? (accessClaims["https://api.openai.com/auth"] as? [String: Any])

        let accountID = (authClaims?["chatgpt_account_id"] as? String) ?? payload.tokens.accountID
        guard !accountID.isEmpty else {
            throw JWTClaimsDecoderError.missingAccountID
        }

        let email = (idClaims["email"] as? String)
            ?? ((accessClaims["https://api.openai.com/profile"] as? [String: Any])?["email"] as? String)
        let planType = authClaims?["chatgpt_plan_type"] as? String
        let displayName = (idClaims["name"] as? String)
            ?? email
            ?? L10n.tr("Account %@", String(accountID.prefix(8)))

        return AuthIdentity(
            accountID: accountID,
            displayName: displayName,
            email: email,
            planType: planType
        )
    }

    func claims(for token: String) throws -> [String: Any] {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else {
            throw JWTClaimsDecoderError.invalidToken
        }

        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))

        guard let data = Data(base64Encoded: base64) else {
            throw JWTClaimsDecoderError.invalidToken
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JWTClaimsDecoderError.invalidToken
        }
        return object
    }
}
