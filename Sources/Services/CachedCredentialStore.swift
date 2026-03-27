import Foundation

enum PlaintextCredentialCacheStoreError: LocalizedError, Equatable {
    case unexpectedData

    var errorDescription: String? {
        switch self {
        case .unexpectedData:
            return L10n.tr("本地凭据缓存格式无效。")
        }
    }
}

struct PlaintextCredentialCacheStore {
    private let cacheFileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(cacheFileURL: URL, fileManager: FileManager = .default) {
        self.cacheFileURL = cacheFileURL
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        self.decoder = JSONDecoder()
    }

    func loadAll() throws -> [UUID: StoredCredential] {
        guard fileManager.fileExists(atPath: cacheFileURL.path) else {
            return [:]
        }

        let data = try Data(contentsOf: cacheFileURL)
        if let decoded = try? decoder.decode([String: StoredCredential].self, from: data) {
            var result: [UUID: StoredCredential] = [:]
            for (key, value) in decoded {
                guard let id = UUID(uuidString: key) else {
                    throw PlaintextCredentialCacheStoreError.unexpectedData
                }
                result[id] = value
            }
            return result
        }

        let legacyDecoded = try decoder.decode([String: CodexAuthPayload].self, from: data)
        var result: [UUID: StoredCredential] = [:]
        for (key, value) in legacyDecoded {
            guard let id = UUID(uuidString: key) else {
                throw PlaintextCredentialCacheStoreError.unexpectedData
            }
            result[id] = .codex(try value.validated())
        }
        return result
    }

    func saveAll(_ credentialsByAccountID: [UUID: StoredCredential]) throws {
        let directoryURL = cacheFileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let encodedCredentials = Dictionary(
            uniqueKeysWithValues: credentialsByAccountID.map { key, value in
                (key.uuidString, value)
            }
        )
        let data = try encoder.encode(encodedCredentials)
        try data.write(to: cacheFileURL, options: [.atomic])

        // Best-effort tightening of local token cache permissions.
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheFileURL.path)
    }
}

final class CachedCredentialStore: AccountCredentialStore, CredentialStore {
    private let persistentStore: PlaintextCredentialCacheStore
    private var memoryCache: [UUID: StoredCredential] = [:]
    private var hasLoadedPersistentCache = false

    init(persistentStore: PlaintextCredentialCacheStore) {
        self.persistentStore = persistentStore
    }

    func preload() throws {
        try loadPersistentCache(allowRecovery: false)
    }

    func save(_ credential: StoredCredential, for accountID: UUID) throws {
        try loadPersistentCache(allowRecovery: true)

        if memoryCache[accountID] == credential {
            return
        }

        memoryCache[accountID] = credential
        try persistentStore.saveAll(memoryCache)
    }

    func loadLatest(for account: ManagedAccount, authFileManager: any AuthFileManaging) throws -> StoredCredential {
        try loadPersistentCache(allowRecovery: true)

        if let cached = memoryCache[account.id] {
            return cached
        }

        if account.isActive,
           let currentPayload = try? authFileManager.readCurrentAuth(),
           let validatedCurrentPayload = try? currentPayload.validated(),
           validatedCurrentPayload.accountIdentifier == account.accountIdentifier
        {
            let credential = StoredCredential.codex(validatedCurrentPayload)
            try save(credential, for: account.id)
            return credential
        }

        throw CredentialStoreError.itemNotFound
    }

    func load(for accountID: UUID) throws -> StoredCredential {
        try loadPersistentCache(allowRecovery: true)

        guard let credential = memoryCache[accountID] else {
            throw CredentialStoreError.itemNotFound
        }
        return credential
    }

    func delete(for accountID: UUID) throws {
        try loadPersistentCache(allowRecovery: true)
        memoryCache.removeValue(forKey: accountID)
        try persistentStore.saveAll(memoryCache)
    }

    private func loadPersistentCache(allowRecovery: Bool) throws {
        guard !hasLoadedPersistentCache else { return }

        do {
            memoryCache = try persistentStore.loadAll()
            hasLoadedPersistentCache = true
        } catch {
            memoryCache = [:]
            hasLoadedPersistentCache = true
            if !allowRecovery {
                throw error
            }
        }
    }
}
