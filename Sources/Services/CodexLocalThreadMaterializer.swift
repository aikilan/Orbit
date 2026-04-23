import Foundation

enum CodexLocalThreadMaterializerError: LocalizedError {
    case appServerError(String)
    case invalidResponse(String)
    case processExited(String)

    var errorDescription: String? {
        switch self {
        case let .appServerError(message):
            return L10n.tr("Codex app-server 返回错误：%@", message)
        case let .invalidResponse(message):
            return L10n.tr("Codex app-server 响应格式无效：%@", message)
        case let .processExited(message):
            return L10n.tr("Codex app-server 已退出：%@", message)
        }
    }
}

final class CodexLocalThreadMaterializer: @unchecked Sendable {
    private let fileManager: FileManager
    private let executableURL: @Sendable () -> URL
    private let baseArguments: @Sendable () -> [String]
    private let runProcess: @Sendable (Process) throws -> Void

    init(
        fileManager: FileManager = .default,
        executableURL: @escaping @Sendable () -> URL = { URL(fileURLWithPath: "/usr/bin/env", isDirectory: false) },
        baseArguments: @escaping @Sendable () -> [String] = { ["codex"] },
        runProcess: @escaping @Sendable (Process) throws -> Void = { try $0.run() }
    ) {
        self.fileManager = fileManager
        self.executableURL = executableURL
        self.baseArguments = baseArguments
        self.runProcess = runProcess
    }
}

extension CodexLocalThreadMaterializer: CodexLocalThreadMaterializing {
    func materializeCopilotSessionQueueItem(
        _ item: CopilotSessionQueueItem,
        context: ResolvedCodexLocalThreadMaterializationContext,
        developerInstructions: String
    ) async throws -> MaterializedCodexThread {
        try await Task.detached(priority: .userInitiated) {
            try self.materializeCopilotSessionQueueItemSync(
                item,
                context: context,
                developerInstructions: developerInstructions
            )
        }.value
    }
}

private extension CodexLocalThreadMaterializer {
    func materializeCopilotSessionQueueItemSync(
        _ item: CopilotSessionQueueItem,
        context: ResolvedCodexLocalThreadMaterializationContext,
        developerInstructions: String
    ) throws -> MaterializedCodexThread {
        let client = try makeClient(context: context)
        defer { client.close() }

        _ = try client.send(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "orbit",
                    "title": "Orbit",
                    "version": "1",
                ],
                "capabilities": [
                    "experimentalApi": false,
                ],
            ]
        )

        let startResult = try client.send(
            method: "thread/start",
            params: [
                "cwd": item.workspacePath,
                "serviceName": "Orbit Copilot Handoff",
                "developerInstructions": developerInstructions,
                "ephemeral": false,
                "experimentalRawEvents": false,
                "persistExtendedHistory": true,
            ]
        )
        let thread = try materializedThread(from: startResult)

        _ = try client.send(
            method: "thread/name/set",
            params: [
                "threadId": thread.id,
                "name": item.title,
            ]
        )

        return thread
    }

    func makeClient(context: ResolvedCodexLocalThreadMaterializationContext) throws -> CodexAppServerJSONLClient {
        let process = Process()
        process.executableURL = executableURL()
        process.arguments = baseArguments() + [
            "app-server",
            "--listen",
            "stdio://",
            "--session-source",
            "vscode",
        ]
        process.currentDirectoryURL = context.workingDirectoryURL
        process.environment = try environment(for: context)

        return try CodexAppServerJSONLClient(process: process, runProcess: runProcess)
    }

    func environment(for context: ResolvedCodexLocalThreadMaterializationContext) throws -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in context.environmentVariables {
            environment[key] = value
        }

        if let codexHomeURL = context.codexHomeURL {
            try CodexManagedHomeWriter(fileManager: fileManager).prepareManagedHome(
                codexHomeURL: codexHomeURL,
                authPayload: context.authPayload,
                configFileContents: context.configFileContents,
                modelCatalogSnapshot: context.modelCatalogSnapshot
            )
            environment["CODEX_HOME"] = codexHomeURL.path
        }

        return environment
    }

    func materializedThread(from result: [String: Any]) throws -> MaterializedCodexThread {
        guard let thread = result["thread"] as? [String: Any] else {
            throw CodexLocalThreadMaterializerError.invalidResponse("thread/start 缺少 thread")
        }
        guard let id = thread["id"] as? String, !id.isEmpty else {
            throw CodexLocalThreadMaterializerError.invalidResponse("thread/start 缺少 thread.id")
        }
        return MaterializedCodexThread(
            id: id,
            path: thread["path"] as? String
        )
    }
}

private final class CodexAppServerJSONLClient {
    private let process: Process
    private let stdin: FileHandle
    private let stdout: FileHandle
    private let stderr: FileHandle
    private var requestCounter = 0

    init(
        process: Process,
        runProcess: (Process) throws -> Void
    ) throws {
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        self.process = process
        stdin = inputPipe.fileHandleForWriting
        stdout = outputPipe.fileHandleForReading
        stderr = errorPipe.fileHandleForReading

        try runProcess(process)
    }

    func send(method: String, params: [String: Any]) throws -> [String: Any] {
        requestCounter += 1
        let id = "orbit-\(requestCounter)"
        try write([
            "id": id,
            "method": method,
            "params": params,
        ])

        while true {
            guard let line = readLine() else {
                throw CodexLocalThreadMaterializerError.processExited(stderrText())
            }
            guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                continue
            }
            guard (object["id"] as? String) == id else {
                continue
            }
            if let error = object["error"] as? [String: Any] {
                let message = error["message"] as? String ?? String(describing: error)
                throw CodexLocalThreadMaterializerError.appServerError(message)
            }
            guard let result = object["result"] as? [String: Any] else {
                throw CodexLocalThreadMaterializerError.invalidResponse(method)
            }
            return result
        }
    }

    func close() {
        try? stdin.close()
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }

    private func write(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        stdin.write(data)
        stdin.write(Data([0x0A]))
    }

    private func readLine() -> String? {
        var data = Data()
        while true {
            let byte = stdout.readData(ofLength: 1)
            if byte.isEmpty {
                return data.isEmpty ? nil : String(data: data, encoding: .utf8)
            }
            if byte[byte.startIndex] == 0x0A {
                return String(data: data, encoding: .utf8)
            }
            data.append(byte)
        }
    }

    private func stderrText() -> String {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        return String(data: stderr.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? L10n.tr("未知错误")
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
