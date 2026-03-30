import Foundation

enum AppSessionLogLevel: String {
    case info = "INFO"
    case warning = "WARNING"
    case error = "ERROR"
}

final class AppSessionLogger {
    let logsDirectoryURL: URL
    let latestLogURL: URL

    private let fileManager: FileManager
    private let processIdentifier: Int32
    private let homeDirectoryPath: String
    private let dateProvider: () -> Date
    private let queue = DispatchQueue(label: "Orbit.AppSessionLogger")
    private let iso8601Formatter: ISO8601DateFormatter
    private let archiveNameFormatter: DateFormatter
    private var handle: FileHandle?

    static func live(
        fileManager: FileManager = .default,
        processInfo: ProcessInfo = .processInfo,
        applicationSupportRootOverride: URL? = nil,
        dateProvider: @escaping () -> Date = Date.init
    ) throws -> AppSessionLogger {
        let appSupportDirectoryURL = try AppPaths.resolveDefaultAppSupportDirectory(
            fileManager: fileManager,
            rootOverride: applicationSupportRootOverride
        )
        return try AppSessionLogger(
            appSupportDirectoryURL: appSupportDirectoryURL,
            fileManager: fileManager,
            processInfo: processInfo,
            dateProvider: dateProvider
        )
    }

    init(
        appSupportDirectoryURL: URL,
        fileManager: FileManager = .default,
        processInfo: ProcessInfo = .processInfo,
        dateProvider: @escaping () -> Date = Date.init
    ) throws {
        self.fileManager = fileManager
        self.processIdentifier = processInfo.processIdentifier
        self.homeDirectoryPath = fileManager.homeDirectoryForCurrentUser.path
        self.dateProvider = dateProvider
        self.logsDirectoryURL = appSupportDirectoryURL.appendingPathComponent("logs", isDirectory: true)
        self.latestLogURL = logsDirectoryURL.appendingPathComponent("latest.log", isDirectory: false)

        let iso8601Formatter = ISO8601DateFormatter()
        iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.iso8601Formatter = iso8601Formatter

        let archiveNameFormatter = DateFormatter()
        archiveNameFormatter.locale = Locale(identifier: "en_US_POSIX")
        archiveNameFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        archiveNameFormatter.dateFormat = "yyyyMMdd-HHmmss"
        self.archiveNameFormatter = archiveNameFormatter

        try fileManager.createDirectory(at: logsDirectoryURL, withIntermediateDirectories: true)
        try archiveLatestLogIfNeeded()
        fileManager.createFile(atPath: latestLogURL.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: latestLogURL)
        try self.handle?.seekToEnd()
    }

    deinit {
        close()
    }

    func close() {
        queue.sync {
            try? handle?.close()
            handle = nil
        }
    }

    func info(_ event: String, metadata: [String: String] = [:]) {
        log(level: .info, event: event, metadata: metadata)
    }

    func warning(_ event: String, metadata: [String: String] = [:]) {
        log(level: .warning, event: event, metadata: metadata)
    }

    func error(_ event: String, metadata: [String: String] = [:]) {
        log(level: .error, event: event, metadata: metadata)
    }

    func log(level: AppSessionLogLevel, event: String, metadata: [String: String] = [:]) {
        queue.sync {
            guard let handle else { return }

            let timestamp = iso8601Formatter.string(from: dateProvider())
            let renderedMetadata = metadata
                .sorted { $0.key < $1.key }
                .map { key, value in
                    "\(key)=\(renderMetadataValue(forKey: key, value: value))"
                }
                .joined(separator: " ")
            let suffix = renderedMetadata.isEmpty ? "" : " \(renderedMetadata)"
            let line = "\(timestamp) [\(level.rawValue)] \(event)\(suffix)\n"

            do {
                try handle.write(contentsOf: Data(line.utf8))
                try handle.synchronize()
            } catch {}
        }
    }

    private func archiveLatestLogIfNeeded() throws {
        guard fileManager.fileExists(atPath: latestLogURL.path) else {
            trimArchivedLogsIfNeeded()
            return
        }

        let archiveURL = nextArchiveURL()
        try fileManager.moveItem(at: latestLogURL, to: archiveURL)
        trimArchivedLogsIfNeeded()
    }

    private func nextArchiveURL() -> URL {
        let baseName = "launch-\(archiveNameFormatter.string(from: dateProvider()))-\(processIdentifier)"
        var candidateURL = logsDirectoryURL.appendingPathComponent("\(baseName).log", isDirectory: false)
        var index = 1

        while fileManager.fileExists(atPath: candidateURL.path) {
            candidateURL = logsDirectoryURL.appendingPathComponent("\(baseName)-\(index).log", isDirectory: false)
            index += 1
        }

        return candidateURL
    }

    private func trimArchivedLogsIfNeeded() {
        guard let archivedLogURLs = try? fileManager.contentsOfDirectory(
            at: logsDirectoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        let archivedLogs = archivedLogURLs
            .filter {
                $0.lastPathComponent.hasPrefix("launch-")
                    && $0.pathExtension == "log"
            }
            .sorted {
                $0.lastPathComponent > $1.lastPathComponent
            }

        guard archivedLogs.count > 10 else { return }
        for url in archivedLogs.dropFirst(10) {
            try? fileManager.removeItem(at: url)
        }
    }

    private func renderMetadataValue(forKey key: String, value: String) -> String {
        if isSensitiveKey(key) {
            return "<redacted>"
        }

        let sanitized = sanitize(value)
        if sanitized.isEmpty {
            return "\"\""
        }
        if sanitized.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "=" }) {
            let escaped = sanitized.replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        return sanitized
    }

    private func sanitize(_ value: String) -> String {
        let normalizedPath: String
        if value == homeDirectoryPath {
            normalizedPath = "~"
        } else if value.hasPrefix(homeDirectoryPath + "/") {
            normalizedPath = "~" + String(value.dropFirst(homeDirectoryPath.count))
        } else {
            normalizedPath = value
        }
        return normalizedPath.replacingOccurrences(of: "\n", with: "\\n")
    }

    private func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key.lowercased()
        return normalized.contains("token")
            || normalized.contains("apikey")
            || normalized.contains("api_key")
            || normalized.contains("authorization")
            || normalized.contains("header")
            || normalized.contains("payload")
    }
}
