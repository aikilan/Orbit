import SwiftUI

@main
struct OrbitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(AppAppearancePreference.storageKey) private var appearancePreference = AppAppearancePreference.system.rawValue
    @StateObject private var model: AppViewModel

    init() {
        let logger = try? AppSessionLogger.live()
        logger?.info("app_init.begin")

        let liveModel = AppViewModel.live(sessionLogger: logger)
        _model = StateObject(wrappedValue: liveModel)
        AppRuntime.shared.model = liveModel
        AppRuntime.shared.sessionLogger = logger
        logger?.info("app_init.end")
    }

    var body: some Scene {
        Window(L10n.tr("Orbit"), id: "accounts") {
            ContentView(model: model)
                .preferredColorScheme(preferredColorScheme)
                .frame(minWidth: 960, minHeight: 620)
        }

        Window(L10n.tr("新增账号"), id: "add-account") {
            AddAccountSheet(model: model)
                .preferredColorScheme(preferredColorScheme)
                .frame(minWidth: 620, minHeight: 520)
        }

        Window(L10n.tr("预设启动 Codex"), id: "launch-provider-desktop") {
            ProviderDesktopLaunchSheet(model: model)
                .preferredColorScheme(preferredColorScheme)
                .frame(minWidth: 620, minHeight: 460)
        }

        Window(L10n.tr("ACP 调试"), id: "copilot-acp-debug") {
            CopilotACPDebugView(store: model.copilotACPDebugStore)
                .preferredColorScheme(preferredColorScheme)
                .frame(minWidth: 980, minHeight: 640)
        }

        Window(L10n.tr("Bridge 调试"), id: "provider-bridge-debug") {
            ProviderBridgeDebugView(store: model.providerBridgeDebugStore)
                .preferredColorScheme(preferredColorScheme)
                .frame(minWidth: 980, minHeight: 640)
        }
    }

    private var preferredColorScheme: ColorScheme? {
        AppAppearancePreference.resolved(from: appearancePreference).colorScheme
    }
}
