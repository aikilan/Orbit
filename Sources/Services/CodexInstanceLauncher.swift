import AppKit
import Foundation

enum CodexInstanceLauncherError: LocalizedError, Equatable {
    case applicationNotFound
    case executableNotFound

    var errorDescription: String? {
        switch self {
        case .applicationNotFound:
            return L10n.tr("没有找到本机安装的 Codex.app。")
        case .executableNotFound:
            return L10n.tr("Codex.app 的可执行文件不存在或不可执行。")
        }
    }
}

struct CodexInstanceLauncher {
    private static let bundleIdentifier = "com.openai.codex"
    private static let instancesDirectoryName = "isolated-codex-instances"

    private let fileManager: FileManager
    private let resolveAppURL: () -> URL?
    private let runProcess: (URL, [String], [String: String]) throws -> Void

    init(
        fileManager: FileManager = .default,
        resolveAppURL: @escaping () -> URL? = Self.resolveInstalledCodexAppURL,
        runProcess: @escaping (URL, [String], [String: String]) throws -> Void = Self.runCodexProcess
    ) {
        self.fileManager = fileManager
        self.resolveAppURL = resolveAppURL
        self.runProcess = runProcess
    }

    func launchIsolatedInstance(
        for account: ManagedAccount,
        payload: CodexAuthPayload,
        appSupportDirectoryURL: URL
    ) throws -> IsolatedCodexLaunchPaths {
        guard let appURL = resolveAppURL() else {
            throw CodexInstanceLauncherError.applicationNotFound
        }

        let executableURL = executableURL(for: appURL)
        guard isExecutableFile(at: executableURL) else {
            throw CodexInstanceLauncherError.executableNotFound
        }

        let paths = isolatedLaunchPaths(for: account, appSupportDirectoryURL: appSupportDirectoryURL)
        try fileManager.createDirectory(at: paths.codexHomeURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.userDataURL, withIntermediateDirectories: true)

        let authFileURL = paths.codexHomeURL.appendingPathComponent("auth.json")
        try AuthFileManager(authFileURL: authFileURL, fileManager: fileManager).activate(payload)

        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = paths.codexHomeURL.path

        try runProcess(
            executableURL,
            ["--user-data-dir=\(paths.userDataURL.path)"],
            environment
        )

        return paths
    }

    private func isolatedLaunchPaths(
        for account: ManagedAccount,
        appSupportDirectoryURL: URL
    ) -> IsolatedCodexLaunchPaths {
        let rootDirectoryURL = appSupportDirectoryURL
            .appendingPathComponent(Self.instancesDirectoryName, isDirectory: true)
            .appendingPathComponent(account.id.uuidString, isDirectory: true)

        return IsolatedCodexLaunchPaths(
            rootDirectoryURL: rootDirectoryURL,
            codexHomeURL: rootDirectoryURL.appendingPathComponent("codex-home", isDirectory: true),
            userDataURL: rootDirectoryURL.appendingPathComponent("user-data", isDirectory: true)
        )
    }

    private func executableURL(for appURL: URL) -> URL {
        if let executableURL = Bundle(url: appURL)?.executableURL,
           isExecutableFile(at: executableURL) {
            return URL(fileURLWithPath: executableURL.path)
        }

        let executableName = appURL.deletingPathExtension().lastPathComponent
        return appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent(executableName, isDirectory: false)
    }

    private func isExecutableFile(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        return fileManager.isExecutableFile(atPath: url.path)
    }

    private static func resolveInstalledCodexAppURL() -> URL? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first?.bundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    private static func runCodexProcess(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]
    ) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}

extension CodexInstanceLauncher: CodexInstanceLaunching {}
