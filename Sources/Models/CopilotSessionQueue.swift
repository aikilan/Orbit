import Foundation

enum CopilotSessionQueueItemStatus: String, Codable, Hashable, Sendable {
    case pending
    case sent
    case archived
}

enum CopilotSessionQueueExecutionTarget: String, Codable, Hashable, Sendable {
    case cli
    case desktop
}

struct CopilotSessionQueueItem: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var workspacePath: String
    var workspaceStorageID: String
    var sessionID: String
    var title: String
    var createdAt: Date?
    var lastMessageAt: Date
    var importedAt: Date
    var status: CopilotSessionQueueItemStatus
    var handoffDirectoryPath: String
    var handoffFilePath: String
    var rawSessionFilePath: String?
    var editingStateFilePath: String?
    var codexThreadID: String?
    var codexThreadPath: String?
    var codexThreadAccountID: UUID?
    var codexThreadCodexHomePath: String?
    var materializedAt: Date?
    var lastSentAt: Date?
    var lastExecutionTarget: CopilotSessionQueueExecutionTarget?
}

struct CopilotSessionSyncSettings: Codable, Hashable, Sendable {
    var isAutoMonitorEnabled: Bool = false
    var monitoredWorkspacePaths: [String] = []
}

extension CopilotSessionQueueItem {
    func matchesImportIdentity(of other: CopilotSessionQueueItem) -> Bool {
        workspacePath == other.workspacePath
            && sessionID == other.sessionID
            && lastMessageAt == other.lastMessageAt
    }
}
