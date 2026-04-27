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
        installWindowObservers()

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
        restoreDockPresenceIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        WindowRouter.shared.openWindow(id: id)
        refreshWindowTitles()

        DispatchQueue.main.async {
            self.refreshWindowTitles()
            WindowRouter.shared.focusExistingWindow(for: id)
            self.restoreDockPresenceIfNeeded()
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
            case "预设启动 Codex", "Launch Codex Preset":
                window.title = L10n.tr("预设启动 Codex")
            case "ACP 调试", "ACP Debug":
                window.title = L10n.tr("ACP 调试")
            default:
                break
            }
        }
        configureWindowDelegates()
    }

    private func installWindowObservers() {
        let notificationCenter = NotificationCenter.default
        notificationCenter.addObserver(
            self,
            selector: #selector(handleWindowVisibilityChanged(_:)),
            name: NSWindow.didBecomeMainNotification,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(handleWindowVisibilityChanged(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
    }

    @objc
    private func handleWindowVisibilityChanged(_ notification: Notification) {
        configureWindowDelegates()
    }

    @objc
    private func handleMainWindowMiniaturize(_ sender: Any?) {
        guard let button = sender as? NSButton,
              let window = button.window,
              isOrbitWindow(window)
        else {
            NSApp.keyWindow?.miniaturize(sender)
            return
        }
        hideMainWindowToStatusBar(window)
    }

    private func configureWindowDelegates() {
        for window in NSApp.windows where isOrbitWindow(window) {
            window.delegate = self
            window.standardWindowButton(.miniaturizeButton)?.target = self
            window.standardWindowButton(.miniaturizeButton)?.action = #selector(handleMainWindowMiniaturize(_:))
        }
    }

    private func isOrbitWindow(_ window: NSWindow) -> Bool {
        [
            L10n.tr("Orbit"),
            "Orbit",
        ].contains(window.title)
    }

    private func hideMainWindowToStatusBar(_ window: NSWindow) {
        AppRuntime.shared.sessionLogger?.info("window.hide_to_status_bar", metadata: ["title": window.title])
        window.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        AppRuntime.shared.sessionLogger?.info("activation_policy.set", metadata: ["policy": "accessory"])
    }

    private func restoreDockPresenceIfNeeded() {
        guard NSApp.activationPolicy() != .regular else { return }
        NSApp.setActivationPolicy(.regular)
        AppRuntime.shared.sessionLogger?.info("activation_policy.set", metadata: ["policy": "regular"])
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard isOrbitWindow(sender) else { return true }
        hideMainWindowToStatusBar(sender)
        return false
    }

    func windowDidMiniaturize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              isOrbitWindow(window)
        else { return }

        window.deminiaturize(nil)
        hideMainWindowToStatusBar(window)
    }
}
