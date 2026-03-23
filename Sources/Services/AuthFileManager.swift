import Foundation

enum AuthFileManagerError: LocalizedError, Equatable {
    case missingAuthFile
    case schemaValidationFailed(String)
    case couldNotRestoreBackup

    var errorDescription: String? {
        switch self {
        case .missingAuthFile:
            return L10n.tr("没有找到 ~/.codex/auth.json。")
        case let .schemaValidationFailed(message):
            return L10n.tr("auth.json 校验失败：%@", message)
        case .couldNotRestoreBackup:
            return L10n.tr("auth.json 写入失败且无法恢复备份。")
        }
    }
}

struct AuthFileManager {
    let authFileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let overwriteExistingContents: (URL, Data) throws -> Void

    init(
        authFileURL: URL,
        fileManager: FileManager = .default,
        overwriteExistingContents: @escaping (URL, Data) throws -> Void = AuthFileManager.overwriteExistingContents
    ) {
        self.authFileURL = authFileURL
        self.fileManager = fileManager
        self.overwriteExistingContents = overwriteExistingContents

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        self.decoder = JSONDecoder()
    }

    func readCurrentAuth() throws -> CodexAuthPayload? {
        guard fileManager.fileExists(atPath: authFileURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: authFileURL)
        let payload = try decoder.decode(CodexAuthPayload.self, from: data)
        return try payload.validated()
    }

    func activate(_ payload: CodexAuthPayload) throws {
        try activatePreservingFileIdentity(payload)
    }

    func activatePreservingFileIdentity(_ payload: CodexAuthPayload) throws {
        let validatedPayload = try payload.validated()
        let directoryURL = authFileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let backupURL = authFileURL.appendingPathExtension("bak")
        let tempURL = authFileURL.appendingPathExtension("tmp-\(UUID().uuidString)")
        let encoded = try encoder.encode(validatedPayload)

        if fileManager.fileExists(atPath: authFileURL.path) {
            do {
                _ = try readCurrentAuth()
                if fileManager.fileExists(atPath: backupURL.path) {
                    try fileManager.removeItem(at: backupURL)
                }
                try fileManager.copyItem(at: authFileURL, to: backupURL)
            } catch {
                throw AuthFileManagerError.schemaValidationFailed(error.localizedDescription)
            }
        }

        do {
            if fileManager.fileExists(atPath: authFileURL.path) {
                try overwriteExistingContents(authFileURL, encoded)
            } else {
                try encoded.write(to: tempURL, options: .atomic)
                try fileManager.moveItem(at: tempURL, to: authFileURL)
            }
        } catch {
            if fileManager.fileExists(atPath: backupURL.path) {
                do {
                    let backupData = try Data(contentsOf: backupURL)
                    try backupData.write(to: authFileURL, options: .atomic)
                } catch {
                    throw AuthFileManagerError.couldNotRestoreBackup
                }
            }
            throw error
        }
    }

    func clearAuthFile() throws {
        guard fileManager.fileExists(atPath: authFileURL.path) else { return }
        try fileManager.removeItem(at: authFileURL)
    }

    private static func overwriteExistingContents(at url: URL, with data: Data) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer {
            try? handle.close()
        }

        try handle.truncate(atOffset: 0)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }
}

extension AuthFileManager: AuthFileManaging {}
