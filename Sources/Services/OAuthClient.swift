import CryptoKit
import Foundation

struct AuthLoginResult: Sendable {
    let payload: CodexAuthPayload
    let identity: AuthIdentity
}

struct UsageRefreshResult: Sendable {
    let snapshot: QuotaSnapshot
    let email: String?
    let planType: String?
    let allowed: Bool
    let limitReached: Bool
    let subscriptionDetails: SubscriptionDetails?

    init(
        snapshot: QuotaSnapshot,
        email: String?,
        planType: String?,
        allowed: Bool,
        limitReached: Bool,
        subscriptionDetails: SubscriptionDetails? = nil
    ) {
        self.snapshot = snapshot
        self.email = email
        self.planType = planType
        self.allowed = allowed
        self.limitReached = limitReached
        self.subscriptionDetails = subscriptionDetails
    }
}

final class BrowserOAuthSession: @unchecked Sendable {
    let state: String
    let codeVerifier: String
    let callbackURL: URL
    let authorizeURL: URL
    let serverErrorDescription: String?

    private let callbackServer: LoopbackCallbackServer?

    init(
        state: String,
        codeVerifier: String,
        callbackURL: URL,
        authorizeURL: URL,
        callbackServer: LoopbackCallbackServer?,
        serverErrorDescription: String?
    ) {
        self.state = state
        self.codeVerifier = codeVerifier
        self.callbackURL = callbackURL
        self.authorizeURL = authorizeURL
        self.callbackServer = callbackServer
        self.serverErrorDescription = serverErrorDescription
    }

    var supportsAutomaticCallback: Bool {
        callbackServer != nil
    }

    func waitForCallback(timeout: TimeInterval = 300) async throws -> BrowserAuthorizationCallback {
        guard let callbackServer else {
            throw OAuthClientError.manualCallbackRequired
        }
        return try await callbackServer.waitForCallback(timeout: timeout)
    }

    func stop() {
        callbackServer?.stop()
    }
}

struct DeviceCodeChallenge: Codable, Equatable, Sendable {
    let deviceCode: String
    let userCode: String
    let verificationURL: URL
    let verificationURLComplete: URL?
    let interval: Int
    let expiresAt: Date
}

enum OAuthClientError: LocalizedError, Equatable {
    case couldNotOpenBrowser
    case callbackServerFailed
    case invalidCallback
    case oauthRejected(String)
    case stateMismatch
    case invalidTokenResponse
    case loginTimedOut
    case manualCallbackRequired
    case deviceAuthorizationPending
    case deviceFlowExpired
    case deviceFlowRejected(String)
    case invalidUsageResponse
    case httpFailure(Int, String)

    var errorDescription: String? {
        switch self {
        case .couldNotOpenBrowser:
            return L10n.tr("无法拉起系统浏览器。")
        case .callbackServerFailed:
            return L10n.tr("本地回调服务器启动失败。")
        case .invalidCallback:
            return L10n.tr("浏览器回调参数无效。")
        case let .oauthRejected(error):
            return L10n.tr("OpenAI 授权被拒绝：%@", error)
        case .stateMismatch:
            return L10n.tr("浏览器回调 state 校验失败。")
        case .invalidTokenResponse:
            return L10n.tr("OpenAI token 响应缺少必要字段。")
        case .loginTimedOut:
            return L10n.tr("登录等待超时。")
        case .manualCallbackRequired:
            return L10n.tr("当前需要手动粘贴浏览器最终跳转的 redirect URL 或 authorization code。")
        case .deviceAuthorizationPending:
            return L10n.tr("设备码仍在等待授权。")
        case .deviceFlowExpired:
            return L10n.tr("设备码已过期。")
        case let .deviceFlowRejected(message):
            return L10n.tr("设备码登录失败：%@", message)
        case .invalidUsageResponse:
            return L10n.tr("额度接口返回的数据结构无效。")
        case let .httpFailure(code, body):
            return L10n.tr("OpenAI 接口返回 %d：%@", code, body)
        }
    }
}

