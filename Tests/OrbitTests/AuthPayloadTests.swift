import XCTest
@testable import Orbit

final class AuthPayloadTests: XCTestCase {
    func testPayloadValidationAcceptsExpectedChatGPTShape() throws {
        let payload = try makePayload()
        XCTAssertEqual(try payload.validated().tokens.accountID, "acct_123")
    }

    func testPayloadValidationAcceptsAPIKeyOnlyShape() throws {
        let payload = CodexAuthPayload(authMode: .apiKey, openAIAPIKey: "sk-test-api-key")

        let validated = try payload.validated()

        XCTAssertEqual(validated.authMode, .apiKey)
        XCTAssertEqual(validated.openAIAPIKey, "sk-test-api-key")
        XCTAssertTrue(validated.tokens.isEmpty)
    }

    func testPayloadDecodingInfersAPIKeyModeFromOfficialMinimalShape() throws {
        let payload = try JSONDecoder().decode(
            CodexAuthPayload.self,
            from: Data(#"{"OPENAI_API_KEY":"sk-test-minimal"}"#.utf8)
        )

        XCTAssertEqual(payload.authMode, .apiKey)
        XCTAssertEqual(payload.openAIAPIKey, "sk-test-minimal")
    }

    func testPayloadValidationRejectsMissingTokenData() {
        let payload = CodexAuthPayload(
            tokens: CodexTokenBundle(
                idToken: "",
                accessToken: "access",
                refreshToken: "refresh",
                accountID: "acct_123"
            ),
            lastRefresh: CodexDateCoding.string(from: Date())
        )

        XCTAssertThrowsError(try payload.validated()) { error in
            XCTAssertEqual(error as? CodexAuthPayloadError, .missingTokenData)
        }
    }

    private func makePayload() throws -> CodexAuthPayload {
        CodexAuthPayload(
            tokens: CodexTokenBundle(
                idToken: "id",
                accessToken: "access",
                refreshToken: "refresh",
                accountID: "acct_123"
            ),
            lastRefresh: CodexDateCoding.string(from: Date())
        )
    }
}
