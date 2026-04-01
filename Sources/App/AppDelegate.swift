import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppRuntime.shared.sessionLogger?.info("did_finish_launching.begin")

        if let exportRequest = IconExportRequest.current {
            NSApp.setActivationPolicy(.prohibited)
            AppRuntime.shared.sessionLogger?.info("activation_policy.set", metadata: ["policy": "prohibited"])
            do {
                try AppIconArtwork.exportAssets(to: exportRequest.outputDirectory)
                AppRuntime.shared.sessionLogger?.info("icon_export.complete")
            } catch {
                AppRuntime.shared.sessionLogger?.error("icon_export.failure", metadata: ["error": error.localizedDescription])
                fputs("\(L10n.tr("导出图标失败: %@", error.localizedDescription))\n", stderr)
            }
            AppRuntime.shared.sessionLogger?.info("application_terminate.requested", metadata: ["reason": "icon_export"])
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.regular)
        AppRuntime.shared.sessionLogger?.info("activation_policy.set", metadata: ["policy": "regular"])
        AppIconArtwork.applyApplicationIcon()
        AppRuntime.shared.sessionLogger?.info("application_icon.applied")

        if let model = AppRuntime.shared.model {
            installStatusBarControllerIfNeeded(with: model)
        } else {
            AppRuntime.shared.sessionLogger?.warning("status_bar.install.skipped", metadata: ["reason": "model_missing"])
        }
    }

    func installStatusBarControllerIfNeeded(with model: AppViewModel) {
        guard statusBarController == nil else {
            AppRuntime.shared.sessionLogger?.info("status_bar.install.skipped", metadata: ["reason": "already_installed"])
            return
        }

        statusBarController = StatusBarController(model: model) { [weak self] id in
            self?.presentWindow(id: id, using: model)
        }
        AppRuntime.shared.sessionLogger?.info("status_bar.install.complete")
    }

    func refreshLocalization() {
        refreshWindowTitles()
        statusBarController?.refreshLocalization()
    }

    private func presentWindow(id: String, using model: AppViewModel) {
        model.noteProgrammaticActivation()
        NSApp.activate(ignoringOtherApps: true)
        WindowRouter.shared.openWindow(id: id)
        refreshWindowTitles()

        DispatchQueue.main.async {
            self.refreshWindowTitles()
            WindowRouter.shared.focusExistingWindow(for: id)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func refreshWindowTitles() {
        for window in NSApp.windows {
            switch window.title {
            case "Orbit":
                window.title = L10n.tr("Orbit")
            case "新增账号", "Add Account":
                window.title = L10n.tr("新增账号")
            case "预设启动 Codex":
                window.title = L10n.tr("预设启动 Codex")
            default:
                break
            }
        }
    }
}
