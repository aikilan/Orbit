import Foundation
import SQLite3
import XCTest
@testable import Orbit

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class CodexRuntimeInspectorTests: XCTestCase {
    func testLatestRelevantSignalUsesNanosecondPrecision() throws {
        let databaseURL = try makeLogDatabase(entries: [
            LogEntry(
                ts: 1_773_000_000,
                tsNanos: 500,
                level: "TRACE",
                target: "codex_app_server::outgoing_message",
                message: "app-server event: Reloaded auth, changed: account"
            )
        ])
        let reader = SQLiteLogReader(databaseURL: databaseURL)

        let signal = try XCTUnwrap(reader.latestRelevantSignal(after: Date(timeIntervalSince1970: 1_773_000_000)))

        XCTAssertEqual(signal.kind, .authReloadCompleted)
    }

    func testLatestAuthErrorDetectsRefreshTokenReused() throws {
        let databaseURL = try makeLogDatabase(entries: [
            LogEntry(
                ts: 1_773_000_001,
                tsNanos: 900,
                level: "ERROR",
                target: "codex_core::auth",
                message: "Failed to refresh token: code=refresh_token_reused"
            )
        ])
        let reader = SQLiteLogReader(databaseURL: databaseURL)

        let signal = try XCTUnwrap(reader.latestAuthError(after: Date(timeIntervalSince1970: 1_773_000_000)))

        XCTAssertEqual(signal.kind, .authErrorRefreshTokenReused)
    }

    func testVerifySwitchReturnsAuthErrorWhenCodexUsesOldRefreshToken() async throws {
        let databaseURL = try makeLogDatabase(entries: [
            LogEntry(
                ts: 1_773_000_010,
                tsNanos: 1_000,
                level: "ERROR",
                target: "codex_core::auth",
                message: "Failed to refresh token: Your refresh token was already used. code=refresh_token_reused"
            )
        ])
        let inspector = CodexRuntimeInspector(
            logReader: SQLiteLogReader(databaseURL: databaseURL),
            isRunningClient: { true }
        )

        let result = await inspector.verifySwitch(after: Date(timeIntervalSince1970: 1_773_000_009), timeoutSeconds: 0.1)

        XCTAssertEqual(result, .authError(.refreshTokenReused))
    }

    func testVerifySwitchReturnsVerifiedWhenReloadSignalAppears() async throws {
        let databaseURL = try makeLogDatabase(entries: [
            LogEntry(
                ts: 1_773_000_011,
                tsNanos: 1_500,
                level: "TRACE",
                target: "codex_app_server::outgoing_message",
                message: "app-server event: account/rateLimits/updated"
            )
        ])
        let inspector = CodexRuntimeInspector(
            logReader: SQLiteLogReader(databaseURL: databaseURL),
            isRunningClient: { true }
        )

        let result = await inspector.verifySwitch(after: Date(timeIntervalSince1970: 1_773_000_010), timeoutSeconds: 0.1)

        XCTAssertEqual(result, .verified)
    }

    private func makeLogDatabase(entries: [LogEntry]) throws -> URL {
        let databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close(database) }

        let createTable = """
        CREATE TABLE logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts INTEGER NOT NULL,
            ts_nanos INTEGER NOT NULL,
            level TEXT NOT NULL,
            target TEXT NOT NULL,
            message TEXT,
            module_path TEXT,
            file TEXT,
            line INTEGER,
            thread_id TEXT,
            process_uuid TEXT,
            estimated_bytes INTEGER NOT NULL DEFAULT 0
        );
        """
        guard sqlite3_exec(database, createTable, nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }

        let insertSQL = """
        INSERT INTO logs (ts, ts_nanos, level, target, message, estimated_bytes)
        VALUES (?, ?, ?, ?, ?, 0);
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, insertSQL, -1, &statement, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_finalize(statement) }

        for entry in entries {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_int64(statement, 1, entry.ts)
            sqlite3_bind_int64(statement, 2, entry.tsNanos)
            sqlite3_bind_text(statement, 3, entry.level, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 4, entry.target, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 5, entry.message, -1, SQLITE_TRANSIENT)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw CocoaError(.fileWriteUnknown)
            }
        }

        return databaseURL
    }
}

private struct LogEntry {
    let ts: Int64
    let tsNanos: Int64
    let level: String
    let target: String
    let message: String
}
