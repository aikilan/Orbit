import AppKit
import SwiftUI

private enum SidebarLayoutMetrics {
    static let minWidth: CGFloat = 272
    static let idealWidth: CGFloat = 286
    static let maxWidth: CGFloat = 332
    static let horizontalPadding: CGFloat = 18
    static let sectionVerticalPadding: CGFloat = 18
    static let footerPadding: CGFloat = 18
}

@MainActor
struct ContentView: View {
    @ObservedObject var model: AppViewModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AppAppearancePreference.storageKey) private var appearancePreference = AppAppearancePreference.system.rawValue
    @State private var draggedAccountID: UUID?
    @State private var dropTargetAccountID: UUID?
    @State private var hoveredAccountID: UUID?
    @State private var accountRowFrames: [UUID: CGRect] = [:]
    @State private var accountDragStartFrame: CGRect?
    @State private var accountDragTranslation: CGSize = .zero
    @State private var hasAccountOrderChangesDuringDrag = false
    private let accountListCoordinateSpaceName = "account-list-coordinate-space"

    var body: some View {
        HSplitView {
            accountSidebar
                .frame(
                    minWidth: SidebarLayoutMetrics.minWidth,
                    idealWidth: SidebarLayoutMetrics.idealWidth,
                    maxWidth: SidebarLayoutMetrics.maxWidth,
                    maxHeight: .infinity,
                    alignment: .topLeading
                )

            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OrbitPalette.background)
        .tint(OrbitPalette.accent)
        .preferredColorScheme(resolvedAppearancePreference.colorScheme)
        .task {
            model.sessionLogger?.info("content_task.begin")
            WindowRouter.shared.register { id in
                openWindow(id: id)
            }
            (NSApp.delegate as? AppDelegate)?.installStatusBarControllerIfNeeded(with: model)
            model.sessionLogger?.info("prepare.begin")
            await model.prepare()
            model.sessionLogger?.info("prepare.end")
            model.sessionLogger?.info("reconcile.begin")
            await model.reconcileCurrentAuthState()
            model.sessionLogger?.info("reconcile.end")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await model.reconcileCurrentAuthStateForAppActivation()
            }
        }
        .sheet(item: $model.isolatedCodexModelSelection, onDismiss: {
            model.cancelIsolatedCodexModelSelection()
        }) { _ in
            IsolatedCodexModelSelectionSheet(model: model)
        }
        .confirmationDialog(
            L10n.tr("删除账号"),
            isPresented: Binding(
                get: { model.pendingDeleteAccountID != nil },
                set: { if !$0 { model.cancelPendingDelete() } }
            ),
            titleVisibility: .visible
        ) {
            if let account = model.pendingDeleteAccount {
                Button(L10n.tr("仅删除本地管理记录"), role: .destructive) {
                    Task { await model.deleteAccount(account.id, clearCurrentAuth: false) }
                }
                if account.platform == .codex {
                    Button(L10n.tr("删除并同时清空当前 ~/.codex/auth.json"), role: .destructive) {
                        Task { await model.deleteAccount(account.id, clearCurrentAuth: true) }
                    }
                }
            }
            Button(L10n.tr("取消"), role: .cancel) {
                model.cancelPendingDelete()
            }
        } message: {
            if let account = model.pendingDeleteAccount {
                if account.platform == .codex {
                    Text(L10n.tr("将删除账号“%@”。如果这是当前激活账号，第二个选项会让本机当前 Codex 处于登出状态。", account.displayName))
                } else {
                    Text(L10n.tr("将删除账号“%@”的本地管理记录。", account.displayName))
                }
            } else {
                Text(L10n.tr("如果这是当前激活账号，第二个选项会让本机当前 Codex 处于登出状态。"))
            }
        }
        .confirmationDialog(
            L10n.tr("安装 GitHub Copilot CLI"),
            isPresented: Binding(
                get: { model.copilotCLIInstallPrompt != nil },
                set: { if !$0, model.copilotCLIInstallPrompt != nil { model.cancelCopilotCLIInstall() } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.tr("安装")) {
                Task { await model.confirmCopilotCLIInstall() }
            }
            Button(L10n.tr("取消"), role: .cancel) {
                model.cancelCopilotCLIInstall()
            }
        } message: {
            Text(L10n.tr("当前机器未安装可用的 `copilot` CLI。是否需要 Orbit 帮你通过 npm 安装？"))
        }
    }

    private var accountSidebar: some View {
        VStack(spacing: 0) {
            sidebarHeader
            Divider()
            sidebarBody
            Divider()
            sidebarFooter
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(OrbitPalette.sidebar)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(OrbitPalette.divider)
                .frame(width: 1)
        }
    }

    private var sidebarHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(nsImage: AppIconArtwork.appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.tr("Orbit"))
                    .font(.system(size: 30, weight: .bold, design: .rounded))

                Text(L10n.tr("本地 LLM 账号工作台"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, SidebarLayoutMetrics.horizontalPadding)
        .padding(.vertical, SidebarLayoutMetrics.sectionVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var sidebarBody: some View {
        Group {
            if model.accounts.isEmpty {
                sidebarEmptyState
            } else {
                sidebarAccountList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var sidebarAccountList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(model.accounts) { account in
                    AccountListRow(
                        account: account,
                        snapshot: model.snapshot(for: account.id),
                        claudeSnapshot: model.claudeRateLimitSnapshot(for: account.id),
                        copilotSnapshot: model.copilotQuotaSnapshot(for: account.id),
                        isSelected: resolvedSelectedAccountID == account.id,
                        isDropTarget: dropTargetAccountID == account.id,
                        isHovering: hoveredAccountID == account.id,
                        isDragging: draggedAccountID == account.id,
                        isRefreshingStatus: model.isRefreshingStatus(for: account.id)
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(accountRowFrameReader(for: account.id))
                    .offset(y: accountDragVisualOffsetY(for: account.id))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard draggedAccountID == nil else { return }
                        model.selectedAccountID = account.id
                    }
                    .simultaneousGesture(accountReorderGesture(for: account))
                    .onHover { hovering in
                        if hovering {
                            hoveredAccountID = account.id
                        } else if hoveredAccountID == account.id {
                            hoveredAccountID = nil
                        }
                    }
                    .zIndex(draggedAccountID == account.id ? 1 : 0)
                    .contextMenu {
                        Button(account.isActive ? L10n.tr("当前正在使用") : L10n.tr("切换到此账号")) {
                            Task { @MainActor in await model.switchToAccount(account) }
                        }
                        .disabled(account.isActive || model.isRefreshingStatus(for: account.id) || model.isSwitchInProgress)

                        Button(model.isRefreshingStatus(for: account.id) ? L10n.tr("正在更新状态...") : L10n.tr("手动更新状态")) {
                            Task { await model.refreshAccountStatus(account) }
                        }
                        .disabled(model.isRefreshingStatus(for: account.id) || model.isRefreshingAllStatuses || model.isSwitchInProgress)

                        if model.canEditProviderAccount(account) {
                            Button(L10n.tr("编辑供应商")) {
                                presentEditProviderWindow(for: account.id)
                            }
                            .disabled(model.isRefreshingStatus(for: account.id) || model.isSwitchInProgress)
                        }

                    }
                }
            }
            .animation(.interactiveSpring(response: 0.24, dampingFraction: 0.88), value: model.accounts.map(\.id))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .coordinateSpace(name: accountListCoordinateSpaceName)
        .onPreferenceChange(AccountRowFramePreferenceKey.self) { frames in
            Task { @MainActor in
                accountRowFrames = frames
            }
        }
        .background(OrbitPalette.sidebar)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var sidebarEmptyState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.tr("还没有账号"))
                    .font(.headline)

                Text(L10n.tr("先新增一个账号，支持 ChatGPT、Provider API Key、Claude Profile，以及 GitHub Copilot。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(OrbitSpacing.section)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 16) {
            sidebarQuickActions

            Divider()

            sidebarPreferences

            if !model.focusedPlatformUnsupportedMessage.isEmpty {
                Text(model.focusedPlatformUnsupportedMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let homePath = model.focusedPlatformHomePath {
                Text(homePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(SidebarLayoutMetrics.footerPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var sidebarQuickActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("快捷操作"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Button {
                presentAddAccountWindow()
            } label: {
                Label(L10n.tr("新增账号"), systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canAddAccounts)

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.tr("工具"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)

                HStack(spacing: 8) {
                    Button {
                        presentProviderDesktopLaunchWindow()
                    } label: {
                        Label(L10n.tr("预设启动"), systemImage: "bolt.circle.fill")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)

                    Button {
                        presentWindow(id: "copilot-acp-debug")
                    } label: {
                        Label(L10n.tr("ACP 调试"), systemImage: "ladybug")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                }

                if let homeButtonTitle = model.focusedPlatformHomeButtonTitle {
                    Button {
                        model.openFocusedPlatformHomeInFinder()
                    } label: {
                        Label(homeButtonTitle, systemImage: "folder")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                }

                Button {
                    Task { await model.refreshAllAccountStatuses() }
                } label: {
                    Label(model.isRefreshingAllStatuses ? L10n.tr("正在刷新账号状态...") : L10n.tr("刷新全部状态"), systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .disabled(
                    model.isRefreshingAllStatuses
                        || model.accounts.isEmpty
                        || !model.focusedPlatformCapabilities.supportsStatusRefresh
                )
            }
        }
    }

    private var sidebarPreferences: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("偏好设置"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.tr("语言"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker(
                    L10n.tr("语言"),
                    selection: Binding(
                        get: { model.languagePreference },
                        set: { model.updateLanguagePreference($0) }
                    )
                ) {
                    ForEach(AppLanguagePreference.allCases) { preference in
                        Text(preference.title).tag(preference)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.tr("外观"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker(
                    L10n.tr("外观"),
                    selection: Binding(
                        get: { resolvedAppearancePreference },
                        set: { appearancePreference = $0.rawValue }
                    )
                ) {
                    ForEach(AppAppearancePreference.allCases) { preference in
                        Text(preference.title).tag(preference)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        }
    }

    private var resolvedSelectedAccountID: UUID? {
        model.selectedAccountID ?? model.activeAccount?.id
    }

    private var resolvedAppearancePreference: AppAppearancePreference {
        AppAppearancePreference.resolved(from: appearancePreference)
    }

    private func presentWindow(id: String) {
        model.noteProgrammaticActivation()
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            openWindow(id: id)
            (NSApp.delegate as? AppDelegate)?.refreshLocalization()
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async {
                (NSApp.delegate as? AppDelegate)?.refreshLocalization()
            }
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        if let banner = model.banner {
            VStack(spacing: 0) {
                BannerView(
                    state: banner,
                    isActionInProgress: model.isRestartingCodex,
                    onAction: { action in
                        Task { @MainActor in await model.performBannerAction(action) }
                    }
                )
                detailPane
            }
        } else {
            detailPane
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let account = model.selectedAccount {
            let authFilePath = configurationPathText(for: account)
            AccountDetailView(
                model: model,
                account: account,
                snapshot: model.snapshot(for: account.id),
                claudeSnapshot: model.claudeRateLimitSnapshot(for: account.id),
                copilotSnapshot: model.copilotQuotaSnapshot(for: account.id),
                authFilePath: authFilePath,
                onRename: { model.renameAccount(account.id, to: $0) },
                onEditProvider: { presentEditProviderWindow(for: account.id) },
                onReauthorize: { presentReauthorizeWindow(for: account.id) },
                onRefreshStatus: { Task { await model.refreshAccountStatus(account) } },
                onSwitch: { Task { @MainActor in await model.switchToAccount(account) } },
                onDelete: { model.requestDeleteAccount(account.id) }
            )
            .id(account.id)
        } else {
            ContentUnavailableView(
                L10n.tr("还没有账号"),
                systemImage: "person.2.slash",
                description: Text(
                    L10n.tr("先新增一个账号，支持 ChatGPT、Provider API Key、Claude Profile，以及 GitHub Copilot。")
                )
            )
        }
    }

    private func configurationPathText(for account: ManagedAccount) -> String {
        if account.providerRule == .githubCopilot {
            return model.copilotManagedConfigPath(for: account.id) ?? model.paths.copilotDirectoryURL.path
        }
        let platformPaths = model.paths.paths(for: account.platform)
        switch account.platform {
        case .codex:
            return platformPaths.authFileURL?.path ?? platformPaths.homeURL.path
        case .claude:
            var values = [platformPaths.homeURL.path]
            if let userSettingsPath = platformPaths.userSettingsFileURL?.path {
                values.append(userSettingsPath)
            }
            return values.joined(separator: "\n")
        }
    }

    private func presentAddAccountWindow() {
        model.prepareAddAccountSheet()
        presentWindow(id: "add-account")
    }

    private func presentProviderDesktopLaunchWindow() {
        model.prepareProviderDesktopLaunch()
        presentWindow(id: "launch-provider-desktop")
    }

    private func presentEditProviderWindow(for accountID: UUID) {
        model.openEditProvider(for: accountID)
        presentWindow(id: "add-account")
    }

    private func presentReauthorizeWindow(for accountID: UUID) {
        model.openReauthorize(for: accountID)
        presentWindow(id: "add-account")
    }

    private func accountRowFrameReader(for accountID: UUID) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: AccountRowFramePreferenceKey.self,
                value: [accountID: proxy.frame(in: .named(accountListCoordinateSpaceName))]
            )
        }
    }

    // 核心拖拽方法：整卡接收 DragGesture，用卡片中点跨过相邻卡片中线作为重排阈值。
    private func accountReorderGesture(for account: ManagedAccount) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(accountListCoordinateSpaceName))
            .onChanged { value in
                guard model.accounts.count > 1 else { return }
                beginAccountDragIfNeeded(account.id)
                guard draggedAccountID == account.id else { return }

                accountDragTranslation = value.translation
                if accountDragStartFrame == nil {
                    accountDragStartFrame = accountRowFrames[account.id]
                }
                guard let startFrame = accountDragStartFrame else { return }
                updateAccountOrderDuringDrag(
                    draggedAccountID: account.id,
                    draggedMidY: startFrame.midY + value.translation.height
                )
            }
            .onEnded { _ in
                finishAccountDrag()
            }
    }

    private func beginAccountDragIfNeeded(_ accountID: UUID) {
        guard draggedAccountID == nil else { return }
        draggedAccountID = accountID
        accountDragStartFrame = accountRowFrames[accountID]
        accountDragTranslation = .zero
        dropTargetAccountID = nil
        hasAccountOrderChangesDuringDrag = false
    }

    private func updateAccountOrderDuringDrag(draggedAccountID: UUID, draggedMidY: CGFloat) {
        let currentOrder = model.accounts.map(\.id)
        let previewOrder = AccountListReorderLogic.previewOrder(
            currentOrder: currentOrder,
            draggedAccountID: draggedAccountID,
            draggedMidY: draggedMidY,
            rowFrames: accountRowFrames
        )
        guard previewOrder != currentOrder else {
            dropTargetAccountID = nil
            return
        }
        guard let destinationAccountID = AccountListReorderLogic.destinationAccountID(
            currentOrder: currentOrder,
            previewOrder: previewOrder,
            draggedAccountID: draggedAccountID
        ) else {
            return
        }

        dropTargetAccountID = destinationAccountID
        hasAccountOrderChangesDuringDrag = true
        withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.88)) {
            model.moveAccount(draggedAccountID, to: destinationAccountID, persist: false)
        }
    }

    private func accountDragVisualOffsetY(for accountID: UUID) -> CGFloat {
        guard draggedAccountID == accountID else { return 0 }
        guard
            let startFrame = accountDragStartFrame,
            let currentFrame = accountRowFrames[accountID]
        else {
            return accountDragTranslation.height
        }

        return accountDragTranslation.height - (currentFrame.minY - startFrame.minY)
    }

    private func finishAccountDrag() {
        let shouldPersistOrder = hasAccountOrderChangesDuringDrag
        withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.9)) {
            draggedAccountID = nil
            dropTargetAccountID = nil
            accountDragStartFrame = nil
            accountDragTranslation = .zero
            hasAccountOrderChangesDuringDrag = false
        }
        if shouldPersistOrder {
            model.persistAccountOrder()
        }
    }
}

private struct AccountRowFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newValue in newValue })
    }
}

private struct AccountPlatformBadge: View {
    let title: String

    init(title: String) {
        self.title = title
    }

    init(platform: PlatformKind) {
        self.title = platform.displayName
    }

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(OrbitPalette.chromeFill, in: Capsule())
    }
}

private struct AccountListRow: View {
    let account: ManagedAccount
    let snapshot: QuotaSnapshot?
    let claudeSnapshot: ClaudeRateLimitSnapshot?
    let copilotSnapshot: CopilotQuotaSnapshot?
    let isSelected: Bool
    let isDropTarget: Bool
    let isHovering: Bool
    let isDragging: Bool
    // 输入：刷新任务命中当前账号时，列表行改为即时 loading 状态。
    let isRefreshingStatus: Bool

    @State private var isHoveringFailureIcon = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Text(account.displayName)
                    .font(.headline.weight(isSelected ? .semibold : .medium))
                    .lineLimit(1)

                Spacer(minLength: 6)

                if account.isActive {
                    Text(L10n.tr("当前"))
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(OrbitPalette.successSoft, in: Capsule())
                }
                AccountPlatformBadge(title: account.accountListBadgeTitle)
            }

            Text(accountSubtitle)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            statusContent
        }
        .padding(.leading, 12)
        .padding(.trailing, 12)
        .padding(.vertical, 11)
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: OrbitRadius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: OrbitRadius.panel, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            if isSelected {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(OrbitPalette.accent)
                    .frame(width: 3, height: 34)
                    .padding(.leading, 1)
                    .transition(.opacity)
            }
        }
        .scaleEffect(isDragging ? 0.985 : 1)
        .opacity(isDragging ? 0.82 : 1)
        .shadow(
            color: isDragging ? OrbitPalette.accent.opacity(0.12) : Color.clear,
            radius: isDragging ? 8 : 0,
            x: 0,
            y: isDragging ? 3 : 0
        )
        .animation(.easeOut(duration: 0.14), value: isSelected)
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(.easeOut(duration: 0.12), value: isRefreshingStatus)
        .animation(.interactiveSpring(response: 0.2, dampingFraction: 0.86), value: isDragging)
    }

    private var accountSubtitle: String {
        switch account.providerRule {
        case .chatgptOAuth:
            return account.email ?? account.accountIdentifier
        case .openAICompatible, .claudeCompatible:
            return account.email ?? account.resolvedProviderDisplayName
        case .claudeProfile:
            return L10n.tr("Claude Profile")
        case .githubCopilot:
            return account.email ?? L10n.tr("GitHub Copilot")
        }
    }

    private var statusSummary: String? {
        if let snapshot {
            return statusSummaryWithSubscriptionRenewal(L10n.tr("剩余 %@", snapshot.remainingSummary))
        }
        if let claudeSnapshot {
            return L10n.tr("请求剩余 %@", claudeRemainingText(claudeSnapshot.requests.remaining))
        }
        if let chat = copilotSnapshot?.chat {
            return L10n.tr("Chat 剩余 %@", chat.remainingPercentageText)
        }
        if let subscriptionRenewalText {
            return subscriptionRenewalText
        }
        if account.providerRule == .githubCopilot {
            return L10n.tr("本地 Copilot")
        }
        if account.providerRule == .claudeProfile {
            return L10n.tr("本地 Profile")
        }
        return nil
    }

    private var shouldShowCodexResetCountdowns: Bool {
        account.providerRule == .chatgptOAuth && snapshot != nil && !isRefreshingStatus
    }

    @ViewBuilder
    private var statusContent: some View {
        if isRefreshingStatus {
            HStack(alignment: .center, spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.64)
                    .frame(width: 14, height: 14)

                Text(L10n.tr("正在刷新账号状态..."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else if shouldShowCodexResetCountdowns, let snapshot {
            ZStack(alignment: .topTrailing) {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    CodexQuotaInfoPanel(
                        snapshot: snapshot,
                        countdowns: snapshot.resetCountdowns(now: context.date),
                        renewalText: subscriptionRenewalText
                    )
                }

                failureStatusIndicator
                    .padding(.top, 6)
                    .padding(.trailing, 6)
            }
        } else {
            HStack(alignment: .center, spacing: 6) {
                Label(statusSummary ?? fallbackStatusSummary, systemImage: "gauge.with.dots.needle.67percent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                failureStatusIndicator
            }
        }
    }

    @ViewBuilder
    private var failureStatusIndicator: some View {
        if let failureStatusMessage {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.red)
                .onHover { hovering in
                    isHoveringFailureIcon = hovering
                }
                .popover(isPresented: failurePopoverBinding, arrowEdge: .leading) {
                    AccountFailurePopoverContent(message: failureStatusMessage)
                }
        }
    }

    private var subscriptionRenewalText: String? {
        guard
            account.providerRule == .chatgptOAuth,
            let currentPeriodEndsAt = account.subscriptionDetails?.currentPeriodEndsAt
        else {
            return nil
        }
        return L10n.tr("续期 %@", currentPeriodEndsAt.formatted(date: .abbreviated, time: .omitted))
    }

    private func statusSummaryWithSubscriptionRenewal(_ summary: String) -> String {
        guard let subscriptionRenewalText else {
            return summary
        }
        return L10n.tr("%@ · %@", summary, subscriptionRenewalText)
    }

    private var fallbackStatusSummary: String {
        account.platform == .claude ? L10n.tr("状态未同步") : L10n.tr("额度未同步")
    }

    private var failureStatusMessage: String? {
        guard
            let level = account.lastStatusLevel,
            level != .info,
            let message = account.lastStatusMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
            !message.isEmpty
        else {
            return nil
        }
        return message
    }

    private var failurePopoverBinding: Binding<Bool> {
        Binding(
            get: { failureStatusMessage != nil && isHoveringFailureIcon },
            set: { isHoveringFailureIcon = $0 }
        )
    }

    private var backgroundColor: Color {
        if isDragging {
            return OrbitPalette.floatingPanelHover
        }
        if isDropTarget {
            return OrbitPalette.accentStrong
        }
        if isSelected {
            return OrbitPalette.selectionFill
        }
        if isRefreshingStatus {
            return OrbitPalette.floatingPanel
        }
        if account.isActive {
            return OrbitPalette.panelMuted
        }
        if isHovering {
            return OrbitPalette.floatingPanel
        }
        return Color.clear
    }

    private var borderColor: Color {
        if isDragging {
            return OrbitPalette.accent.opacity(0.22)
        }
        if isDropTarget {
            return OrbitPalette.accent.opacity(0.4)
        }
        if isSelected {
            return OrbitPalette.accent.opacity(0.3)
        }
        if isRefreshingStatus {
            return OrbitPalette.accent.opacity(0.18)
        }
        if isHovering {
            return OrbitPalette.hoverBorder
        }
        return Color.clear
    }

    private func claudeRemainingText(_ value: Int?) -> String {
        guard let value else { return L10n.tr("未知") }
        return "\(value)"
    }
}

private struct CodexQuotaInfoPanel: View {
    let snapshot: QuotaSnapshot
    let countdowns: CodexQuotaResetCountdowns
    let renewalText: String?
    private let labelColumnWidth: CGFloat = 66
    private let valueColumnWidth: CGFloat = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            quotaValueRow
            if !countdowns.isEmpty {
                countdownValueRow
            }
            if let renewalText {
                renewalRow(renewalText)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OrbitPalette.chromeSubtle, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(OrbitPalette.divider.opacity(0.55), lineWidth: 1)
        )
    }

    private var quotaValueRow: some View {
        alignedMetricRow(
            systemImage: "gauge.with.dots.needle.67percent",
            title: L10n.tr("剩余"),
            fiveHourText: snapshot.fiveHourWindow.map { "5h \($0.remainingPercentText)" },
            weeklyText: snapshot.weeklyWindow.map { "7d \($0.remainingPercentText)" },
            fiveHourColor: .secondary,
            weeklyColor: .secondary
        )
    }

    private var countdownValueRow: some View {
        alignedMetricRow(
            systemImage: "clock",
            title: L10n.tr("重置时间"),
            fiveHourText: countdowns.fiveHour.map { L10n.tr("%@ 后", $0.text) },
            weeklyText: countdowns.weekly.map { L10n.tr("%@ 后", $0.text) },
            fiveHourColor: countdowns.fiveHour.map { foregroundColor(for: $0.tone) } ?? .secondary,
            weeklyColor: countdowns.weekly.map { foregroundColor(for: $0.tone) } ?? .secondary
        )
    }

    private func alignedMetricRow(
        systemImage: String,
        title: String,
        fiveHourText: String?,
        weeklyText: String?,
        fiveHourColor: Color,
        weeklyColor: Color
    ) -> some View {
        HStack(alignment: .center, spacing: 7) {
            metricLabel(systemImage: systemImage, title: title)

            metricValue(fiveHourText, color: fiveHourColor)
                .frame(width: valueColumnWidth, alignment: .leading)

            metricValue(weeklyText, color: weeklyColor)
                .frame(width: valueColumnWidth, alignment: .leading)

            Spacer(minLength: 0)
        }
    }

    private func metricLabel(systemImage: String, title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 14)

            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .frame(width: labelColumnWidth, alignment: .leading)
    }

    private func metricValue(_ text: String?, color: Color) -> some View {
        Group {
            if let text {
                Text(text)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            } else {
                Text("")
                    .font(.caption.weight(.bold))
            }
        }
    }

    private func renewalRow(_ renewalText: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 14)

            Text(renewalText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.86)
        }
        .padding(.top, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func foregroundColor(for tone: QuotaResetCountdownTone) -> Color {
        switch tone {
        case .normal:
            return .secondary
        case .warning:
            return .yellow
        case .danger:
            return .red
        }
    }
}

