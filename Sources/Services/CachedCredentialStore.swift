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

    func loadAll() throws -> [UUID: CodexAuthPayload] {
        guard fileManager.fileExists(atPath: cacheFileURL.path) else {
            return [:]
        }

        let data = try Data(contentsOf: cacheFileURL)
        let decoded = try decoder.decode([String: CodexAuthPayload].self, from: data)
        var result: [UUID: CodexAuthPayload] = [:]
        for (key, value) in decoded {
            guard let id = UUID(uuidString: key) else {
                throw PlaintextCredentialCacheStoreError.unexpectedData
            }
            result[id] = try value.validated()
        }
        return result
    }

    func saveAll(_ payloadsByAccountID: [UUID: CodexAuthPayload]) throws {
        let directoryURL = cacheFileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let encodedPayloads = try Dictionary(
            uniqueKeysWithValues: payloadsByAccountID.map { key, value in
                (key.uuidString, try value.validated())
            }
        )
        let data = try encoder.encode(encodedPayloads)
        try data.write(to: cacheFileURL, options: [.atomic])

        // Best-effort tightening of local token cache permissions.
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheFileURL.path)
    }
}

final class CachedCredentialStore: AccountCredentialStore, CredentialStore {
    private let persistentStore: PlaintextCredentialCacheStore
    private var memoryCache: [UUID: CodexAuthPayload] = [:]
    private var hasLoadedPersistentCache = false

    init(persistentStore: PlaintextCredentialCacheStore) {
        self.persistentStore = persistentStore
    }

    func preload() throws {
        try loadPersistentCache(allowRecovery: false)
    }

    func save(_ payload: CodexAuthPayload, for accountID: UUID) throws {
        try loadPersistentCache(allowRecovery: true)
        let validatedPayload = try payload.validated()

        if memoryCache[accountID] == validatedPayload {
            return
        }

        memoryCache[accountID] = validatedPayload
        try persistentStore.saveAll(memoryCache)
    }

    func loadLatest(for account: ManagedAccount, authFileManager: any AuthFileManaging) throws -> CodexAuthPayload {
        try loadPersistentCache(allowRecovery: true)

        if let cached = memoryCache[account.id] {
            return cached
        }

        if account.isActive,
           let currentPayload = try? authFileManager.readCurrentAuth(),
           let validatedCurrentPayload = try? currentPayload.validated(),
           validatedCurrentPayload.accountIdentifier == account.codexAccountID
        {
            try save(validatedCurrentPayload, for: account.id)
            return validatedCurrentPayload
        }

        throw CredentialStoreError.itemNotFound
    }

    func load(for accountID: UUID) throws -> CodexAuthPayload {
        try loadPersistentCache(allowRecovery: true)

        guard let payload = memoryCache[accountID] else {
            throw CredentialStoreError.itemNotFound
        }
        return payload
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
