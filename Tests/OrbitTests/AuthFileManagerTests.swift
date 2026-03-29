import XCTest
@testable import Orbit

final class AuthFileManagerTests: XCTestCase {
    func testActivatePreservesFileIdentityForExistingAuthFile() throws {
        let tempDirectory = try makeTempDirectory()
        let authURL = tempDirectory.appendingPathComponent("auth.json")
        let manager = AuthFileManager(authFileURL: authURL)

        let firstPayload = makePayload(accountID: "acct_A")
        let secondPayload = makePayload(accountID: "acct_B")

        try manager.activate(firstPayload)
        let originalIdentifier = try fileIdentifier(for: authURL)
        try manager.activate(secondPayload)

        let saved = try XCTUnwrap(try manager.readCurrentAuth())
        XCTAssertEqual(saved.tokens.accountID, "acct_B")
        XCTAssertEqual(try fileIdentifier(for: authURL), originalIdentifier)
    }

    func testActivateRejectsInvalidExistingAuthBeforeOverwrite() throws {
        let tempDirectory = try makeTempDirectory()
        let authURL = tempDirectory.appendingPathComponent("auth.json")
        try Data("{\"auth_mode\":\"chatgpt\"}".utf8).write(to: authURL)
        let manager = AuthFileManager(authFileURL: authURL)

        XCTAssertThrowsError(try manager.activate(makePayload(accountID: "acct_B"))) { error in
            guard case AuthFileManagerError.schemaValidationFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testActivateRestoresBackupIfOverwriteFails() throws {
        let tempDirectory = try makeTempDirectory()
        let authURL = tempDirectory.appendingPathComponent("auth.json")

        let originalPayload = makePayload(accountID: "acct_A")
        let updatedPayload = makePayload(accountID: "acct_B")
        try AuthFileManager(authFileURL: authURL).activate(originalPayload)

        let manager = AuthFileManager(
            authFileURL: authURL,
            overwriteExistingContents: { url, data in
                let partialData = data.prefix(16)
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.truncate(atOffset: 0)
                try handle.seek(toOffset: 0)
                try handle.write(contentsOf: partialData)
                throw CocoaError(.fileWriteUnknown)
            }
        )

        XCTAssertThrowsError(try manager.activate(updatedPayload))

        let restored = try XCTUnwrap(try AuthFileManager(authFileURL: authURL).readCurrentAuth())
        XCTAssertEqual(restored.tokens.accountID, originalPayload.tokens.accountID)
    }

    func testReadCurrentAuthAcceptsOfficialAPIKeyOnlyShape() throws {
        let tempDirectory = try makeTempDirectory()
        let authURL = tempDirectory.appendingPathComponent("auth.json")
        try Data(#"{"OPENAI_API_KEY":"sk-test-file"}"#.utf8).write(to: authURL)

        let payload = try XCTUnwrap(try AuthFileManager(authFileURL: authURL).readCurrentAuth())

        XCTAssertEqual(payload.authMode, .apiKey)
        XCTAssertEqual(payload.openAIAPIKey, "sk-test-file")
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fileIdentifier(for url: URL) throws -> AnyHashable {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.systemFileNumber] as? NSNumber)
    }

    private func makePayload(accountID: String) -> CodexAuthPayload {
        CodexAuthPayload(
            tokens: CodexTokenBundle(
                idToken: "id_\(accountID)",
                accessToken: "access_\(accountID)",
                refreshToken: "refresh_\(accountID)",
                accountID: accountID
            ),
            lastRefresh: CodexDateCoding.string(from: Date())
        )
    }
}
