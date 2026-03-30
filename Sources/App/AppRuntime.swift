import Foundation

@MainActor
final class AppRuntime {
    static let shared = AppRuntime()

    var model: AppViewModel?
    var sessionLogger: AppSessionLogger?
}