private struct AccountFailurePopoverContent: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 260, alignment: .leading)
            .padding(12)
    }
}

private struct AccountDetailView: View {
    @ObservedObject var model: AppViewModel
    @Environment(\.colorScheme) private var colorScheme
    let account: ManagedAccount
    let snapshot: QuotaSnapshot?
    let claudeSnapshot: ClaudeRateLimitSnapshot?
    let copilotSnapshot: CopilotQuotaSnapshot?
    let authFilePath: String
    let onRename: (String) -> Void
    let onEditProvider: () -> Void
    let onReauthorize: () -> Void
    let onRefreshStatus: () -> Void
    let onSwitch: () -> Void
    let onDelete: () -> Void

    @State private var draftName = ""
    @State private var isShowingCopilotSessionQueueSheet = false
    @State private var isShowingCopilotSessionImportSheet = false

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                HStack(alignment: .top, spacing: OrbitSpacing.section) {
                    VStack(alignment: .leading, spacing: OrbitSpacing.regular) {
                        workspaceHeader
                        quickActionSection
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                    VStack(alignment: .leading, spacing: OrbitSpacing.regular) {
                        inspectorPanel
                        deleteSection
                    }
                    .frame(width: inspectorWidth(for: proxy.size.width), alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(OrbitSpacing.section)
            }
            .background(OrbitPalette.workspace)
        }
        .onAppear {
            draftName = account.displayName
        }
        .onChange(of: account.id) { _, _ in
            draftName = account.displayName
        }
        .sheet(isPresented: $isShowingCopilotSessionImportSheet) {
            CopilotSessionImportSheet(
                candidates: model.copilotSessionImportCandidates,
                errorMessage: model.copilotSessionImportError,
                isImporting: model.isImportingCopilotSession,
                onImport: { candidate in
                    Task {
                        await model.importCopilotSession(candidate)
                        isShowingCopilotSessionImportSheet = false
                    }
                },
                onCancel: {
                    isShowingCopilotSessionImportSheet = false
                }
            )
        }
        .sheet(isPresented: $isShowingCopilotSessionQueueSheet) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(L10n.tr("同步 copilot 任务"))
                        .font(.title3.bold())

                    Spacer()

                    Button(L10n.tr("关闭")) {
                        isShowingCopilotSessionQueueSheet = false
                    }
                    .keyboardShortcut(.cancelAction)
                }

