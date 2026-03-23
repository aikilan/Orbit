import Foundation

protocol CredentialStore {
    func save(_ payload: CodexAuthPayload, for accountID: UUID) throws
    func load(for accountID: UUID) throws -> CodexAuthPayload
    func delete(for accountID: UUID) throws
}

enum CredentialStoreError: LocalizedError, Equatable {
    case itemNotFound
    case unexpectedData

    var errorDescription: String? {
        switch self {
        case .itemNotFound:
            return L10n.tr("没有找到该账号的本地凭据。")
        case .unexpectedData:
            return L10n.tr("本地凭据格式无效。")
        }
    }
}