struct OAuthClientConfiguration: Sendable {
    var baseURL = URL(string: "https://auth.openai.com")!
    var chatGPTBaseURL = URL(string: "https://chatgpt.com")!
    var clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    var authorizePath = "/oauth/authorize"
    var tokenPath = "/oauth/token"
    var deviceStartPath = "/api/accounts/codex/device"
    var deviceTokenPath = "/deviceauth/token"
    var usagePath = "/backend-api/wham/usage"
    var callbackHost = "localhost"
    var callbackPort: UInt16 = 1455
    var callbackPath = "/auth/callback"
    var scopes = [
        "openid",
        "profile",
        "email",
        "offline_access",
        "api.connectors.read",
        "api.connectors.invoke",
    ]
}

final class OAuthClient: @unchecked Sendable {
    private let configuration: OAuthClientConfiguration
    private let session: URLSession
    private let jwtDecoder: JWTClaimsDecoder

    init(
        configuration: OAuthClientConfiguration = OAuthClientConfiguration(),
        session: URLSession = .shared,
        jwtDecoder: JWTClaimsDecoder = JWTClaimsDecoder()
    ) {
        self.configuration = configuration
        self.session = session
        self.jwtDecoder = jwtDecoder
    }

    func beginBrowserLogin(openURL: @escaping @Sendable (URL) -> Bool) async throws -> BrowserOAuthSession {
        let state = Self.randomString(length: 32)
        let verifier = Self.randomString(length: 64)
        let challenge = Self.codeChallenge(for: verifier)
        let callbackURL = URL(string: "http://\(configuration.callbackHost):\(configuration.callbackPort)\(configuration.callbackPath)")!
        let callbackServer = LoopbackCallbackServer(
            host: configuration.callbackHost,
            port: configuration.callbackPort,
            callbackPath: configuration.callbackPath
        )

        let startedServer: LoopbackCallbackServer?
        let serverErrorDescription: String?
        do {
            _ = try await callbackServer.start()
            startedServer = callbackServer
            serverErrorDescription = nil
        } catch {
            startedServer = nil
            serverErrorDescription = error.localizedDescription
        }

        let authorizeURL = try buildAuthorizeURL(callbackURL: callbackURL, state: state, challenge: challenge)

        guard openURL(authorizeURL) else {
            throw OAuthClientError.couldNotOpenBrowser
        }

        return BrowserOAuthSession(
            state: state,
            codeVerifier: verifier,
            callbackURL: callbackURL,
            authorizeURL: authorizeURL,
            callbackServer: startedServer,
            serverErrorDescription: serverErrorDescription
        )
    }

    func completeBrowserLogin(session: BrowserOAuthSession) async throws -> AuthLoginResult {
        let callback = try await session.waitForCallback()
        return try await completeBrowserLogin(session: session, callback: callback)
    }

    func completeBrowserLogin(session: BrowserOAuthSession, pastedInput: String) async throws -> AuthLoginResult {
        session.stop()
        let callback = try parsePastedBrowserInput(pastedInput, expectedState: session.state)
        return try await completeBrowserLogin(session: session, callback: callback)
    }

    private func completeBrowserLogin(session: BrowserOAuthSession, callback: BrowserAuthorizationCallback) async throws -> AuthLoginResult {
        if !callback.state.isEmpty && callback.state != session.state {
            throw OAuthClientError.stateMismatch
        }
        let tokenResponse = try await exchangeAuthorizationCode(
            callbackCode: callback.code,
            callbackURL: session.callbackURL,
            codeVerifier: session.codeVerifier
        )
        return try buildResult(from: tokenResponse)
    }

