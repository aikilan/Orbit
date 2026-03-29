import SwiftUI

@main
struct OrbitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: AppViewModel

    init() {
        let liveModel = AppViewModel.live()
        _model = StateObject(wrappedValue: liveModel)
        AppRuntime.shared.model = liveModel
    }

    var body: some Scene {
        Window(L10n.tr("Orbit"), id: "accounts") {
            ContentView(model: model)
                .frame(minWidth: 960, minHeight: 620)
        }

        Window(L10n.tr("新增账号"), id: "add-account") {
            AddAccountSheet(model: model)
                .frame(minWidth: 620, minHeight: 520)
        }
    }
}
