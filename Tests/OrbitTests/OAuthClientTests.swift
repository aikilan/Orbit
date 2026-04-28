import Foundation
import XCTest
@testable import Orbit

final class OAuthClientTests: XCTestCase {
    func testRefreshAuthExchangesRefreshTokenAndReturnsUpdatedPayload() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://auth.openai.com/oauth/token")
            XCTAssertEqual(request.httpMethod, "POST")

            let body = String(data: try XCTUnwrap(Self.requestBody(from: request)), encoding: .utf8)
            XCTAssertTrue(body?.contains("grant_type=refresh_token") == true)
            XCTAssertTrue(body?.contains("refresh_token=refresh_old") == true)

            let responseBody = """
            {
              "access_token": "\(Self.makeUnsignedJWT(claims: [
                "https://api.openai.com/auth": [
                    "chatgpt_account_id": "acct_refresh"
                ]
              ]))",
              "refresh_token": "refresh_new",
              "id_token": "\(Self.makeUnsignedJWT(claims: [
                "name": "Refresh User",
                "email": "refresh@example.com",
                "https://api.openai.com/auth": [
                    "chatgpt_account_id": "acct_refresh",
                    "chatgpt_plan_type": "plus"
                ]
              ]))"
            }
            """

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(responseBody.utf8))
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OAuthClient(session: session)

        let result = try await client.refreshAuth(using: CodexAuthPayload(
            tokens: CodexTokenBundle(
                idToken: Self.makeUnsignedJWT(claims: [
                    "https://api.openai.com/auth": ["chatgpt_account_id": "acct_refresh"],
                ]),
                accessToken: Self.makeUnsignedJWT(claims: [
                    "https://api.openai.com/auth": ["chatgpt_account_id": "acct_refresh"],
                ]),
                refreshToken: "refresh_old",
                accountID: "acct_refresh"
            ),
            lastRefresh: CodexDateCoding.string(from: Date())
        ))

        XCTAssertEqual(result.payload.tokens.refreshToken, "refresh_new")
        XCTAssertEqual(result.identity.accountID, "acct_refresh")
        XCTAssertEqual(result.identity.displayName, "Refresh User")
        XCTAssertEqual(result.identity.planType, "plus")
    }

    func testFetchUsageSnapshotParsesQuotaAndCredits() async throws {
        MockURLProtocol.requestHandler = { request in
            switch (request.url?.host, request.url?.path) {
            case ("chatgpt.com", "/backend-api/wham/usage"):
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "acct_usage")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access_usage")

                let responseBody = """
                {
                  "email": "usage@example.com",
                  "plan_type": "team",
                  "subscription": {
                    "status": "active",
                    "is_disabled": false,
                    "is_expired": false
                  },
                  "rate_limit": {
                    "allowed": true,
                    "limit_reached": false,
                    "primary_window": {
                      "used_percent": 12,
                      "limit_window_seconds": 18000,
                      "reset_at": 1773908626
                    },
                    "secondary_window": {
                      "used_percent": 34,
                      "limit_window_seconds": 604800,
                      "reset_at": 1774017140
                    }
                  },
                  "credits": {
                    "has_credits": true,
                    "unlimited": false,
                    "balance": 9.5
                  }
                }
                """
                return try Self.jsonResponse(for: request, body: responseBody)

            case ("android.chat.openai.com", "/backend-api/accounts/check/v4-2023-04-27"):
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "acct_usage")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access_usage")
                XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "ChatGPT/1.2026.0 Android")
                XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "timezone_offset_min" })?
                    .value, "\(-TimeZone.current.secondsFromGMT() / 60)")

                let responseBody = """
                {
                  "accounts": {
                    "acct_usage": {
                      "entitlement": {
                        "has_active_subscription": true,
                        "subscription_plan": "chatgptplusplan",
                        "renews_at": "2026-05-07T00:00:00+00:00",
                        "expires_at": "2026-05-07T06:00:00+00:00"
                      }
                    }
                  }
                }
                """
                return try Self.jsonResponse(for: request, body: responseBody)

            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "<nil>")")
                throw URLError(.badURL)
            }
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OAuthClient(session: session)

        let result = try await client.fetchUsageSnapshot(using: CodexAuthPayload(
            tokens: CodexTokenBundle(
                idToken: Self.makeUnsignedJWT(claims: [
                    "https://api.openai.com/auth": ["chatgpt_account_id": "acct_usage"],
                ]),
                accessToken: "access_usage",
                refreshToken: "refresh_usage",
                accountID: "acct_usage"
            ),
            lastRefresh: CodexDateCoding.string(from: Date())
        ))

        XCTAssertEqual(result.email, "usage@example.com")
        XCTAssertEqual(result.planType, "team")
        XCTAssertTrue(result.allowed)
        XCTAssertFalse(result.limitReached)
        XCTAssertEqual(Int(result.snapshot.primary.usedPercent), 12)
        XCTAssertEqual(result.snapshot.primary.windowMinutes, 300)
        XCTAssertEqual(Int(try XCTUnwrap(result.snapshot.secondary).usedPercent), 34)
        XCTAssertEqual(try XCTUnwrap(result.snapshot.secondary).windowMinutes, 10080)
        XCTAssertEqual(result.snapshot.source, .onlineUsageRefresh)
        XCTAssertEqual(result.snapshot.credits?.balance, 9.5)
        XCTAssertEqual(result.subscriptionDetails?.allowed, true)
        XCTAssertEqual(result.subscriptionDetails?.limitReached, false)
        XCTAssertEqual(result.subscriptionDetails?.currentPeriodEndsAt, Self.iso8601Date("2026-05-07T00:00:00Z"))
    }

    func testFetchUsageSnapshotParsesPersonalAccountResponseWithFlexibleFieldTypes() async throws {
        MockURLProtocol.requestHandler = { request in
            guard request.url?.host == "chatgpt.com",
                  request.url?.path == "/backend-api/wham/usage" else {
                return try Self.jsonResponse(for: request, body: #"{"accounts":{}}"#)
            }

            let responseBody = """
            {
              "email": "personal@example.com",
              "plan_type": "plus",
              "rate_limit": {
                "allowed": 1,
                "limit_reached": "false",
                "primary_window": {
                  "used_percent": "18",
                  "limit_window_seconds": "18000",
                  "reset_at": "1773908626"
                }
              },
              "credits": {
                "has_credits": "true",
                "unlimited": 0,
                "balance": "9.5"
              }
            }
            """

            return try Self.jsonResponse(for: request, body: responseBody)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OAuthClient(session: session)

        let result = try await client.fetchUsageSnapshot(using: CodexAuthPayload(
            tokens: CodexTokenBundle(
                idToken: Self.makeUnsignedJWT(claims: [
                    "https://api.openai.com/auth": ["chatgpt_account_id": "acct_personal"],
                ]),
                accessToken: "access_personal",
                refreshToken: "refresh_personal",
                accountID: "acct_personal"
            ),
            lastRefresh: CodexDateCoding.string(from: Date())
        ))

        XCTAssertEqual(result.email, "personal@example.com")
        XCTAssertEqual(result.planType, "plus")
        XCTAssertTrue(result.allowed)
        XCTAssertFalse(result.limitReached)
        XCTAssertEqual(Int(result.snapshot.primary.usedPercent), 18)
        XCTAssertEqual(result.snapshot.primary.windowMinutes, 300)
        XCTAssertNil(result.snapshot.secondary)
        XCTAssertEqual(result.snapshot.remainingSummary, L10n.tr("5h %@", "82%"))
        XCTAssertEqual(result.snapshot.credits?.balance, 9.5)
    }

    func testFetchUsageSnapshotIgnoresAccountCheckFailure() async throws {
        MockURLProtocol.requestHandler = { request in
            switch (request.url?.host, request.url?.path) {
            case ("chatgpt.com", "/backend-api/wham/usage"):
                let responseBody = """
                {
                  "email": "fallback@example.com",
                  "plan_type": "plus",
                  "subscription": {
                    "expires_at": 1775126400
                  },
                  "rate_limit": {
                    "allowed": true,
                    "limit_reached": false,
                    "primary_window": {
                      "used_percent": 10,
                      "limit_window_seconds": 18000
                    }
                  }
                }
                """
                return try Self.jsonResponse(for: request, body: responseBody)

            case ("android.chat.openai.com", "/backend-api/accounts/check/v4-2023-04-27"):
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 403,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/html"]
                )!
                return (response, Data("<html>forbidden</html>".utf8))

            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "<nil>")")
                throw URLError(.badURL)
            }
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OAuthClient(session: session)

        let result = try await client.fetchUsageSnapshot(using: CodexAuthPayload(
            tokens: CodexTokenBundle(
                idToken: Self.makeUnsignedJWT(claims: [
                    "https://api.openai.com/auth": ["chatgpt_account_id": "acct_fallback"],
                ]),
                accessToken: "access_fallback",
                refreshToken: "refresh_fallback",
                accountID: "acct_fallback"
            ),
            lastRefresh: CodexDateCoding.string(from: Date())
        ))

        XCTAssertEqual(result.email, "fallback@example.com")
        XCTAssertEqual(result.planType, "plus")
        XCTAssertTrue(result.allowed)
        XCTAssertFalse(result.limitReached)
        XCTAssertEqual(result.subscriptionDetails?.currentPeriodEndsAt, Date(timeIntervalSince1970: 1_775_126_400))
    }

    override func tearDown() {
        super.tearDown()
        MockURLProtocol.requestHandler = nil
    }

    private static func jsonResponse(for request: URLRequest, body: String) throws -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: try XCTUnwrap(request.url),
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }

    private static func iso8601Date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: value)!
    }

    private static func makeUnsignedJWT(claims: [String: Any]) -> String {
        func encode(_ object: Any) -> String {
            let data = try! JSONSerialization.data(withJSONObject: object)
            return data
                .base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }

        return "\(encode(["alg": "none"]))" + "." + encode(claims) + ".signature"
    }

    private static func requestBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }

        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        let bufferSize = 1024
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }

        return data.isEmpty ? nil : data
    }
}

private final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            XCTFail("Missing request handler")
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
