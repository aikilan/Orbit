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
        .task {
            WindowRouter.shared.register { id in
                openWindow(id: id)
            }
            (NSApp.delegate as? AppDelegate)?.installStatusBarControllerIfNeeded(with: model)
            await model.prepare()
            await model.reconcileCurrentAuthState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await model.reconcileCurrentAuthStateForAppActivation()
            }
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
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("Orbit"))
                .font(.system(size: 32, weight: .bold, design: .rounded))

            Text(L10n.tr("本地 LLM 账号工作台"))
                .font(.callout)
                .foregroundStyle(.secondary)

            Text(L10n.tr("账号"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
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
                    Button {
                        model.selectedAccountID = account.id
                    } label: {
                        AccountListRow(
                            account: account,
                            snapshot: model.snapshot(for: account.id),
                            claudeSnapshot: model.claudeRateLimitSnapshot(for: account.id),
                            isSelected: resolvedSelectedAccountID == account.id
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(account.isActive ? L10n.tr("当前正在使用") : L10n.tr("切换到此账号")) {
                            Task { await model.switchToAccount(account) }
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
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(OrbitPalette.sidebar)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var sidebarEmptyState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.tr("还没有账号"))
                    .font(.headline)

                Text(L10n.tr("先新增一个账号，支持 Codex 浏览器登录 / API Key，以及 Claude Profile / Anthropic API Key。"))
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
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("快捷操作"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Button {
                presentAddAccountWindow()
            } label: {
                Label(L10n.tr("新增账号"), systemImage: "plus.circle.fill")
            }
            .buttonStyle(.bordered)
            .disabled(!model.canAddAccounts)

            if let homeButtonTitle = model.focusedPlatformHomeButtonTitle {
                Button {
                    model.openFocusedPlatformHomeInFinder()
                } label: {
                    Label(homeButtonTitle, systemImage: "folder")
                }
                .buttonStyle(.bordered)
            }

            Button {
                Task { await model.refreshAllAccountStatuses() }
            } label: {
                Label(model.isRefreshingAllStatuses ? L10n.tr("正在刷新账号状态...") : L10n.tr("刷新全部状态"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(
                model.isRefreshingAllStatuses
                    || model.accounts.isEmpty
                    || !model.focusedPlatformCapabilities.supportsStatusRefresh
            )

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
            .padding(.top, 4)

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

    private var resolvedSelectedAccountID: UUID? {
        model.selectedAccountID ?? model.activeAccount?.id
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
                        Task { await model.performBannerAction(action) }
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
                authFilePath: authFilePath,
                onRename: { model.renameAccount(account.id, to: $0) },
                onEditProvider: { presentEditProviderWindow(for: account.id) },
                onRefreshStatus: { Task { await model.refreshAccountStatus(account) } },
                onSwitch: { Task { await model.switchToAccount(account) } },
                onDelete: { model.requestDeleteAccount(account.id) }
            )
            .id(account.id)
        } else {
            ContentUnavailableView(
                L10n.tr("还没有账号"),
                systemImage: "person.2.slash",
                description: Text(
                    L10n.tr("先新增一个账号，支持 Codex 浏览器登录 / API Key，以及 Claude Profile / Anthropic API Key。")
                )
            )
        }
    }

    private func configurationPathText(for account: ManagedAccount) -> String {
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

    private func presentEditProviderWindow(for accountID: UUID) {
        model.openEditProvider(for: accountID)
        presentWindow(id: "add-account")
    }
}

private struct AccountPlatformBadge: View {
    let platform: PlatformKind

    var body: some View {
        Text(platform.displayName)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.05), in: Capsule())
    }
}

private struct AccountListRow: View {
    let account: ManagedAccount
    let snapshot: QuotaSnapshot?
    let claudeSnapshot: ClaudeRateLimitSnapshot?
    let isSelected: Bool

    @State private var isHovering = false

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
                AccountPlatformBadge(platform: account.platform)
            }

            Text(accountSubtitle)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Label(statusSummary ?? fallbackStatusSummary, systemImage: "gauge.with.dots.needle.67percent")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
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
        .animation(.easeOut(duration: 0.14), value: isSelected)
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private var accountSubtitle: String {
        switch account.providerRule {
        case .chatgptOAuth:
            return account.email ?? account.accountIdentifier
        case .openAICompatible, .claudeCompatible:
            return account.email ?? account.resolvedProviderDisplayName
        case .claudeProfile:
            return L10n.tr("Claude Profile")
        }
    }

    private var statusSummary: String? {
        if let snapshot {
            return L10n.tr("剩余 %@", snapshot.remainingSummary)
        }
        if let claudeSnapshot {
            return L10n.tr("请求剩余 %@", claudeRemainingText(claudeSnapshot.requests.remaining))
        }
        if account.providerRule == .claudeProfile {
            return L10n.tr("本地 Profile")
        }
        return nil
    }

    private var fallbackStatusSummary: String {
        account.platform == .claude ? L10n.tr("状态未同步") : L10n.tr("额度未同步")
    }

    private var backgroundColor: Color {
        if isSelected {
            return OrbitPalette.panel
        }
        if account.isActive {
            return OrbitPalette.panelMuted
        }
        if isHovering {
            return OrbitPalette.panel
        }
        return Color.clear
    }

    private var borderColor: Color {
        if isSelected {
            return OrbitPalette.accent.opacity(0.22)
        }
        if isHovering {
            return Color.black.opacity(0.08)
        }
        return Color.clear
    }

    private func claudeRemainingText(_ value: Int?) -> String {
        guard let value else { return L10n.tr("未知") }
        return "\(value)"
    }
}

private struct AccountDetailView: View {
    @ObservedObject var model: AppViewModel
    let account: ManagedAccount
    let snapshot: QuotaSnapshot?
    let claudeSnapshot: ClaudeRateLimitSnapshot?
    let authFilePath: String
    let onRename: (String) -> Void
    let onEditProvider: () -> Void
    let onRefreshStatus: () -> Void
    let onSwitch: () -> Void
    let onDelete: () -> Void

    @State private var draftName = ""

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
                    .background(Color.primary.opacity(0.05), in: Capsule())
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
        }
    }

    private var credentialSummaryValue: String {
        switch account.providerRule {
        case .claudeProfile:
            return L10n.tr("本地快照")
        case .chatgptOAuth, .openAICompatible, .claudeCompatible:
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
        }
    }

    private var workspaceStatusText: String? {
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
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.tr("打开 CLI"))
                        .font(.title2.bold())

                    Text(cliLaunchHelpText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

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

            Rectangle()
                .fill(Color.white.opacity(0.5))
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

            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.tr("快捷操作"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button(model.isRefreshingStatus(for: account.id) ? L10n.tr("正在更新状态...") : L10n.tr("手动更新状态")) {
                        onRefreshStatus()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.isRefreshingStatus(for: account.id) || model.isRefreshingAllStatuses || model.isSwitchInProgress)
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

                    if model.shouldOfferRestartCodex(for: account) {
                        Button(model.isRestartingCodex ? L10n.tr("正在重启 Codex...") : L10n.tr("重启 Codex")) {
                            Task { await model.performBannerAction(.restartCodex) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(model.isRestartingCodex)
                    }
                }
            }
        }
        .padding(24)
        .orbitSurface(.accent, radius: OrbitRadius.hero)
    }

    private var secondaryLaunchActionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("附加操作"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(L10n.tr("切换当前账号或启动独立实例。"))
                .font(.footnote)
                .foregroundStyle(.secondary)

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

            Button(L10n.tr("删除账号"), role: .destructive) {
                onDelete()
            }
            .buttonStyle(.bordered)
            .disabled(model.isRefreshingStatus(for: account.id) || model.isSwitchInProgress)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .orbitSurface(.danger)
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
            case .chatgptOAuth, .openAICompatible:
                return L10n.tr("打开 CLI 会启动应用生成的 Claude Code patched runtime，并自动桥接当前账号的 OpenAI 兼容凭据。")
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

    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(account.platform == .codex ? L10n.tr("额度快照") : L10n.tr("限额快照"))
                .font(.headline)

            if account.platform == .codex {
                if let snapshot {
                    HStack(spacing: 10) {
                        quotaStat(title: L10n.tr("5 小时剩余"), value: snapshot.primary.remainingPercentText)
                        quotaStat(title: L10n.tr("7 天剩余"), value: snapshot.secondary.remainingPercentText)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        inspectorRow(L10n.tr("口径"), L10n.tr("剩余百分比（与 Codex 状态面板一致）"))
                        inspectorRow(L10n.tr("计划类型"), snapshot.planType ?? L10n.tr("未知"))
                        inspectorRow(L10n.tr("来源"), snapshot.source.displayName)
                        inspectorRow(L10n.tr("采集时间"), snapshot.capturedAt.formatted(date: .abbreviated, time: .standard))
                        inspectorRow(L10n.tr("5 小时重置"), snapshot.primary.resetsAt?.formatted(date: .abbreviated, time: .standard) ?? L10n.tr("未知"))
                        inspectorRow(L10n.tr("7 天重置"), snapshot.secondary.resetsAt?.formatted(date: .abbreviated, time: .standard) ?? L10n.tr("未知"))

                        if let credits = snapshot.credits {
                            inspectorRow(L10n.tr("Credits"), credits.unlimited ? L10n.tr("unlimited") : (credits.balance.map { "\($0)" } ?? L10n.tr("无")))
                        }
                    }
                } else {
                    Text(L10n.tr("这个账号还没有被可靠归档的本地额度快照。切换到该账号并实际使用一段时间后，应用会从本地会话事件中抓取额度。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .orbitSurface(.warning)
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
                Text(L10n.tr("这是本地 Claude Profile；应用不会在线刷新 claude.ai 登录态，可直接从应用启动 Claude CLI 验证。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .orbitSurface(.warning)
            } else {
                Text(L10n.tr("还没有刷新过 Anthropic 限额。手动更新状态后，应用会读取响应头中的 requests 和 token 限额信息。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .orbitSurface(.warning)
            }
        }
    }

    private func quotaStat(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.bold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(OrbitPalette.panelMuted, in: RoundedRectangle(cornerRadius: OrbitRadius.row, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: OrbitRadius.row, style: .continuous)
                .strokeBorder(OrbitPalette.divider, lineWidth: 1)
        )
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

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("账号状态"))
                .font(.headline)

            VStack(alignment: .leading, spacing: 10) {
                inspectorRow(L10n.tr("上次检查"), account.lastStatusCheckAt?.formatted(date: .abbreviated, time: .standard) ?? L10n.tr("尚未手动更新"))
                inspectorRow(L10n.tr("最近结果"), account.lastStatusMessage ?? L10n.tr("尚未手动更新"))
                inspectorRow(L10n.tr("说明"), statusDescriptionText)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .orbitSurface(statusTone)
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

                        Spacer(minLength: 8)

                        Text(L10n.tr("点击启动 CLI"))
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
            .help(isDisabled ? L10n.tr("当前不可点击") : L10n.tr("点击快速启动 CLI"))

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
            return Color.white.opacity(0.4)
        }
        return isHovering ? Color.white.opacity(0.95) : Color.white.opacity(0.78)
    }

    private var overlayColor: Color {
        isHovering ? OrbitPalette.accent.opacity(0.2) : Color.black.opacity(0.05)
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

                    AccountPlatformBadge(platform: account.platform)
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
        account.isActive ? Color.primary.opacity(0.07) : Color.primary.opacity(0.025)
    }

    private var borderColor: Color {
        account.isActive ? Color.primary.opacity(0.06) : Color.primary.opacity(0.035)
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
        .task {
            await model.prepare()
        }
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

    private var shouldShowStandaloneRestartAction: Bool {
        model.focusedPlatform == .codex && model.canQuickRestartCodex && model.restartPromptMessage == nil
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
                            Task { await model.switchToRecommendedLowQuotaAccount() }
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
                            model.dismissRestartPrompt()
                        }
                        .buttonStyle(.bordered)

                        Button(model.isRestartingCodex ? L10n.tr("正在重启...") : L10n.tr("立即重启 Codex")) {
                            Task { await model.performBannerAction(.restartCodex) }
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

                    if shouldShowStandaloneRestartAction {
                        quickActionButton(
                            model.isRestartingCodex ? L10n.tr("正在重启") : L10n.tr("重启 Codex"),
                            systemImage: "power",
                            isProminent: true,
                            isDisabled: model.isRestartingCodex
                        ) {
                            Task { await model.performBannerAction(.restartCodex) }
                        }
                    } else {
                        quickActionButton(L10n.tr("退出应用"), systemImage: "xmark.circle") {
                            NSApp.terminate(nil)
                        }
                    }
                }

                if shouldShowStandaloneRestartAction {
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
