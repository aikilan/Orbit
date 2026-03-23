import AppKit
import SwiftUI

@MainActor
final class WindowRouter {
    static let shared = WindowRouter()

    private var openWindowHandler: ((String) -> Void)?

    func register(_ handler: @escaping (String) -> Void) {
        openWindowHandler = handler
    }

    func openWindow(id: String) {
        openWindowHandler?(id)
        focusExistingWindow(for: id)

        DispatchQueue.main.async { [weak self] in
            self?.focusExistingWindow(for: id)
        }
    }

    func focusExistingWindow(for id: String) {
        existingWindow(for: id)?.makeKeyAndOrderFront(nil)
    }

    private func existingWindow(for id: String) -> NSWindow? {
        let titles: [String]

        switch id {
        case "accounts":
            titles = [L10n.tr("Codex Account Switcher")]
        case "add-account":
            titles = [L10n.tr("新增账号"), "新增账号", "Add Account"]
        default:
            titles = []
        }

        guard !titles.isEmpty else { return nil }
        return NSApp.windows.first(where: { titles.contains($0.title) })
    }
}

@MainActor
final class StatusBarController: NSObject {
    private static let popoverWidth: CGFloat = 360
    private static let defaultPopoverHeight: CGFloat = 240

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let model: AppViewModel
    private let openWindow: (String) -> Void
    private var pendingSingleClickWorkItem: DispatchWorkItem?

    init(model: AppViewModel, openWindow: @escaping (String) -> Void) {
        self.model = model
        self.openWindow = openWindow
        super.init()

        configureStatusItem()
        configurePopover()
    }

    @objc
    private func handleStatusItemClick(_ sender: Any?) {
        guard let button = sender as? NSStatusBarButton else {
            openMainPanel()
            return
        }

        guard let event = NSApp.currentEvent else {
            openMainPanel()
            return
        }

        switch event.type {
        case .rightMouseUp:
            cancelPendingSingleClick()
            togglePopover(relativeTo: button)
        case .leftMouseUp:
            if event.clickCount >= 2 {
                cancelPendingSingleClick()
                togglePopover(relativeTo: button)
            } else {
                scheduleSingleClick()
            }
        default:
            openMainPanel()
        }
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }

        button.image = AppIconArtwork.menuBarIcon
        button.imageScaling = .scaleProportionallyDown
        button.imagePosition = .imageOnly
        button.toolTip = L10n.tr("Codex Account Switcher")
        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func configurePopover() {
        let rootView = AnyView(
            MenuBarContentView(
                model: model,
                onOpenAccounts: { [weak self] in
                    self?.openAccountsFromPopover()
                },
                onOpenAddAccount: { [weak self] in
                    self?.openAddAccountFromPopover()
                },
                onPreferredHeightChange: { [weak self] height in
                    self?.updatePopoverHeight(height)
                }
            )
        )

        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: Self.popoverWidth, height: Self.defaultPopoverHeight)
        popover.contentViewController = NSHostingController(rootView: rootView)
    }

    func refreshLocalization() {
        statusItem.button?.toolTip = L10n.tr("Codex Account Switcher")
    }

    private func updatePopoverHeight(_ height: CGFloat) {
        let resolvedHeight = height > 0 ? ceil(height) : Self.defaultPopoverHeight
        guard abs(popover.contentSize.height - resolvedHeight) > 1 else { return }
        popover.contentSize = NSSize(width: Self.popoverWidth, height: resolvedHeight)
    }

    private func scheduleSingleClick() {
        cancelPendingSingleClick()

        let workItem = DispatchWorkItem { [weak self] in
            self?.openMainPanel()
        }

        pendingSingleClickWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: workItem)
    }

    private func cancelPendingSingleClick() {
        pendingSingleClickWorkItem?.cancel()
        pendingSingleClickWorkItem = nil
    }

    private func openMainPanel() {
        popover.performClose(nil)
        openWindow("accounts")
    }

    private func openAccountsFromPopover() {
        popover.performClose(nil)
        openWindow("accounts")
    }

    private func openAddAccountFromPopover() {
        popover.performClose(nil)
        openWindow("add-account")
    }

    private func togglePopover(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
