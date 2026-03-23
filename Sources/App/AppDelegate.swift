import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let exportRequest = IconExportRequest.current {
            NSApp.setActivationPolicy(.prohibited)
            do {
                try AppIconArtwork.exportAssets(to: exportRequest.outputDirectory)
            } catch {
                fputs("\(L10n.tr("导出图标失败: %@", error.localizedDescription))\n", stderr)
            }
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.regular)
        AppIconArtwork.applyApplicationIcon()

        if let model = AppRuntime.shared.model {
            installStatusBarControllerIfNeeded(with: model)
        }
    }

    func installStatusBarControllerIfNeeded(with model: AppViewModel) {
        guard statusBarController == nil else { return }

        statusBarController = StatusBarController(model: model) { [weak self] id in
            self?.presentWindow(id: id, using: model)
        }
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
            case "Codex Account Switcher":
                window.title = L10n.tr("Codex Account Switcher")
            case "新增账号", "Add Account":
                window.title = L10n.tr("新增账号")
            default:
                break
            }
        }
    }
}