    func startDeviceCodeLogin() async throws -> DeviceCodeChallenge {
        let url = endpointURL(path: configuration.deviceStartPath)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "client_id": configuration.clientID,
            "scope": configuration.scopes.joined(separator: " "),
        ])

        let (data, response) = try await session.data(for: request)
        try validateHTTP(response: response, data: data)

        let rawResponse = try JSONDecoder().decode(DeviceCodeStartResponse.self, from: data)
        guard
            let verificationURL = URL(string: rawResponse.verificationURI),
            let deviceCode = rawResponse.deviceCode,
            let userCode = rawResponse.userCode
        else {
            throw OAuthClientError.invalidTokenResponse
        }

        return DeviceCodeChallenge(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURL: verificationURL,
            verificationURLComplete: rawResponse.verificationURIComplete.flatMap(URL.init(string:)),
            interval: rawResponse.interval ?? 5,
            expiresAt: Date().addingTimeInterval(TimeInterval(rawResponse.expiresIn ?? 900))
        )
    }

    func pollDeviceCodeLogin(challenge: DeviceCodeChallenge) async throws -> AuthLoginResult {
        while Date() < challenge.expiresAt {
            try await Task.sleep(for: .seconds(max(challenge.interval, 1)))

            do {
                let response = try await exchangeDeviceCode(challenge: challenge)
                return try buildResult(from: response)
            } catch OAuthClientError.deviceAuthorizationPending {
                continue
            }
        }

        throw OAuthClientError.deviceFlowExpired
    }

    func refreshAuth(using payload: CodexAuthPayload) async throws -> AuthLoginResult {
        let validatedPayload = try payload.validated()
        let url = endpointURL(path: configuration.tokenPath)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "grant_type": "refresh_token",
            "refresh_token": validatedPayload.tokens.refreshToken,
            "client_id": configuration.clientID,
        ])

        let (data, response) = try await session.data(for: request)
        try validateHTTP(response: response, data: data)
        let tokenResponse = try JSONDecoder().decode(TokenExchangeResponse.self, from: data)
        return try buildResult(from: tokenResponse)
    }

    func fetchUsageSnapshot(using payload: CodexAuthPayload) async throws -> UsageRefreshResult {
        let validatedPayload = try payload.validated()
        let url = chatGPTEndpointURL(path: configuration.usagePath)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(validatedPayload.tokens.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(validatedPayload.tokens.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")

        let (data, response) = try await session.data(for: request)
        try validateHTTP(response: response, data: data)

        let usageResponse = try JSONDecoder().decode(UsageResponse.self, from: data)
        return try buildUsageSnapshot(from: usageResponse)
    }

    private func buildUsageSnapshot(from usageResponse: UsageResponse) throws -> UsageRefreshResult {
        guard let rateLimit = usageResponse.rateLimit else {
            throw OAuthClientError.invalidUsageResponse
        }
        guard let primaryWindow = rateLimit.primaryWindow ?? rateLimit.secondaryWindow else {
            throw OAuthClientError.invalidUsageResponse
        }

        let snapshot = QuotaSnapshot(
            primary: RateLimitWindowSnapshot(
                usedPercent: primaryWindow.usedPercent,
                windowMinutes: primaryWindow.limitWindowSeconds / 60,
                resetsAt: primaryWindow.resetAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            ),
            secondary: (rateLimit.primaryWindow == nil ? nil : rateLimit.secondaryWindow).map {
                RateLimitWindowSnapshot(
                    usedPercent: $0.usedPercent,
                    windowMinutes: $0.limitWindowSeconds / 60,
                    resetsAt: $0.resetAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                )
            },
            credits: usageResponse.credits.map {
                CreditsSnapshot(hasCredits: $0.hasCredits, unlimited: $0.unlimited, balance: $0.balance)
            },
            planType: usageResponse.planType,
            capturedAt: Date(),
            source: .onlineUsageRefresh
        )

        return UsageRefreshResult(
            snapshot: snapshot,
            email: usageResponse.email,
            planType: usageResponse.planType,
            allowed: rateLimit.allowed ?? usageResponse.subscriptionDetails?.allowed ?? true,
            limitReached: rateLimit.limitReached ?? usageResponse.subscriptionDetails?.limitReached ?? false,
            subscriptionDetails: usageResponse.subscriptionDetails
        )
    }

    private func buildAuthorizeURL(callbackURL: URL, state: String, challenge: String) throws -> URL {
        var components = URLComponents(url: endpointURL(path: configuration.authorizePath), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: callbackURL.absoluteString),
            URLQueryItem(name: "scope", value: configuration.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]

        guard let url = components?.url else {
            throw OAuthClientError.invalidCallback
        }
        return url
    }

    private func exchangeAuthorizationCode(callbackCode: String, callbackURL: URL, codeVerifier: String) async throws -> TokenExchangeResponse {
        let url = endpointURL(path: configuration.tokenPath)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "grant_type": "authorization_code",
            "code": callbackCode,
            "redirect_uri": callbackURL.absoluteString,
            "client_id": configuration.clientID,
            "code_verifier": codeVerifier,
        ])

        let (data, response) = try await session.data(for: request)
        try validateHTTP(response: response, data: data)
        return try JSONDecoder().decode(TokenExchangeResponse.self, from: data)
    }

    private func exchangeDeviceCode(challenge: DeviceCodeChallenge) async throws -> TokenExchangeResponse {
        let url = endpointURL(path: configuration.deviceTokenPath)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            "device_code": challenge.deviceCode,
            "client_id": configuration.clientID,
        ])

        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200 ... 299).contains(httpResponse.statusCode) {
            if let deviceError = try? JSONDecoder().decode(DeviceCodeErrorResponse.self, from: data) {
                switch deviceError.error {
                case "authorization_pending":
                    throw OAuthClientError.deviceAuthorizationPending
                case "slow_down":
                    try await Task.sleep(for: .seconds(challenge.interval + 2))
                    throw OAuthClientError.deviceAuthorizationPending
                case "expired_token":
                    throw OAuthClientError.deviceFlowExpired
                default:
                    throw OAuthClientError.deviceFlowRejected(deviceError.errorDescription ?? deviceError.error)
                }
            }
            throw OAuthClientError.httpFailure(httpResponse.statusCode, redactedBody(data))
        }

        return try JSONDecoder().decode(TokenExchangeResponse.self, from: data)
    }

    private func buildResult(from response: TokenExchangeResponse) throws -> AuthLoginResult {
        guard
            let idToken = response.idToken,
            let accessToken = response.accessToken,
            let refreshToken = response.refreshToken
        else {
            throw OAuthClientError.invalidTokenResponse
        }

        let provisionalPayload = CodexAuthPayload(
            tokens: CodexTokenBundle(
                idToken: idToken,
                accessToken: accessToken,
                refreshToken: refreshToken,
                accountID: response.accountID ?? ""
            ),
            lastRefresh: CodexDateCoding.string(from: Date())
        )

        let identity = try jwtDecoder.decodeIdentity(from: provisionalPayload)
        let payload = CodexAuthPayload(
            tokens: CodexTokenBundle(
                idToken: idToken,
                accessToken: accessToken,
                refreshToken: refreshToken,
                accountID: identity.accountID
            ),
            lastRefresh: CodexDateCoding.string(from: Date())
        )

        return AuthLoginResult(payload: try payload.validated(), identity: identity)
    }

    private func validateHTTP(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OAuthClientError.invalidTokenResponse
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            throw OAuthClientError.httpFailure(httpResponse.statusCode, redactedBody(data))
        }
    }

    private func redactedBody(_ data: Data) -> String {
        let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        return body.replacingOccurrences(of: #"("[A-Za-z_]*token"\s*:\s*")[^"]+("#, with: "$1[REDACTED]$2", options: .regularExpression)
    }

    private func endpointURL(path: String) -> URL {
        configuration.baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    private func chatGPTEndpointURL(path: String) -> URL {
        configuration.chatGPTBaseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    private func formBody(_ values: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = values
            .sorted(by: { $0.key < $1.key })
            .map { key, value in
                let escapedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let escapedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(escapedKey)=\(escapedValue)"
            }
            .joined(separator: "&")
        return Data(body.utf8)
    }

    static func randomString(length: Int) -> String {
        let characters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return String((0 ..< length).map { _ in characters.randomElement()! })
    }

    static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    func parsePastedBrowserInput(_ input: String, expectedState: String) throws -> BrowserAuthorizationCallback {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OAuthClientError.invalidCallback
        }

        if let url = URL(string: trimmed), let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            if let error = items["error"], !error.isEmpty {
                throw OAuthClientError.oauthRejected(error)
            }
            if let code = items["code"], !code.isEmpty {
                let state = items["state"] ?? ""
                if !state.isEmpty && state != expectedState {
                    throw OAuthClientError.stateMismatch
                }
                return BrowserAuthorizationCallback(code: code, state: state)
            }
        }

        if trimmed.contains("?code="), let code = trimmed.components(separatedBy: "?code=").last {
            return BrowserAuthorizationCallback(code: code, state: "")
        }

        return BrowserAuthorizationCallback(code: trimmed, state: "")
    }
}