                ScrollView {
                    copilotSessionQueueSection
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
            .frame(width: 680, height: 520, alignment: .topLeading)
        }
    }

    private func inspectorWidth(for totalWidth: CGFloat) -> CGFloat {
        min(336, max(280, totalWidth * 0.34))
    }

    private var workspaceHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.tr("当前账号"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(account.displayName)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .lineLimit(2)

            Text(workspaceDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                AccountPlatformBadge(platform: account.platform)

                if account.isActive {
                    Text(L10n.tr("当前"))
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(OrbitPalette.successSoft, in: Capsule())
                }

                Text(account.planType ?? account.authKind.displayName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(OrbitPalette.chromeFill, in: Capsule())
            }

            if let workspaceStatusText {
                Text(workspaceStatusText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var credentialSummaryLabel: String {
        switch account.providerRule {
        case .chatgptOAuth:
            return L10n.tr("邮箱")
        case .openAICompatible, .claudeCompatible:
            return L10n.tr("Key 摘要")
        case .claudeProfile:
            return L10n.tr("Profile")
        case .githubCopilot:
            return L10n.tr("Host/Login")
        }
    }

    private var credentialSummaryValue: String {
        switch account.providerRule {
        case .claudeProfile:
            return L10n.tr("本地快照")
        case .chatgptOAuth, .openAICompatible, .claudeCompatible, .githubCopilot:
            return account.email ?? L10n.tr("未解析")
        }
    }

    private var headerSummary: String {
        switch account.providerRule {
        case .chatgptOAuth:
            return account.email ?? account.accountIdentifier
        case .openAICompatible, .claudeCompatible:
            return account.resolvedProviderDisplayName
        case .claudeProfile:
            return L10n.tr("本地 Profile")
        case .githubCopilot:
            return account.email ?? L10n.tr("GitHub Provider")
        }
    }

    private var workspaceDescription: String {
        if account.displayName != headerSummary {
            return headerSummary
        }
        switch account.providerRule {
        case .chatgptOAuth:
            return L10n.tr("已接入 ChatGPT 凭据，可直接从当前账号启动本地 CLI。")
        case .openAICompatible:
            return L10n.tr("当前账号会按保存的 OpenAI 兼容 provider、模型和桥接方式启动。")
        case .claudeCompatible:
            return L10n.tr("当前账号会按保存的 Claude 兼容 provider、模型和 API Key 启动。")
        case .claudeProfile:
            return L10n.tr("当前账号会直接复用已保存的本地 Claude Profile。")
        case .githubCopilot:
            return L10n.tr("当前账号会通过 Orbit 的本地 GitHub provider bridge 启动 Codex CLI、Codex.app 或 Claude Code。")
        }
    }

    private var workspaceStatusText: String? {
        if let chat = copilotSnapshot?.chat {
            return L10n.tr("Chat 剩余 %@", chat.remainingPercentageText)
        }
        if let snapshot {
            return L10n.tr("剩余 %@", snapshot.remainingSummary)
        }
        if let claudeSnapshot {
            return L10n.tr("请求剩余 %@", claudeValueSummary(claudeSnapshot.requests))
        }
        return nil
    }

    private var codexUsageStatusText: String? {
        if account.providerRule != .chatgptOAuth {
            return nil
        }
        return account.subscriptionDetails?.usageStatusText
    }

    private var codexAvailabilityText: String? {
        if account.providerRule != .chatgptOAuth {
            return nil
        }
        guard let details = account.subscriptionDetails, details.allowed != nil else {
            return nil
        }
        return details.availabilityText
    }

    private var codexLimitStatusText: String? {
        if account.providerRule != .chatgptOAuth {
            return nil
        }
        guard let details = account.subscriptionDetails, details.limitReached != nil else {
            return nil
        }
        return details.limitStatusText
    }

    private var codexCurrentPeriodEndsAtText: String? {
        guard
            account.providerRule == .chatgptOAuth,
            let currentPeriodEndsAt = account.subscriptionDetails?.currentPeriodEndsAt
        else {
            return nil
        }
        return currentPeriodEndsAt.formatted(date: .abbreviated, time: .omitted)
    }

    private func inspectorRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)

            Text(value)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var quickActionSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 16) {
                    Text(L10n.tr("打开 CLI"))
                        .font(.title2.bold())

                    Spacer(minLength: 12)

                    Picker(
                        L10n.tr("默认启动目标"),
                        selection: Binding(
                            get: { model.defaultCLITarget(for: account) },
                            set: { model.setDefaultCLITarget($0, for: account.id) }
                        )
                    ) {
                        ForEach(account.allowedCLITargets) { target in
                            Text(target.displayName)
                                .tag(target)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }

                Text(cliLaunchHelpText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Rectangle()
                .fill(OrbitPalette.divider)
                .frame(height: 1)

            Button {
                chooseDirectoryAndOpenCLI()
            } label: {
                HStack(spacing: 10) {
                    Text(primaryCLILaunchButtonTitle)
                        .font(.headline)

                    Spacer(minLength: 0)

                    Image(systemName: "folder.badge.plus")
                        .font(.callout.weight(.semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isCLIActionDisabled)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.tr("最近目录"))
                    .font(.headline)

                if recentCLILaunches.isEmpty {
                    Text(L10n.tr("先选择一个目录打开 %@，后续会在这里快速重开。", selectedCLITarget.displayName))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(recentCLILaunches) { record in
                            CLIDirectoryHistoryCard(
                                record: record,
                                isDisabled: isCLIActionDisabled,
                                onOpen: {
                                    launchCLI(record: record)
                                },
                                onDelete: {
                                    model.deleteCLILaunchRecord(record.id, for: account.id)
                                }
                            )
                        }
                    }
                }

                HStack(spacing: 12) {
                    Button(L10n.tr("浏览其他目录...")) {
                        chooseDirectoryAndOpenCLI()
                    }
                    .buttonStyle(.plain)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .disabled(isCLIActionDisabled)
                }
            }

            Divider()

            secondaryLaunchActionsSection

            Divider()

            accountMaintenanceActionsSection
        }
        .padding(24)
        .orbitSurface(.accent, radius: OrbitRadius.hero)
    }

    private var copilotSessionQueueSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("同步 copilot 任务"))
                        .font(.headline)
                    Text(L10n.tr("从 VSCode 同目录 Copilot Chat session 生成本地 handoff，再同步给当前选中账号继续。"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Toggle(
                    L10n.tr("自动监听"),
                    isOn: Binding(
                        get: { model.isCopilotSessionAutoMonitorEnabled },
                        set: { model.setCopilotSessionAutoMonitorEnabled($0) }
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            Button {
                chooseCopilotSessionWorkspace()
            } label: {
                Label(L10n.tr("导入 VSCode Copilot 任务..."), systemImage: "tray.and.arrow.down")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if model.copilotSessionQueueItems.isEmpty {
                Text(L10n.tr("还没有同步的 copilot 任务。"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(model.copilotSessionQueueItems.prefix(6))) { item in
                        CopilotSessionQueueCard(
                            item: item,
                            isExecuting: model.executingCopilotSessionQueueItemID == item.id,
                            isDesktopDisabled: item.codexThreadID == nil && !model.canSendCopilotSessionQueueItemToDesktop(for: account),
                            isCLIDisabled: !account.supportsCodexCLI,
                            onRunCLI: {
                                Task { await model.executeCopilotSessionQueueItemInCLI(item) }
                            },
                            onRunDesktop: {
                                Task { await model.executeCopilotSessionQueueItemInDesktop(item) }
                            },
                            onArchive: {
                                model.archiveCopilotSessionQueueItem(item.id)
                            },
                            onDelete: {
                                model.deleteCopilotSessionQueueItem(item.id)
                            }
                        )
                    }
                }
            }
        }
    }

    private var secondaryLaunchActionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("启动与同步"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(L10n.tr("切换账号、启动独立实例，或同步 VSCode Copilot 任务。"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button(switchButtonTitle) {
                    onSwitch()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(account.isActive || model.isRefreshingStatus(for: account.id) || model.isSwitchInProgress)

                if shouldShowIsolatedInstanceAction {
                    Button(isolatedInstanceButtonTitle) {
                        Task { await model.launchIsolatedCodex(for: account) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isIsolatedInstanceActionDisabled)
                }

                Button {
                    isShowingCopilotSessionQueueSheet = true
                } label: {
                    Label(L10n.tr("同步 copilot 任务"), systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var accountMaintenanceActionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("账号维护"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(L10n.tr("刷新状态、编辑配置或重新授权。"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Button(model.isRefreshingStatus(for: account.id) ? L10n.tr("正在更新状态...") : L10n.tr("手动更新状态")) {
                        onRefreshStatus()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.isRefreshingStatus(for: account.id) || model.isRefreshingAllStatuses || model.isSwitchInProgress)

                    if model.canOperateMainCodexInstance(for: account) {
                        Button(model.isRestartingCodex ? model.mainCodexInstanceActionInProgressTitle : model.mainCodexInstanceActionTitle) {
                            Task { @MainActor in await model.performBannerAction(.restartCodex) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(model.isRestartingCodex)
                    }
                }

                HStack(spacing: 10) {
                    if model.canEditProviderAccount(account) {
                        Button(L10n.tr("编辑供应商")) {
                            onEditProvider()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(model.isRefreshingStatus(for: account.id) || model.isSwitchInProgress)
                    }

                    if model.canReauthorizeAccount(account) {
                        Button(L10n.tr("重新登录授权")) {
                            onReauthorize()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(model.isRefreshingStatus(for: account.id) || model.isSwitchInProgress)
                    }
                }
            }
        }
    }

    private var inspectorPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.tr("账号详情"))
                .font(.title3.bold())

            HStack(alignment: .center, spacing: 10) {
                TextField(L10n.tr("显示名"), text: $draftName)
                    .textFieldStyle(.roundedBorder)
                Button(L10n.tr("保存名称")) {
                    onRename(draftName)
                }
                .buttonStyle(.bordered)
            }

            VStack(alignment: .leading, spacing: 12) {
                inspectorRow(L10n.tr("账号类型"), account.authKind.displayName)
                inspectorRow(L10n.tr("账号 ID"), account.accountIdentifier)
                inspectorRow(credentialSummaryLabel, credentialSummaryValue)
                inspectorRow(L10n.tr("套餐类型"), account.planType ?? L10n.tr("未知"))
                if let codexCurrentPeriodEndsAtText {
                    inspectorRow(L10n.tr("到期/续期时间"), codexCurrentPeriodEndsAtText)
                }

                if let codexUsageStatusText {
                    inspectorRow(L10n.tr("Codex 使用状态"), codexUsageStatusText)
                }
                if let codexAvailabilityText {
                    inspectorRow(L10n.tr("可用性"), codexAvailabilityText)
                }
                if let codexLimitStatusText {
                    inspectorRow(L10n.tr("额度限制"), codexLimitStatusText)
                }

                inspectorRow(L10n.tr("最后刷新"), account.lastRefreshAt?.formatted(date: .abbreviated, time: .standard) ?? L10n.tr("未知"))
                inspectorRow(L10n.tr("最后使用"), account.lastUsedAt?.formatted(date: .abbreviated, time: .standard) ?? L10n.tr("从未"))
            }

            Divider()
            quotaSection
            Divider()
            statusSection
            Divider()
            pathSection
        }
        .padding(.top, 8)
    }

    private var deleteSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("删除账号"))
                .font(.headline.bold())

            Text(L10n.tr("此操作不可撤销。"))
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(role: .destructive) {
                onDelete()
            } label: {
                Text(L10n.tr("删除账号"))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(deleteButtonForegroundColor)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .overlay(
                        RoundedRectangle(cornerRadius: OrbitRadius.row, style: .continuous)
                            .strokeBorder(deleteButtonBorderColor, lineWidth: 1)
                            .allowsHitTesting(false)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: OrbitRadius.row, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isDeleteActionDisabled)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .orbitSurface(.danger)
    }

    private var isDeleteActionDisabled: Bool {
        model.isRefreshingStatus(for: account.id) || model.isSwitchInProgress
    }

    private var deleteButtonForegroundColor: Color {
        Color.red.opacity(isDeleteActionDisabled ? 0.42 : 0.9)
    }

    private var deleteButtonBorderColor: Color {
        Color.red.opacity(isDeleteActionDisabled ? 0.16 : 0.34)
    }

    private var switchButtonTitle: String {
        if model.isVerifyingSwitch(for: account.id) {
            return L10n.tr("正在验证热更...")
        }
        if model.isSwitchingAccount(account.id) {
            return L10n.tr("正在切换账号...")
        }
        if account.isActive {
            return L10n.tr("当前正在使用")
        }
        return L10n.tr("切换到此账号")
    }

    private var cliLaunchHelpText: String {
        if account.providerRule == .openAICompatible, !account.supportsResponsesAPI {
            return L10n.tr("打开 CLI 会先通过本地桥接把 OpenAI Responses API 转成 chat/completions，再按当前账号配置启动。")
        }
        switch selectedCLITarget {
        case .claude:
            switch account.providerRule {
            case .claudeProfile:
                return L10n.tr("打开 CLI 会直接复用当前账号保存的 Claude Profile。")
            case .claudeCompatible:
                return L10n.tr("打开 CLI 会按当前账号的 Claude 兼容 provider、模型和 API Key 启动 Claude Code。")
            case .githubCopilot:
                return L10n.tr("打开 CLI 会先连到 Orbit 的本地 GitHub provider bridge，再复用现有 Responses -> Claude 的桥接链路。")
            case .chatgptOAuth, .openAICompatible:
                return L10n.tr("打开 CLI 会优先使用系统 Claude Code 启动，并自动桥接当前账号的 OpenAI 兼容凭据；仅旧版 Claude Code 会回退到应用生成的 patched runtime。")
            }
        case .codex:
            if !account.supportsCodexCLI {
                return L10n.tr("当前账号不支持打开 Codex CLI。")
            }
            if model.hasLaunchedIsolatedInstance(for: account.id) {
                return L10n.tr("该账号的独立实例已在当前会话中启动，为避免重复拉起，当前已禁用再次启动。")
            }
            if account.isActive && account.providerRule == .chatgptOAuth {
                return L10n.tr("打开 CLI 会直接使用当前 ~/.codex；当前活跃的 ChatGPT 账号不能再起独立实例，避免触发 refresh_token_reused。")
            }
            if account.providerRule == .openAICompatible {
                return L10n.tr("打开 CLI 会为该账号生成独立 CODEX_HOME，并按账号里的 OpenAI 兼容 provider 配置启动。")
            }
            if account.providerRule == .claudeCompatible {
                return L10n.tr("打开 CLI 会先桥接当前 Claude 兼容 provider，再用独立 CODEX_HOME 启动 Codex CLI。")
            }
            if account.providerRule == .githubCopilot {
                return L10n.tr("打开 CLI 会先连到 Orbit 的本地 GitHub provider bridge，再把 GitHub Copilot 暴露成 OpenAI Responses provider。")
            }
            return L10n.tr("打开 CLI 时会为该账号使用独立 CODEX_HOME；独立实例也会使用独立 CODEX_HOME 和 user-data 目录启动，不会改写当前 ~/.codex。")
        }
    }

    private var isolatedInstanceButtonTitle: String {
        if model.isLaunchingIsolatedInstance(for: account.id) {
            return L10n.tr("正在启动独立实例...")
        }
        if model.hasLaunchedIsolatedInstance(for: account.id) {
            return L10n.tr("独立实例已启动")
        }
        return L10n.tr("启动独立实例")
    }

    private var selectedCLITarget: CLIEnvironmentTarget {
        model.defaultCLITarget(for: account)
    }

    private var recentCLILaunches: [CLILaunchRecord] {
        Array(
            model.cliLaunchHistory(for: account.id)
                .filter { $0.target == selectedCLITarget }
                .prefix(4)
        )
    }

    private var primaryCLILaunchButtonTitle: String {
        if model.isLaunchingCLI(for: account.id) {
            return L10n.tr("正在打开 %@...", selectedCLITarget.displayName)
        }
        return L10n.tr("选择目录并打开 %@", selectedCLITarget.displayName)
    }

    private var isCLIActionDisabled: Bool {
        model.isRefreshingStatus(for: account.id)
            || model.isRefreshingAllStatuses
            || model.isLaunchingCLI(for: account.id)
            || model.isLaunchingIsolatedInstance(for: account.id)
            || model.isSwitchInProgress
    }

    private var shouldShowIsolatedInstanceAction: Bool {
        account.providerRule == .chatgptOAuth
            || account.providerRule == .openAICompatible
            || account.providerRule == .githubCopilot
    }

    private var isIsolatedInstanceActionDisabled: Bool {
        !model.canLaunchIsolatedCodex(for: account)
            || model.isLaunchingIsolatedInstance(for: account.id)
            || model.isLaunchingCLI(for: account.id)
            || model.isSwitchInProgress
    }

    private func chooseDirectoryAndOpenCLI() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = L10n.tr("打开 %@", selectedCLITarget.displayName)
        panel.message = L10n.tr("选择一个目录作为 %@ 的启动目录。", selectedCLITarget.displayName)
        if let path = recentCLILaunches.first?.path {
            panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        }

        guard panel.runModal() == .OK, let directoryURL = panel.url else { return }
        launchCLI(in: directoryURL)
    }

    private func launchCLI(in directoryURL: URL) {
        Task {
            await model.openCLI(for: account, target: selectedCLITarget, workingDirectoryURL: directoryURL)
        }
    }

    private func launchCLI(record: CLILaunchRecord) {
        Task {
            await model.openCLI(
                for: account,
                target: selectedCLITarget,
                workingDirectoryURL: URL(fileURLWithPath: record.path, isDirectory: true)
            )
        }
    }

    private func chooseCopilotSessionWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = L10n.tr("读取 Session")
        panel.message = L10n.tr("选择 VSCode 中使用 Copilot Chat 的 workspace 目录。")
        if let path = recentCLILaunches.first?.path {
            panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        }

        guard panel.runModal() == .OK, let directoryURL = panel.url else { return }
        isShowingCopilotSessionQueueSheet = false
        Task {
            await model.loadCopilotSessionCandidates(for: directoryURL)
            isShowingCopilotSessionImportSheet = true
        }
    }

    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(account.platform == .codex ? L10n.tr("额度快照") : L10n.tr("限额快照"))
                .font(.headline)

            if account.providerRule == .githubCopilot {
                if let copilotSnapshot {
                    HStack(alignment: .top, spacing: 10) {
                        if let chat = copilotSnapshot.chat {
                            quotaStat(title: L10n.tr("Chat 剩余"), value: chat.remainingPercentageText)
                        }
                        if let completions = copilotSnapshot.completions {
                            quotaStat(title: L10n.tr("Completions 剩余"), value: completions.remainingPercentageText)
                        }
                        if let premiumInteractions = copilotSnapshot.premiumInteractions {
                            quotaStat(title: L10n.tr("Premium 剩余"), value: premiumInteractions.remainingPercentageText)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        if let chat = copilotSnapshot.chat {
                            inspectorRow(L10n.tr("Chat 已用"), chat.usageSummary)
                            inspectorRow(L10n.tr("Chat 重置"), formattedDate(chat.resetDate))
                        }
                        if let completions = copilotSnapshot.completions {
                            inspectorRow(L10n.tr("Completions 已用"), completions.usageSummary)
                            inspectorRow(L10n.tr("Completions 重置"), formattedDate(completions.resetDate))
                        }
                        if let premiumInteractions = copilotSnapshot.premiumInteractions {
                            inspectorRow(L10n.tr("Premium 已用"), premiumInteractions.usageSummary)
                            inspectorRow(L10n.tr("Premium 重置"), formattedDate(premiumInteractions.resetDate))
                        }
                        inspectorRow(L10n.tr("采集时间"), copilotSnapshot.capturedAt.formatted(date: .abbreviated, time: .standard))
                    }
                } else {
                    inspectorNotice(
                        L10n.tr("当前还没有可用的 Copilot quota 快照；手动更新状态至少会校验本地登录态和模型列表。"),
                        tone: .warning
                    )
                }
            } else if account.platform == .codex {
                if let snapshot {
                    if snapshot.fiveHourWindow != nil || snapshot.weeklyWindow != nil {
                        HStack(alignment: .top, spacing: 10) {
                            if let fiveHourWindow = snapshot.fiveHourWindow {
                                quotaStat(title: L10n.tr("5 小时剩余"), value: fiveHourWindow.remainingPercentText)
                            }
                            if let weeklyWindow = snapshot.weeklyWindow {
                                quotaStat(title: L10n.tr("7 天剩余"), value: weeklyWindow.remainingPercentText)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        inspectorRow(L10n.tr("口径"), L10n.tr("剩余百分比（与 Codex 状态面板一致）"))
                        inspectorRow(L10n.tr("计划类型"), snapshot.planType ?? L10n.tr("未知"))
                        inspectorRow(L10n.tr("来源"), snapshot.source.displayName)
                        inspectorRow(L10n.tr("采集时间"), snapshot.capturedAt.formatted(date: .abbreviated, time: .standard))
                        if let fiveHourWindow = snapshot.fiveHourWindow {
                            inspectorRow(
                                L10n.tr("5 小时重置"),
                                fiveHourWindow.resetsAt?.formatted(date: .abbreviated, time: .standard) ?? L10n.tr("未知")
                            )
                            if let countdown = fiveHourWindow.resetCountdown() {
                                inspectorRow(L10n.tr("5 小时重置倒计时"), countdown.text)
                            }
                        }
                        if let weeklyWindow = snapshot.weeklyWindow {
                            inspectorRow(
                                L10n.tr("7 天重置"),
                                weeklyWindow.resetsAt?.formatted(date: .abbreviated, time: .standard) ?? L10n.tr("未知")
                            )
                            if let countdown = weeklyWindow.resetCountdown() {
                                inspectorRow(L10n.tr("7 天重置倒计时"), countdown.text)
                            }
                        }

                        if let credits = snapshot.credits {
                            inspectorRow(L10n.tr("Credits"), credits.unlimited ? L10n.tr("unlimited") : (credits.balance.map { "\($0)" } ?? L10n.tr("无")))
                        }
                    }
                } else {
                    inspectorNotice(
                        L10n.tr("这个账号还没有被可靠归档的本地额度快照。切换到该账号并实际使用一段时间后，应用会从本地会话事件中抓取额度。"),
                        tone: .warning
                    )
                }
            } else if let claudeSnapshot {
                VStack(alignment: .leading, spacing: 10) {
                    inspectorRow(L10n.tr("Requests"), claudeValueSummary(claudeSnapshot.requests))
                    inspectorRow(L10n.tr("Requests 重置"), formattedDate(claudeSnapshot.requests.resetAt))
                    inspectorRow(L10n.tr("Input Tokens"), claudeValueSummary(claudeSnapshot.inputTokens))
                    inspectorRow(L10n.tr("Input Tokens 重置"), formattedDate(claudeSnapshot.inputTokens.resetAt))
                    inspectorRow(L10n.tr("Output Tokens"), claudeValueSummary(claudeSnapshot.outputTokens))
                    inspectorRow(L10n.tr("Output Tokens 重置"), formattedDate(claudeSnapshot.outputTokens.resetAt))
                    inspectorRow(L10n.tr("来源"), claudeSnapshot.source.displayName)
                    inspectorRow(L10n.tr("采集时间"), claudeSnapshot.capturedAt.formatted(date: .abbreviated, time: .standard))
                }
            } else if account.authKind == .claudeProfile {
                inspectorNotice(
                    L10n.tr("这是本地 Claude Profile；应用不会在线刷新 claude.ai 登录态，可直接从应用启动 Claude CLI 验证。"),
                    tone: .warning
                )
            } else {
                inspectorNotice(
                    L10n.tr("还没有刷新过 Anthropic 限额。手动更新状态后，应用会读取响应头中的 requests 和 token 限额信息。"),
                    tone: .warning
                )
            }
        }
    }

    private func quotaStat(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(quotaStatDisplayTitle(title))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Text(value)
                .font(.title3.weight(.bold))
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
        .padding(14)
        .background(OrbitPalette.panelMuted, in: RoundedRectangle(cornerRadius: OrbitRadius.row, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: OrbitRadius.row, style: .continuous)
                .strokeBorder(OrbitPalette.divider, lineWidth: 1)
        )
    }

    private func quotaStatDisplayTitle(_ title: String) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedTitle.hasSuffix("剩余") {
            let prefix = trimmedTitle.dropLast("剩余".count).trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty {
                return "\(prefix)\n剩余"
            }
        }

        if trimmedTitle.lowercased().hasSuffix("remaining") {
            let prefix = trimmedTitle.dropLast("remaining".count).trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty {
                return "\(prefix)\nremaining"
            }
        }

        return trimmedTitle
    }

    private var pathSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(account.platform == .codex ? L10n.tr("当前写入路径") : L10n.tr("配置路径"))
                .font(.headline)

            Text(authFilePath)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .orbitSurface()
        }
    }

    private var statusTone: OrbitSurfaceTone {
        switch account.lastStatusLevel ?? .info {
        case .info:
            return .success
        case .warning:
            return .warning
        case .error:
            return .danger
        }
    }

    private var localizedLastStatusMessage: String {
        guard let message = account.lastStatusMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty else {
            return L10n.tr("尚未手动更新")
        }

        if let quotaSummary = snapshot?.remainingSummary {
            if matchesLocalizedStatusTemplate(
                message,
                chineseTemplate: "状态与额度已更新：剩余 %@，当前已触达额度限制。",
                englishTemplate: "Status and quota updated: %@ remaining, and the current quota limit has been reached."
            ) {
                return L10n.tr("状态与额度已更新：剩余 %@，当前已触达额度限制。", quotaSummary)
            }

            if matchesLocalizedStatusTemplate(
                message,
                chineseTemplate: "状态与额度已更新：剩余 %@。",
                englishTemplate: "Status and quota updated: %@ remaining."
            ) {
                return L10n.tr("状态与额度已更新：剩余 %@。", quotaSummary)
            }
        }

        if let claudeSnapshot,
           matchesLocalizedStatusTemplate(
                message,
                chineseTemplate: "Anthropic API Key 已刷新：请求剩余 %@。",
                englishTemplate: "Anthropic API Key refreshed: %@ requests remaining."
           ) {
            return L10n.tr(
                "Anthropic API Key 已刷新：请求剩余 %@。",
                claudeRemainingStatusText(claudeSnapshot.requests.remaining)
            )
        }

        for (chinese, english, key) in [
            (
                "Provider API Key 本地凭据可用。",
                "Provider API Key local credential is available.",
                "Provider API Key 本地凭据可用。"
            ),
            (
                "API Key 模式不支持在线额度同步，已同步当前 ~/.codex/auth.json。",
                "API Key mode does not support online quota sync. The current ~/.codex/auth.json has been synced.",
                "API Key 模式不支持在线额度同步，已同步当前 ~/.codex/auth.json。"
            ),
            (
                "API Key 模式不支持在线额度同步，本地凭据可用。",
                "API Key mode does not support online quota sync, but the local credential is available.",
                "API Key 模式不支持在线额度同步，本地凭据可用。"
            ),
            (
                "状态已更新，并同步了当前 ~/.codex/auth.json。",
                "Status updated, and the current ~/.codex/auth.json has been synced.",
                "状态已更新，并同步了当前 ~/.codex/auth.json。"
            ),
            (
                "状态已更新，账号凭据可用。",
                "Status updated and the account credential is available.",
                "状态已更新，账号凭据可用。"
            ),
            (
                "这是本地 Claude Profile；应用不会在线刷新 claude.ai 登录态，可直接从应用启动 Claude CLI 验证。",
                "This is a local Claude Profile. The app does not refresh claude.ai sign-in state online; you can verify it by launching Claude CLI from the app.",
                "这是本地 Claude Profile；应用不会在线刷新 claude.ai 登录态，可直接从应用启动 Claude CLI 验证。"
            ),
        ] {
            if message == chinese || message == english {
                return L10n.tr(key)
            }
        }

        if let error = extractStatusTemplateArgument(
            from: message,
            chineseTemplate: "状态已更新，但额度同步失败：%@",
            englishTemplate: "Status updated, but quota sync failed: %@"
        ) {
            return L10n.tr("状态已更新，但额度同步失败：%@", error)
        }

        if let error = extractStatusTemplateArgument(
            from: message,
            chineseTemplate: "状态更新失败：%@",
            englishTemplate: "Status update failed: %@"
        ) {
            return L10n.tr("状态更新失败：%@", error)
        }

        return message
    }

    private func claudeRemainingStatusText(_ value: Int?) -> String {
        guard let value else { return L10n.tr("未知") }
        return "\(value)"
    }

    private func matchesLocalizedStatusTemplate(
        _ message: String,
        chineseTemplate: String,
        englishTemplate: String
    ) -> Bool {
        extractStatusTemplateArgument(
            from: message,
            chineseTemplate: chineseTemplate,
            englishTemplate: englishTemplate
        ) != nil
    }

    private func extractStatusTemplateArgument(
        from message: String,
        chineseTemplate: String,
        englishTemplate: String
    ) -> String? {
        for template in [chineseTemplate, englishTemplate] {
            guard let placeholderRange = template.range(of: "%@") else {
                if message == template {
                    return ""
                }
                continue
            }

            let prefix = String(template[..<placeholderRange.lowerBound])
            let suffix = String(template[placeholderRange.upperBound...])
            guard message.hasPrefix(prefix), message.hasSuffix(suffix) else {
                continue
            }

            let start = message.index(message.startIndex, offsetBy: prefix.count)
            let end = message.index(message.endIndex, offsetBy: -suffix.count)
            guard start <= end else {
                continue
            }

            return String(message[start..<end])
        }

        return nil
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if usesSubduedInspectorCards {
                HStack(alignment: .center, spacing: 10) {
                    Text(L10n.tr("账号状态"))
                        .font(.headline)

                    Spacer(minLength: 8)

                    semanticBadge(
                        title: statusBadgeTitle,
                        tone: statusTone
                    )
                }
            } else {
                Text(L10n.tr("账号状态"))
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 10) {
                inspectorRow(L10n.tr("上次检查"), account.lastStatusCheckAt?.formatted(date: .abbreviated, time: .standard) ?? L10n.tr("尚未手动更新"))
                inspectorRow(L10n.tr("最近结果"), localizedLastStatusMessage)
                inspectorRow(L10n.tr("说明"), statusDescriptionText)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .orbitSurface(statusTone)
        }
    }

    private var statusBadgeTitle: String {
        switch statusTone {
        case .success:
            return L10n.tr("可用")
        case .warning:
            return L10n.tr("注意")
        case .danger:
            return L10n.tr("异常")
        case .neutral, .accent:
            return ""
        }
    }

    @ViewBuilder
    private func inspectorNotice(_ message: String, tone: OrbitSurfaceTone) -> some View {
        if usesSubduedInspectorCards {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: semanticSymbolName(for: tone))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(semanticForegroundColor(for: tone))
                    .frame(width: 16)
                    .padding(.top, 2)

                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .orbitSurface(tone)
        } else {
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .orbitSurface(tone)
        }
    }

    private var usesSubduedInspectorCards: Bool {
        colorScheme == .dark
    }

    private func semanticBadge(title: String, tone: OrbitSurfaceTone) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Circle()
                .fill(semanticForegroundColor(for: tone))
                .frame(width: 6, height: 6)

            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(semanticForegroundColor(for: tone))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(semanticBackgroundColor(for: tone), in: Capsule())
    }

    private func semanticSymbolName(for tone: OrbitSurfaceTone) -> String {
        switch tone {
        case .success:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .danger:
            return "xmark.circle.fill"
        case .neutral:
            return "info.circle.fill"
        case .accent:
            return "sparkles"
        }
    }

    private func semanticForegroundColor(for tone: OrbitSurfaceTone) -> Color {
        switch tone {
        case .success:
            return .green
        case .warning:
            return .yellow
        case .danger:
            return .red
        case .neutral:
            return .secondary
        case .accent:
            return OrbitPalette.accent
        }
    }

    private func semanticBackgroundColor(for tone: OrbitSurfaceTone) -> Color {
        switch tone {
        case .success:
            return OrbitPalette.successSoft
        case .warning:
            return OrbitPalette.warningSoft
        case .danger:
            return OrbitPalette.dangerSoft
        case .neutral:
            return OrbitPalette.chromeFill
        case .accent:
            return OrbitPalette.accentSoft
        }
    }

    private var statusDescriptionText: String {
        switch account.providerRule {
        case .chatgptOAuth:
            return L10n.tr("手动更新会在线刷新该账号凭据并同步在线额度；界面统一按剩余百分比展示。")
        case .claudeProfile:
            return L10n.tr("手动更新只记录本地 Claude Profile 状态，不会同步 claude.ai 登录态。")
        case .claudeCompatible where account.providerPresetID == "anthropic":
            return L10n.tr("手动更新会向 Anthropic 发起极小探测请求，并读取响应头中的 requests 与 token 限额。")
        case .openAICompatible, .claudeCompatible:
            return L10n.tr("手动更新只确认当前 Provider API Key 的本地凭据是否可用。")
        case .githubCopilot:
            return L10n.tr("手动更新会校验本地 GitHub Copilot 登录态，并刷新当前可用模型；如果后续 CLI 暴露 quota 数据，也会归档到这里。")
        }
    }

    private func formattedDate(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .standard) ?? L10n.tr("未知")
    }

    private func claudeValueSummary(_ value: ClaudeRateLimitValueSnapshot) -> String {
        let remaining = value.remaining.map(String.init) ?? L10n.tr("未知")
        let limit = value.limit.map(String.init) ?? L10n.tr("未知")
        return "\(remaining) / \(limit)"
    }
}

private struct CopilotSessionQueueCard: View {
    let item: CopilotSessionQueueItem
    let isExecuting: Bool
    let isDesktopDisabled: Bool
    let isCLIDisabled: Bool
    let onRunCLI: () -> Void
    let onRunDesktop: () -> Void
    let onArchive: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(item.title)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)

                        Text(item.status.displayName)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(item.status.foregroundColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(item.status.backgroundColor, in: Capsule())
                    }

                    Text(URL(fileURLWithPath: item.workspacePath, isDirectory: true).lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text(item.lastMessageAt.formatted(date: .abbreviated, time: .standard))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 8)

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .help(L10n.tr("删除队列项"))
            }

            HStack(spacing: 8) {
                Button {
                    onRunCLI()
                } label: {
                    Label(isExecuting ? L10n.tr("发送中...") : L10n.tr("Codex CLI"), systemImage: "terminal")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isExecuting || isCLIDisabled || item.status != .pending)

                Button {
                    onRunDesktop()
                } label: {
                    if item.codexThreadID == nil {
                        Label(L10n.tr("同步到 Codex"), systemImage: "arrow.triangle.2.circlepath")
                    } else {
                        Label(L10n.tr("打开线程"), systemImage: "macwindow")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isExecuting || isDesktopDisabled || (item.codexThreadID == nil && item.status != .pending))

                Button {
                    onArchive()
                } label: {
                    Label(L10n.tr("归档"), systemImage: "archivebox")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(item.status == .archived)

                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OrbitPalette.floatingPanel, in: RoundedRectangle(cornerRadius: OrbitRadius.row, style: .continuous))
    }
}

private struct CopilotSessionImportSheet: View {
    let candidates: [CopilotSessionCandidate]
    let errorMessage: String?
    let isImporting: Bool
    let onImport: (CopilotSessionCandidate) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("选择 Copilot Session"))
                        .font(.title3.bold())
                    Text(L10n.tr("Orbit 会生成本地 handoff 文件并加入接力队列。"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(L10n.tr("关闭")) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if candidates.isEmpty {
                Text(L10n.tr("该目录没有可导入的 Copilot Chat session。"))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(candidates) { candidate in
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(candidate.title)
                                        .font(.headline)
                                        .lineLimit(1)

                                    Text(candidate.sessionID)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)

                                    HStack(spacing: 8) {
                                        Text(candidate.lastMessageAt.formatted(date: .abbreviated, time: .standard))
                                        if candidate.hasPendingEdits {
                                            Text(L10n.tr("有待应用编辑"))
                                        }
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                }

                                Spacer()

                                Button(isImporting ? L10n.tr("导入中...") : L10n.tr("导入")) {
                                    onImport(candidate)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(isImporting)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                OrbitPalette.floatingPanel,
                                in: RoundedRectangle(cornerRadius: OrbitRadius.row, style: .continuous)
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(20)
        .frame(width: 620, height: 460, alignment: .topLeading)
    }
}

private extension CopilotSessionQueueItemStatus {
    var displayName: String {
        switch self {
        case .pending:
            return L10n.tr("待接手")
        case .sent:
            return L10n.tr("已发送")
        case .archived:
            return L10n.tr("已归档")
        }
    }

    var foregroundColor: Color {
        switch self {
        case .pending:
            return OrbitPalette.accent
        case .sent:
            return .green
        case .archived:
            return .secondary
        }
    }

    var backgroundColor: Color {
        switch self {
        case .pending:
            return OrbitPalette.accentSoft
        case .sent:
            return OrbitPalette.successSoft
        case .archived:
            return OrbitPalette.chromeFill
        }
    }
}

private struct CLIDirectoryHistoryCard: View {
    let record: CLILaunchRecord
    let isDisabled: Bool
    let onOpen: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .center, spacing: 8) {
                        Text(URL(fileURLWithPath: record.path).lastPathComponent)
                            .font(.headline)
                            .lineLimit(1)

                        Text(record.target.displayName)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(OrbitPalette.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(OrbitPalette.accentSoft, in: Capsule())

                        Spacer(minLength: 8)

                        Text(L10n.tr("点击启动 %@", record.target.displayName))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(isDisabled ? .tertiary : .secondary)
                    }

                    Text(record.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .help(isDisabled ? L10n.tr("当前不可点击") : L10n.tr("点击快速启动 %@", record.target.displayName))
            .accessibilityLabel(L10n.tr("点击启动 %@", record.target.displayName))

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.callout.weight(.semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .disabled(isDisabled)
            .help(isDisabled ? L10n.tr("当前不可点击") : L10n.tr("删除此目录"))
            .accessibilityLabel(L10n.tr("删除此目录"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: OrbitRadius.row, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: OrbitRadius.row, style: .continuous)
                .strokeBorder(overlayColor, lineWidth: isHovering && !isDisabled ? 1 : 0)
        )
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private var backgroundColor: Color {
        if isDisabled {
            return OrbitPalette.floatingPanelDisabled
        }
        return isHovering ? OrbitPalette.floatingPanelHover : OrbitPalette.floatingPanel
    }

    private var overlayColor: Color {
        isHovering ? OrbitPalette.accent.opacity(0.2) : OrbitPalette.hoverBorder
    }
}

private struct BannerView: View {
    let state: BannerState
    let isActionInProgress: Bool
    let onAction: (BannerAction) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.headline)
                .foregroundStyle(iconColor)
            Text(state.message)
                .lineLimit(2)
            Spacer()
            if let action = state.action {
                Button(isActionInProgress ? L10n.tr("处理中...") : action.title) {
                    onAction(action)
                }
                .buttonStyle(.bordered)
                .disabled(isActionInProgress)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(backgroundColor)
    }

    private var iconName: String {
        switch state.level {
        case .info:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .error:
            return "xmark.octagon.fill"
        }
    }

    private var backgroundColor: Color {
        switch state.level {
        case .info:
            return OrbitPalette.successSoft
        case .warning:
            return OrbitPalette.warningSoft
        case .error:
            return OrbitPalette.dangerSoft
        }
    }

    private var iconColor: Color {
        switch state.level {
        case .info:
            return .green
        case .warning:
            return .yellow
        case .error:
            return .red
        }
    }
}

private enum MenuBarPanelMetrics {
    static let width: CGFloat = 360
    static let maxAccountListHeight: CGFloat = 300
    static let accountRowSpacing: CGFloat = 8
    static let accountRowCornerRadius: CGFloat = 12
    static let accountRowHorizontalPadding: CGFloat = 12
    static let accountRowVerticalPadding: CGFloat = 10
    static let estimatedAccountRowHeight: CGFloat = 68
}

private struct MenuBarAccountListHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct MenuBarPanelHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct MenuBarAccountRow: View {
    let account: ManagedAccount
    let snapshot: QuotaSnapshot?
    let claudeSnapshot: ClaudeRateLimitSnapshot?
    let switchButtonTitle: String
    let isSwitchDisabled: Bool
    let onSwitch: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(account.displayName)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    AccountPlatformBadge(title: account.accountListBadgeTitle)
                }

                if let summaryText {
                    Text(summaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(account.platform == .claude ? L10n.tr("状态未同步") : L10n.tr("额度未同步"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            if account.isActive {
                Label(L10n.tr("当前"), systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            }
            else {
                Button(switchButtonTitle) {
                    onSwitch()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isSwitchDisabled)
                .focusable(false)
            }
        }
        .padding(.horizontal, MenuBarPanelMetrics.accountRowHorizontalPadding)
        .padding(.vertical, MenuBarPanelMetrics.accountRowVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundColor, in: rowShape)
        .overlay {
            rowShape
                .strokeBorder(borderColor, lineWidth: 1)
        }
    }

    private var rowShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: MenuBarPanelMetrics.accountRowCornerRadius, style: .continuous)
    }

    private var backgroundColor: Color {
        account.isActive ? OrbitPalette.selectionFill : OrbitPalette.chromeSubtle
    }

    private var borderColor: Color {
        account.isActive ? OrbitPalette.accent.opacity(0.18) : OrbitPalette.divider
    }

    private var summaryText: String? {
        if let snapshot {
            return L10n.tr("剩余 %@", snapshot.remainingSummary)
        }
        if let claudeSnapshot {
            if let remaining = claudeSnapshot.requests.remaining {
                return L10n.tr("请求剩余 %@", "\(remaining)")
            }
            return L10n.tr("请求剩余 未知")
        }
        if account.platform == .claude, account.authKind == .claudeProfile {
            return L10n.tr("本地 Profile")
        }
        return nil
    }
}

struct MenuBarContentView: View {
    @ObservedObject var model: AppViewModel
    let onOpenAccounts: () -> Void
    let onOpenAddAccount: () -> Void
    let onPreferredHeightChange: (CGFloat) -> Void

    @AppStorage(AppAppearancePreference.storageKey) private var appearancePreference = AppAppearancePreference.system.rawValue
    @State private var measuredAccountListHeight: CGFloat = 0
    @State private var measuredPanelHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let active = model.activeAccount {
                Text(L10n.tr("当前账号：%@", active.displayName))
                    .font(.headline)
            } else {
                Text(L10n.tr("当前没有激活账号"))
                    .font(.headline)
            }

            Divider()

            if model.accounts.isEmpty {
                Text(L10n.tr("暂无账号"))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: MenuBarPanelMetrics.accountRowSpacing) {
                        ForEach(model.accounts) { account in
                            MenuBarAccountRow(
                                account: account,
                                snapshot: model.snapshot(for: account.id),
                                claudeSnapshot: model.claudeRateLimitSnapshot(for: account.id),
                                switchButtonTitle: switchButtonTitle(for: account),
                                isSwitchDisabled: account.isActive || model.isSwitchInProgress,
                                onSwitch: {
                                    Task { await model.switchToAccount(account) }
                                }
                            )
                        }
                    }
                    .background {
                        GeometryReader { proxy in
                            Color.clear
                                .preference(
                                    key: MenuBarAccountListHeightPreferenceKey.self,
                                    value: proxy.size.height
                                )
                        }
                    }
                }
                .frame(height: accountListHeight)
                .onPreferenceChange(MenuBarAccountListHeightPreferenceKey.self) { height in
                    Task { @MainActor in
                        measuredAccountListHeight = height
                    }
                }
            }

            Divider()

            if !model.focusedPlatformUnsupportedMessage.isEmpty {
                Text(model.focusedPlatformUnsupportedMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            quickActionsSection
        }
        .padding(14)
        .frame(width: MenuBarPanelMetrics.width)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .preference(key: MenuBarPanelHeightPreferenceKey.self, value: proxy.size.height)
            }
        }
        .onPreferenceChange(MenuBarPanelHeightPreferenceKey.self) { height in
            Task { @MainActor in
                guard abs(height - measuredPanelHeight) > 1 else { return }
                measuredPanelHeight = height
                onPreferredHeightChange(height)
            }
        }
        .preferredColorScheme(resolvedAppearancePreference.colorScheme)
        .task {
            await model.prepare()
        }
    }

    private var resolvedAppearancePreference: AppAppearancePreference {
        AppAppearancePreference.resolved(from: appearancePreference)
    }

    private var accountListHeight: CGFloat {
        min(resolvedAccountListContentHeight, MenuBarPanelMetrics.maxAccountListHeight)
    }

    private var resolvedAccountListContentHeight: CGFloat {
        if measuredAccountListHeight > 0 {
            return measuredAccountListHeight
        }

        let count = CGFloat(model.accounts.count)
        let spacing = max(0, count - 1) * MenuBarPanelMetrics.accountRowSpacing
        return (count * MenuBarPanelMetrics.estimatedAccountRowHeight) + spacing
    }

    private var shouldShowStandaloneMainInstanceAction: Bool {
        model.canOperateFocusedMainCodexInstance && model.restartPromptMessage == nil
    }

    private func switchButtonTitle(for account: ManagedAccount) -> String {
        if model.isVerifyingSwitch(for: account.id) {
            return L10n.tr("验证中")
        }
        if model.isSwitchingAccount(account.id) {
            return L10n.tr("切换中")
        }
        return L10n.tr("切换")
    }

    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("快捷操作"))
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            if model.focusedPlatform == .codex, let recommendation = model.lowQuotaSwitchRecommendation {
                VStack(alignment: .leading, spacing: 8) {
                    Text(recommendation.promptTitle)
                        .font(.callout.weight(.medium))
                    Text(recommendation.promptMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button(L10n.tr("稍后")) {
                            model.dismissLowQuotaSwitchRecommendation()
                        }
                        .buttonStyle(.bordered)

                        Button(recommendation.switchButtonTitle) {
                            Task { @MainActor in await model.switchToRecommendedLowQuotaAccount() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isSwitchInProgress)
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if model.focusedPlatform == .codex, let promptMessage = model.restartPromptMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.tr("切换完成后，是否现在重启 Codex？"))
                        .font(.callout.weight(.medium))
                    Text(promptMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button(L10n.tr("稍后")) {
                            Task { @MainActor in model.dismissRestartPrompt() }
                        }
                        .buttonStyle(.bordered)

                        Button(model.isRestartingCodex ? L10n.tr("正在重启...") : L10n.tr("立即重启 Codex")) {
                            Task { @MainActor in await model.performBannerAction(.restartCodex) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isRestartingCodex)
                    }
                }
                .padding(10)
                .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    quickActionButton(L10n.tr("打开主窗口"), systemImage: "macwindow") {
                        onOpenAccounts()
                    }

                    quickActionButton(L10n.tr("新增账号"), systemImage: "plus.circle") {
                        onOpenAddAccount()
                    }
                    .disabled(!model.canAddAccounts)
                }

                HStack(spacing: 10) {
                    quickActionButton(
                        model.isRefreshingAllStatuses ? L10n.tr("刷新中") : L10n.tr("刷新状态"),
                        systemImage: "arrow.clockwise",
                        isDisabled: model.isRefreshingAllStatuses
                            || model.accounts.isEmpty
                            || !model.focusedPlatformCapabilities.supportsStatusRefresh
                    ) {
                        Task { await model.refreshAllAccountStatuses() }
                    }

                    if shouldShowStandaloneMainInstanceAction {
                        quickActionButton(
                            model.isRestartingCodex ? model.mainCodexInstanceActionInProgressTitle : model.mainCodexInstanceActionTitle,
                            systemImage: "power",
                            isProminent: true,
                            isDisabled: model.isRestartingCodex
                        ) {
                            Task { @MainActor in await model.performBannerAction(.restartCodex) }
                        }
                    } else {
                        quickActionButton(L10n.tr("退出应用"), systemImage: "xmark.circle") {
                            NSApp.terminate(nil)
                        }
                    }
                }

                if shouldShowStandaloneMainInstanceAction {
                    quickActionButton(L10n.tr("退出应用"), systemImage: "xmark.circle") {
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func quickActionButton(
        _ title: String,
        systemImage: String,
        isProminent: Bool = false,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        if isProminent {
            Button(action: action) {
                Label(title, systemImage: systemImage)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isDisabled)
        } else {
            Button(action: action) {
                Label(title, systemImage: systemImage)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isDisabled)
        }
    }
}
