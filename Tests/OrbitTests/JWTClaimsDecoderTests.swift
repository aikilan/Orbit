import XCTest
@testable import Orbit

final class JWTClaimsDecoderTests: XCTestCase {
    func testDecoderExtractsAccountIdentityFromJWTClaims() throws {
        let decoder = JWTClaimsDecoder()
        let idToken = makeUnsignedJWT(claims: [
            "name": "Lie Jax",
            "email": "lie@example.com",
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acct_456",
                "chatgpt_plan_type": "team",
            ],
        ])
        let accessToken = makeUnsignedJWT(claims: [
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acct_456",
            ],
        ])
        let payload = CodexAuthPayload(
            tokens: CodexTokenBundle(
                idToken: idToken,
                accessToken: accessToken,
                refreshToken: "refresh",
                accountID: "acct_456"
            ),
            lastRefresh: CodexDateCoding.string(from: Date())
        )

        let identity = try decoder.decodeIdentity(from: payload)

        XCTAssertEqual(identity.accountID, "acct_456")
        XCTAssertEqual(identity.displayName, "Lie Jax")
        XCTAssertEqual(identity.email, "lie@example.com")
        XCTAssertEqual(identity.planType, "team")
    }

    private func makeUnsignedJWT(claims: [String: Any]) -> String {
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
}