extension OAuthClient: OAuthClienting {}

private struct TokenExchangeResponse: Codable {
    let accessToken: String?
    let refreshToken: String?
    let idToken: String?
    let accountID: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case accountID = "account_id"
    }
}

private struct UsageResponse: Decodable {
    let email: String?
    let planType: String?
    let rateLimit: RateLimitDetails?
    let credits: Credits?
    let subscriptionDetails: SubscriptionDetails?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        email = Self.decodeString(in: container, keys: ["email"])
        planType = Self.decodeString(in: container, keys: ["plan_type"])
        rateLimit = Self.decodeRateLimit(in: container, key: "rate_limit")
        credits = Self.decodeCredits(in: container, key: "credits")

        var details = try Self.decodeSubscriptionDetails(from: container)
        if let rateLimit {
            details = SubscriptionDetails(
                allowed: details?.allowed ?? rateLimit.allowed,
                limitReached: details?.limitReached ?? rateLimit.limitReached
            )
        }
        subscriptionDetails = details?.hasAnyValue == true ? details : nil
    }

    struct RateLimitDetails {
        let allowed: Bool?
        let limitReached: Bool?
        let primaryWindow: Window?
        let secondaryWindow: Window?
    }

    struct Window {
        let usedPercent: Double
        let limitWindowSeconds: Int
        let resetAt: Int?
    }

    struct Credits {
        let hasCredits: Bool
        let unlimited: Bool
        let balance: Double?
    }

    private static func decodeSubscriptionDetails(
        from container: KeyedDecodingContainer<DynamicCodingKey>
    ) throws -> SubscriptionDetails? {
        var details = decodeSubscriptionDetails(in: container)
        for key in ["subscription", "plan", "account_plan", "subscription_plan"] {
            let codingKey = DynamicCodingKey(key)
            guard container.contains(codingKey),
                  let nested = try? container.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: codingKey) else {
                continue
            }
            if let nestedDetails = decodeSubscriptionDetails(in: nested) {
                details = nestedDetails.merged(over: details)
            }
        }
        return details?.hasAnyValue == true ? details : nil
    }

    private static func decodeRateLimit(
        in container: KeyedDecodingContainer<DynamicCodingKey>,
        key: String
    ) -> RateLimitDetails? {
        let codingKey = DynamicCodingKey(key)
        guard container.contains(codingKey),
              let nested = try? container.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: codingKey) else {
            return nil
        }

        let allowed = decodeBool(in: nested, keys: ["allowed", "is_allowed"])
        let limitReached = decodeBool(in: nested, keys: ["limit_reached", "is_limit_reached"])
        let primaryWindow = decodeWindow(in: nested, key: "primary_window")
        let secondaryWindow = decodeWindow(in: nested, key: "secondary_window")

        guard allowed != nil || limitReached != nil || primaryWindow != nil || secondaryWindow != nil else {
            return nil
        }

        return RateLimitDetails(
            allowed: allowed,
            limitReached: limitReached,
            primaryWindow: primaryWindow,
            secondaryWindow: secondaryWindow
        )
    }

    private static func decodeWindow(
        in container: KeyedDecodingContainer<DynamicCodingKey>,
        key: String
    ) -> Window? {
        let codingKey = DynamicCodingKey(key)
        guard container.contains(codingKey),
              let nested = try? container.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: codingKey),
              let usedPercent = decodeDouble(in: nested, keys: ["used_percent"]),
              let limitWindowSeconds = decodeInt(in: nested, keys: ["limit_window_seconds"]) else {
            return nil
        }

        return Window(
            usedPercent: usedPercent,
            limitWindowSeconds: limitWindowSeconds,
            resetAt: decodeInt(in: nested, keys: ["reset_at"])
        )
    }

    private static func decodeCredits(
        in container: KeyedDecodingContainer<DynamicCodingKey>,
        key: String
    ) -> Credits? {
        let codingKey = DynamicCodingKey(key)
        guard container.contains(codingKey),
              let nested = try? container.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: codingKey) else {
            return nil
        }

        let hasCredits = decodeBool(in: nested, keys: ["has_credits"]) ?? false
        let unlimited = decodeBool(in: nested, keys: ["unlimited"]) ?? false
        let balance = decodeDouble(in: nested, keys: ["balance"])

        guard hasCredits || unlimited || balance != nil else {
            return nil
        }

        return Credits(hasCredits: hasCredits, unlimited: unlimited, balance: balance)
    }

    private static func decodeSubscriptionDetails(
        in container: KeyedDecodingContainer<DynamicCodingKey>
    ) -> SubscriptionDetails? {
        let details = SubscriptionDetails(
            allowed: decodeBool(in: container, keys: [
                "allowed",
                "is_allowed",
                "can_use",
                "can_access",
            ]),
            limitReached: decodeBool(in: container, keys: [
                "limit_reached",
                "is_limit_reached",
            ])
        )

        return details.hasAnyValue ? details : nil
    }

    private static func decodeString(
        in container: KeyedDecodingContainer<DynamicCodingKey>,
        keys: [String]
    ) -> String? {
        for key in keys {
            let codingKey = DynamicCodingKey(key)
            if let value = try? container.decodeIfPresent(String.self, forKey: codingKey),
               let normalized = normalizedString(value) {
                return normalized
            }
            if let value = try? container.decodeIfPresent(Int.self, forKey: codingKey) {
                return "\(value)"
            }
            if let value = try? container.decodeIfPresent(Double.self, forKey: codingKey) {
                return "\(value)"
            }
            if let value = try? container.decodeIfPresent(Bool.self, forKey: codingKey) {
                return value ? "true" : "false"
            }
        }
        return nil
    }

    private static func decodeBool(
        in container: KeyedDecodingContainer<DynamicCodingKey>,
        keys: [String]
    ) -> Bool? {
        for key in keys {
            let codingKey = DynamicCodingKey(key)
            if let value = try? container.decodeIfPresent(Bool.self, forKey: codingKey) {
                return value
            }
            if let value = try? container.decodeIfPresent(Int.self, forKey: codingKey) {
                return value != 0
            }
            if let value = try? container.decodeIfPresent(String.self, forKey: codingKey),
               let normalized = normalizedString(value) {
                switch normalized.lowercased() {
                case "true", "1", "yes":
                    return true
                case "false", "0", "no":
                    return false
                default:
                    continue
                }
            }
        }
        return nil
    }

    private static func decodeInt(
        in container: KeyedDecodingContainer<DynamicCodingKey>,
        keys: [String]
    ) -> Int? {
        for key in keys {
            let codingKey = DynamicCodingKey(key)
            if let value = try? container.decodeIfPresent(Int.self, forKey: codingKey) {
                return value
            }
            if let value = try? container.decodeIfPresent(Double.self, forKey: codingKey) {
                return Int(value)
            }
            if let value = try? container.decodeIfPresent(String.self, forKey: codingKey),
               let normalized = normalizedString(value),
               let intValue = Int(normalized) {
                return intValue
            }
        }
        return nil
    }

    private static func decodeDouble(
        in container: KeyedDecodingContainer<DynamicCodingKey>,
        keys: [String]
    ) -> Double? {
        for key in keys {
            let codingKey = DynamicCodingKey(key)
            if let value = try? container.decodeIfPresent(Double.self, forKey: codingKey) {
                return value
            }
            if let value = try? container.decodeIfPresent(Int.self, forKey: codingKey) {
                return Double(value)
            }
            if let value = try? container.decodeIfPresent(String.self, forKey: codingKey),
               let normalized = normalizedString(value),
               let doubleValue = Double(normalized) {
                return doubleValue
            }
        }
        return nil
    }

    private static func normalizedString(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

private struct DeviceCodeStartResponse: Codable {
    let deviceCode: String?
    let userCode: String?
    let verificationURI: String
    let verificationURIComplete: String?
    let expiresIn: Int?
    let interval: Int?

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case verificationURIComplete = "verification_uri_complete"
        case expiresIn = "expires_in"
        case interval
    }
}

private struct DeviceCodeErrorResponse: Codable {
    let error: String
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}
