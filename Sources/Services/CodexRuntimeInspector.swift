import AppKit
import Foundation

enum SwitchVerificationIssue: Equatable, Sendable {
    case refreshTokenReused
    case generic(String)
}

enum SwitchVerificationResult: Equatable, Sendable {
    case noRunningClient
    case verified
    case restartRecommended
    case authError(SwitchVerificationIssue)
}

enum CodexRuntimeInspectorError: LocalizedError, Equatable {
    case applicationNotFound
    case gracefulShutdownTimedOut
    case relaunchFailed(String)

    var errorDescription: String? {
        switch self {
        case .applicationNotFound:
            return L10n.tr("没有找到本机安装的 Codex.app。")
        case .gracefulShutdownTimedOut:
            return L10n.tr("Codex 没有在预期时间内退出。")
        case let .relaunchFailed(message):
            return L10n.tr("Codex 重新拉起失败：%@", message)
        }
    }
}

final class CodexRuntimeInspector: @unchecked Sendable {
    private static let bundleIdentifier = "com.openai.codex"

    private let logReader: SQLiteLogReader
    private let isRunningClient: @Sendable () -> Bool

    init(
        logReader: SQLiteLogReader,
        isRunningClient: @escaping @Sendable () -> Bool = {
            !NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").isEmpty
        }
    ) {
        self.logReader = logReader
        self.isRunningClient = isRunningClient
    }

    func isCodexDesktopRunning() -> Bool {
        isRunningClient()
    }

    func verifySwitch(after date: Date, timeoutSeconds: TimeInterval = 6) async -> SwitchVerificationResult {
        guard isCodexDesktopRunning() else {
            return .noRunningClient
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let authError = logReader.latestAuthError(after: date) {
                switch authError.kind {
                case .authErrorRefreshTokenReused:
                    return .authError(.refreshTokenReused)
                case .authError:
                    return .authError(.generic(authError.message))
                default:
                    break
                }
            }

            if let signal = logReader.latestRelevantSignal(after: date) {
                switch signal.kind {
                case .rateLimitsUpdated, .authReloadCompleted:
                    return .verified
                case .authReloadStarted:
                    break
                default:
                    break
                }
            }
            try? await Task.sleep(for: .milliseconds(500))
        }

        return .restartRecommended
    }

    func restartCodex() async throws {
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier)
        guard
            let appURL = runningApps.first?.bundleURL
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier)
        else {
            throw CodexRuntimeInspectorError.applicationNotFound
        }

        for app in runningApps {
            _ = app.terminate()
        }

        if !runningApps.isEmpty {
            let deadline = Date().addingTimeInterval(5)
            while isCodexDesktopRunning(), Date() < deadline {
                try? await Task.sleep(for: .milliseconds(250))
            }

            guard !isCodexDesktopRunning() else {
                throw CodexRuntimeInspectorError.gracefulShutdownTimedOut
            }
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
                if let error {
                    continuation.resume(throwing: CodexRuntimeInspectorError.relaunchFailed(error.localizedDescription))
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
}

extension CodexRuntimeInspector: CodexRuntimeInspecting {}
