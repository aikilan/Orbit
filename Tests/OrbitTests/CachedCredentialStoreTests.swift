import Foundation
import XCTest
@testable import Orbit

final class CachedCredentialStoreTests: XCTestCase {
    func testRestartUsesPersistentCache() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let accountID = UUID()
        let payload = makePayload(accountID: "acct_restart", refreshToken: "refresh_old")
        let cacheFileURL = root.appendingPathComponent("credentials-cache.json")

        let firstStore = CachedCredentialStore(
            persistentStore: PlaintextCredentialCacheStore(cacheFileURL: cacheFileURL)
        )
        try firstStore.preload()
        try firstStore.save(payload, for: accountID)

        let secondStore = CachedCredentialStore(
            persistentStore: PlaintextCredentialCacheStore(cacheFileURL: cacheFileURL)
        )
        try secondStore.preload()

        XCTAssertEqual(try secondStore.load(for: accountID), payload)
    }

    func testActiveAccountUsesAuthFileAndPersistsCache() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let accountID = UUID()
        let payload = makePayload(accountID: "acct_active", refreshToken: "refresh_old")
        let authFileManager = CacheTestAuthFileManager()
        authFileManager.currentAuth = payload
        let cacheFileURL = root.appendingPathComponent("credentials-cache.json")
        let account = makeAccount(id: accountID, codexAccountID: payload.tokens.accountID, isActive: true)

        let firstStore = CachedCredentialStore(
            persistentStore: PlaintextCredentialCacheStore(cacheFileURL: cacheFileURL)
        )
        try firstStore.preload()
        XCTAssertEqual(try firstStore.loadLatest(for: account, authFileManager: authFileManager), payload)

        authFileManager.currentAuth = nil
        let secondStore = CachedCredentialStore(
            persistentStore: PlaintextCredentialCacheStore(cacheFileURL: cacheFileURL)
        )
        try secondStore.preload()
        XCTAssertEqual(try secondStore.loadLatest(for: account, authFileManager: authFileManager), payload)
    }

    func testDeleteRemovesPersistentCacheEntry() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let accountID = UUID()
        let payload = makePayload(accountID: "acct_delete", refreshToken: "refresh_old")
        let cacheFileURL = root.appendingPathComponent("credentials-cache.json")
        let store = CachedCredentialStore(
            persistentStore: PlaintextCredentialCacheStore(cacheFileURL: cacheFileURL)
        )

        try store.preload()
        try store.save(payload, for: accountID)
        try store.delete(for: accountID)

        XCTAssertThrowsError(try store.load(for: accountID))

        let restartedStore = CachedCredentialStore(
            persistentStore: PlaintextCredentialCacheStore(cacheFileURL: cacheFileURL)
        )
        try restartedStore.preload()
        XCTAssertThrowsError(try restartedStore.load(for: accountID))
    }

    func testLoadLatestThrowsWhenOnlyInMemoryMissing() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let accountID = UUID()
        let payload = makePayload(accountID: "acct_missing", refreshToken: "refresh_old")
        let store = CachedCredentialStore(
            persistentStore: PlaintextCredentialCacheStore(cacheFileURL: root.appendingPathComponent("credentials-cache.json"))
        )

        try store.preload()
        let account = makeAccount(id: accountID, codexAccountID: payload.tokens.accountID, isActive: false)

        XCTAssertThrowsError(try store.loadLatest(for: account, authFileManager: CacheTestAuthFileManager())) { error in
            XCTAssertEqual(error as? CredentialStoreError, .itemNotFound)
        }
    }

    func testSaveIsIdempotentForSamePayload() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let accountID = UUID()
        let payload = makePayload(accountID: "acct_same", refreshToken: "refresh_same")
        let cacheFileURL = root.appendingPathComponent("credentials-cache.json")
        let store = CachedCredentialStore(
            persistentStore: PlaintextCredentialCacheStore(cacheFileURL: cacheFileURL)
        )

        try store.preload()
        try store.save(payload, for: accountID)

        let before = try Data(contentsOf: cacheFileURL)
        try store.save(payload, for: accountID)
        let after = try Data(contentsOf: cacheFileURL)

        XCTAssertEqual(before, after)
    }

    func testPreloadRejectsInvalidCodexPayloadInNewFormatCache() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let accountID = UUID()
        let cacheFileURL = root.appendingPathComponent("credentials-cache.json")
        try writeInvalidNewFormatCache(to: cacheFileURL, accountID: accountID)

        let store = CachedCredentialStore(
            persistentStore: PlaintextCredentialCacheStore(cacheFileURL: cacheFileURL)
        )

        XCTAssertThrowsError(try store.preload())
    }

    func testLoadLatestRecoversFromInvalidNewFormatCacheUsingActiveAuthFile() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let accountID = UUID()
        let cacheFileURL = root.appendingPathComponent("credentials-cache.json")
        try writeInvalidNewFormatCache(to: cacheFileURL, accountID: accountID)

        let payload = makePayload(accountID: "acct_recovered", refreshToken: "refresh_recovered")
        let account = makeAccount(id: accountID, codexAccountID: payload.tokens.accountID, isActive: true)
        let authFileManager = CacheTestAuthFileManager()
        authFileManager.currentAuth = payload

        let store = CachedCredentialStore(
            persistentStore: PlaintextCredentialCacheStore(cacheFileURL: cacheFileURL)
        )

        XCTAssertEqual(try store.loadLatest(for: account, authFileManager: authFileManager), payload)

        let restartedStore = CachedCredentialStore(
            persistentStore: PlaintextCredentialCacheStore(cacheFileURL: cacheFileURL)
        )
        try restartedStore.preload()
        XCTAssertEqual(try restartedStore.load(for: accountID), payload)
    }

    private func makePayload(accountID: String, refreshToken: String) -> CodexAuthPayload {
        CodexAuthPayload(
            tokens: CodexTokenBundle(
                idToken: "id_\(accountID)",
                accessToken: "access_\(accountID)",
                refreshToken: refreshToken,
                accountID: accountID
            ),
            lastRefresh: CodexDateCoding.string(from: Date())
        )
    }

    private func makeAccount(id: UUID, codexAccountID: String, isActive: Bool) -> ManagedAccount {
        ManagedAccount(
            id: id,
            codexAccountID: codexAccountID,
            displayName: "Cached User",
            email: "cached@example.com",
            authMode: .chatgpt,
            createdAt: Date(),
            lastUsedAt: nil,
            lastQuotaSnapshotAt: nil,
            lastRefreshAt: nil,
            planType: nil,
            lastStatusCheckAt: nil,
            lastStatusMessage: nil,
            lastStatusLevel: nil,
            isActive: isActive
        )
    }

    private func writeInvalidNewFormatCache(to cacheFileURL: URL, accountID: UUID) throws {
        let directoryURL = cacheFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let payload = """
        {
          "\(accountID.uuidString)" : {
            "kind" : "codex",
            "codex" : {
              "auth_mode" : "chatgpt",
              "tokens" : {
                "id_token" : "id_invalid",
                "access_token" : "access_invalid",
                "refresh_token" : "refresh_invalid",
                "account_id" : "acct_invalid"
              },
              "last_refresh" : "not-an-iso8601-date"
            }
          }
        }
        """
        try Data(payload.utf8).write(to: cacheFileURL, options: [.atomic])
    }
}

private final class CacheTestAuthFileManager: AuthFileManaging {
    var currentAuth: CodexAuthPayload?

    func readCurrentAuth() throws -> CodexAuthPayload? {
        currentAuth
    }

    func activate(_ payload: CodexAuthPayload) throws {
        currentAuth = payload
    }

    func activatePreservingFileIdentity(_ payload: CodexAuthPayload) throws {
        currentAuth = payload
    }

    func clearAuthFile() throws {
        currentAuth = nil
    }
}
