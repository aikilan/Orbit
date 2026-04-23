import Foundation
import SQLite3
import XCTest
@testable import Orbit

private let COPILOT_QUEUE_SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class CopilotSessionQueueImporterTests: XCTestCase {
    func testListsWorkspaceSessionsAndImportsFullHandoff() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let appSupport = root.appendingPathComponent("app-support", isDirectory: true)
        let workspace = root.appendingPathComponent("next-erp-h5", isDirectory: true)
        let storage = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Code", isDirectory: true)
            .appendingPathComponent("User", isDirectory: true)
            .appendingPathComponent("workspaceStorage", isDirectory: true)
            .appendingPathComponent("storage-1", isDirectory: true)

        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: storage, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: appSupport, withIntermediateDirectories: true)
        try #"{"folder":"\#(workspace.absoluteString)"}"#.write(
            to: storage.appendingPathComponent("workspace.json"),
            atomically: true,
            encoding: .utf8
        )
        try makeStateDatabase(
            at: storage.appendingPathComponent("state.vscdb"),
            index: [
                "version": 1,
                "entries": [
                    "session-1": [
                        "sessionId": "session-1",
                        "title": "修复登录页",
                        "lastMessageDate": 1_710_000_005_000,
                        "hasPendingEdits": true,
                        "isEmpty": false,
                        "lastResponseState": "complete",
                    ],
                ],
            ]
        )

        let chatSessions = storage.appendingPathComponent("chatSessions", isDirectory: true)
        try fileManager.createDirectory(at: chatSessions, withIntermediateDirectories: true)
        try """
        {"kind":0,"v":{"requests":[{"requestId":"r0","timestamp":1710000000000,"agent":"panel","modelId":"gpt-4.1","message":{"text":"先梳理登录流程"}}]}}
        {"kind":1,"k":["requests",0,"response"],"v":{"kind":"markdownContent","value":"登录流程在 src/login.ts。"}}
        {"kind":2,"k":["requests"],"v":{"requestId":"r1","timestamp":1710000001000,"agent":"panel","modelId":"gpt-4.1","message":{"text":"修复 next-erp-h5 登录页空白问题"},"contentReferences":[{"uri":"file:///src/login.ts"}],"editedFileEvents":[{"uri":"file:///src/login.ts","event":"modified"}]}}
        {"kind":2,"k":["requests",1,"response"],"v":[{"kind":"markdownContent","value":"我会修改登录页状态判断。"},{"kind":"toolInvocationSerialized","toolName":"editFile","toolSpecificData":{"uri":"file:///src/login.ts"}}]}
        """.write(
            to: chatSessions.appendingPathComponent("session-1.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let editingStateURL = storage
            .appendingPathComponent("chatEditingSessions", isDirectory: true)
            .appendingPathComponent("session-1", isDirectory: true)
            .appendingPathComponent("state.json", isDirectory: false)
        try fileManager.createDirectory(at: editingStateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"edits":[{"path":"src/login.ts"}]}"#.write(to: editingStateURL, atomically: true, encoding: .utf8)

        let importer = CopilotSessionQueueImporter(
            homeDirectoryURL: home,
            appSupportDirectoryURL: appSupport,
            fileManager: fileManager
        )

        let candidates = try importer.sessions(for: workspace)

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].workspacePath, workspace.standardizedFileURL.path)
        XCTAssertEqual(candidates[0].workspaceStorageID, "storage-1")
        XCTAssertEqual(candidates[0].sessionID, "session-1")
        XCTAssertEqual(candidates[0].title, "修复登录页")
        XCTAssertTrue(candidates[0].hasPendingEdits)

        let item = try importer.importSession(candidates[0])
        let handoff = try String(contentsOfFile: item.handoffFilePath, encoding: .utf8)

        XCTAssertEqual(item.status, .pending)
        XCTAssertTrue(fileManager.fileExists(atPath: item.rawSessionFilePath ?? ""))
        XCTAssertTrue(fileManager.fileExists(atPath: item.editingStateFilePath ?? ""))
        XCTAssertTrue(handoff.contains("先梳理登录流程"))
        XCTAssertTrue(handoff.contains("修复 next-erp-h5 登录页空白问题"))
        XCTAssertTrue(handoff.contains("登录流程在 src/login.ts。"))
        XCTAssertTrue(handoff.contains("editFile"))
        XCTAssertTrue(handoff.contains(#""edits""#))
        XCTAssertTrue(handoff.contains("原始 session JSONL"))
    }

    func testDatabasePersistsQueueMetadataAndDedupeIdentity() throws {
        let item = CopilotSessionQueueItem(
            id: UUID(),
            workspacePath: "/tmp/next-erp-h5",
            workspaceStorageID: "storage",
            sessionID: "session",
            title: "接力",
            createdAt: nil,
            lastMessageAt: Date(timeIntervalSince1970: 1_710_000_000),
            importedAt: Date(),
            status: .pending,
            handoffDirectoryPath: "/tmp/handoff",
            handoffFilePath: "/tmp/handoff/handoff.md",
            rawSessionFilePath: nil,
            editingStateFilePath: nil,
            lastSentAt: nil,
            lastExecutionTarget: nil
        )

        var database = AppDatabase.empty
        database.upsertCopilotSessionQueueItem(item)
        database.upsertCopilotSessionQueueItem(item)
        database.setCopilotSessionAutoMonitorEnabled(true)
        database.markCopilotSessionQueueItemSent(id: item.id, target: .cli)
        database.markCopilotSessionQueueItemMaterialized(
            id: item.id,
            accountID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            codexHomeURL: URL(fileURLWithPath: "/tmp/codex-home", isDirectory: true),
            threadID: "019db9c1-2222-7000-8000-000000000001",
            threadPath: "/tmp/thread.jsonl"
        )

        let data = try JSONEncoder().encode(database)
        let decoded = try JSONDecoder().decode(AppDatabase.self, from: data)

        XCTAssertEqual(decoded.version, AppDatabase.currentVersion)
        XCTAssertEqual(decoded.copilotSessionQueueItems.count, 1)
        XCTAssertEqual(decoded.copilotSessionQueueItems[0].status, .sent)
        XCTAssertEqual(decoded.copilotSessionQueueItems[0].lastExecutionTarget, .desktop)
        XCTAssertEqual(decoded.copilotSessionQueueItems[0].codexThreadID, "019db9c1-2222-7000-8000-000000000001")
        XCTAssertEqual(decoded.copilotSessionQueueItems[0].codexThreadPath, "/tmp/thread.jsonl")
        XCTAssertEqual(decoded.copilotSessionQueueItems[0].codexThreadAccountID?.uuidString, "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        XCTAssertEqual(decoded.copilotSessionQueueItems[0].codexThreadCodexHomePath, "/tmp/codex-home")
        XCTAssertNotNil(decoded.copilotSessionQueueItems[0].materializedAt)
        XCTAssertEqual(decoded.copilotSessionSyncSettings.monitoredWorkspacePaths, ["/tmp/next-erp-h5"])
        XCTAssertTrue(decoded.copilotSessionSyncSettings.isAutoMonitorEnabled)
    }

    private func makeStateDatabase(at url: URL, index: [String: Any]) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }

        XCTAssertEqual(sqlite3_exec(database, "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB);", nil, nil, nil), SQLITE_OK)
        let data = try JSONSerialization.data(withJSONObject: index)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, "INSERT INTO ItemTable (key, value) VALUES (?, ?);", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, "chat.ChatSessionStore.index", -1, COPILOT_QUEUE_SQLITE_TRANSIENT)
        _ = data.withUnsafeBytes { buffer in
            sqlite3_bind_blob(statement, 2, buffer.baseAddress, Int32(data.count), COPILOT_QUEUE_SQLITE_TRANSIENT)
        }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    }
}
