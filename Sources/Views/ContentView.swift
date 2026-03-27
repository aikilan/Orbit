import AppKit
import SwiftUI

private enum SidebarLayoutMetrics {
    static let minWidth: CGFloat = 260
    static let idealWidth: CGFloat = 300
    static let maxWidth: CGFloat = 360
    static let horizontalPadding: CGFloat = 16
    static let sectionVerticalPadding: CGFloat = 16
    static let footerPadding: CGFloat = 16
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
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var sidebarHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.tr("账号"))
                .font(.title2.bold())
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
        List(selection: $model.selectedAccountID) {
            ForEach(model.accounts) { account in
                AccountListRow(
                    account: account,
                    snapshot: model.snapshot(for: account.id),
                    claudeSnapshot: model.claudeRateLimitSnapshot(for: account.id)
                )
                    .tag(account.id)
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button(account.isActive ? L10n.tr("当前正在使用") : L10n.tr("切换到此账号")) {
                            Task { await model.switchToAccount(account) }
                        }
                        .disabled(account.isActive || model.isRefreshingStatus(for: account.id) || model.isSwitchInProgress)

                        Button(model.isRefreshingStatus(for: account.id) ? L10n.tr("正在更新状态...") : L10n.tr("手动更新状态")) {
                            Task { await model.refreshAccountStatus(account) }
                        }
                        .disabled(model.isRefreshingStatus(for: account.id) || model.isRefreshingAllStatuses || model.isSwitchInProgress)
                    }
            }
        }
        .listStyle(.sidebar)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var sidebarEmptyState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.tr("还没有账号"))
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Text(L10n.tr("先新增一个账号，支持 Codex 浏览器登录 / API Key，以及 Claude Profile / Anthropic API Key。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, SidebarLayoutMetrics.horizontalPadding)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                presentWindow(id: "add-account")
            } label: {
                Label(L10n.tr("新增账号"), systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
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

    private func presentWindow(id: String) {
        model.noteProgrammaticActivation()
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            openWindow(id: id)
            NSApp.activate(ignoringOtherApps: true)
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
}

private struct AccountPlatformBadge: View {
    let platform: PlatformKind

    var body: some View {
        Text(platform.displayName)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.12), in: Capsule())
    }
}

private struct AccountListRow: View {
    let account: ManagedAccount
    let snapshot: QuotaSnapshot?
    let claudeSnapshot: ClaudeRateLimitSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(account.displayName)
                    .font(.headline)
                if account.isActive {
                    Text(L10n.tr("当前"))
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.12), in: Capsule())
                }
                AccountPlatformBadge(platform: account.platform)
            }

            Text(accountSubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let statusSummary {
                Label(statusSummary, systemImage: "gauge.with.dots.needle.67percent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(account.platform == .claude ? L10n.tr("状态未同步") : L10n.tr("额度未同步"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var accountSubtitle: String {
        switch account.authKind {
        case .chatgpt:
            return account.email ?? account.accountIdentifier
        case .openAIAPIKey:
            return account.email ?? "OpenAI API Key"
        case .claudeProfile:
            return L10n.tr("Claude Profile")
        case .anthropicAPIKey:
            return account.email ?? "Anthropic API Key"
        }
    }

    private var statusSummary: String? {
        if let snapshot {
            return L10n.tr("剩余 %@", snapshot.remainingSummary)
        }
        if let claudeSnapshot {
            return L10n.tr("请求剩余 %@", claudeRemainingText(claudeSnapshot.requests.remaining))
        }
        if account.platform == .claude, account.authKind == .claudeProfile {
            return L10n.tr("本地 Profile")
        }
        return nil
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
    let onRefreshStatus: () -> Void
    let onSwitch: () -> Void
    let onDelete: () -> Void

    @State private var draftName = ""

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 24) {
                    quickActionSection

                    VStack(alignment: .leading, spacing: 12) {
                        Text(L10n.tr("账号详情"))
                            .font(.largeTitle.bold())

                        HStack(alignment: .center, spacing: 12) {
                            TextField(L10n.tr("显示名"), text: $draftName)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 280)
                            Button(L10n.tr("保存名称")) {
                                onRename(draftName)
                            }
                            .buttonStyle(.bordered)
                        }

                        infoGrid
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                    quotaSection

                    statusSection

                    pathSection

                    deleteSection
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                cliDirectoryHistorySection
                    .frame(width: 320, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(24)
        }
        .onAppear {
            draftName = account.displayName
        }
        .onChange(of: account.id) { _, _ in
            draftName = account.displayName
        }
    }

    private var infoGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
            infoRow(L10n.tr("账号类型"), account.authKind.displayName)
            infoRow(L10n.tr("账号 ID"), account.accountIdentifier)
            infoRow(credentialSummaryLabel, credentialSummaryValue)
            infoRow(L10n.tr("套餐类型"), account.planType ?? L10n.tr("未知"))
            if let codexUsageStatusText {
                infoRow(L10n.tr("Codex 使用状态"), codexUsageStatusText)
            }
            if let codexAvailabilityText {
                infoRow(L10n.tr("可用性"), codexAvailabilityText)
            }
            if let codexLimitStatusText {
                infoRow(L10n.tr("额度限制"), codexLimitStatusText)
            }
            infoRow(L10n.tr("最后刷新"), account.lastRefreshAt?.formatted(date: .abbreviated, time: .standard) ?? L10n.tr("未知"))
            infoRow(L10n.tr("最后使用"), account.lastUsedAt?.formatted(date: .abbreviated, time: .standard) ?? L10n.tr("从未"))
        }
    }

    private var credentialSummaryLabel: String {
        switch account.authKind {
        case .chatgpt:
            return L10n.tr("邮箱")
        case .openAIAPIKey, .anthropicAPIKey:
            return L10n.tr("Key 摘要")
        case .claudeProfile:
            return L10n.tr("Profile")
        }
    }

    private var credentialSummaryValue: String {
        switch account.authKind {
        case .claudeProfile:
            return L10n.tr("本地快照")
        case .chatgpt, .openAIAPIKey, .anthropicAPIKey:
            return account.email ?? L10n.tr("未解析")
        }
    }

    private var codexUsageStatusText: String? {
        if account.platform != .codex || account.authKind == .openAIAPIKey {
            return nil
        }
        return account.subscriptionDetails?.usageStatusText
    }

    private var codexAvailabilityText: String? {
        if account.platform != .codex || account.authKind == .openAIAPIKey {
            return nil
        }
        guard let details = account.subscriptionDetails, details.allowed != nil else {
            return nil
        }
        return details.availabilityText
    }

    private var codexLimitStatusText: String? {
        if account.platform != .codex || account.authKind == .openAIAPIKey {
            return nil
        }
        guard let details = account.subscriptionDetails, details.limitReached != nil else {
            return nil
        }
        return details.limitStatusText
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
    }

    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(account.platform == .codex ? L10n.tr("额度快照") : L10n.tr("限额快照"))
                .font(.title2.bold())

            if account.platform == .codex {
                if let snapshot {
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                        infoRow(L10n.tr("5 小时剩余"), snapshot.primary.remainingPercentText)
                        infoRow(L10n.tr("7 天剩余"), snapshot.secondary.remainingPercentText)
                        infoRow(L10n.tr("口径"), L10n.tr("剩余百分比（与 Codex 状态面板一致）"))
                        infoRow(L10n.tr("计划类型"), snapshot.planType ?? L10n.tr("未知"))
                        infoRow(L10n.tr("来源"), snapshot.source.displayName)
                        infoRow(L10n.tr("采集时间"), snapshot.capturedAt.formatted(date: .abbreviated, time: .standard))
                        infoRow(L10n.tr("5 小时重置"), snapshot.primary.resetsAt?.formatted(date: .abbreviated, time: .standard) ?? L10n.tr("未知"))
                        infoRow(L10n.tr("7 天重置"), snapshot.secondary.resetsAt?.formatted(date: .abbreviated, time: .standard) ?? L10n.tr("未知"))
                        if let credits = snapshot.credits {
                            infoRow(L10n.tr("Credits"), credits.unlimited ? L10n.tr("unlimited") : (credits.balance.map { "\($0)" } ?? L10n.tr("无")))
                        }
                    }
                    .padding(24)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else {
                    Text(L10n.tr("这个账号还没有被可靠归档的本地额度快照。切换到该账号并实际使用一段时间后，应用会从本地会话事件中抓取额度。"))
                        .foregroundStyle(.secondary)
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            } else {
                if let claudeSnapshot {
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                        infoRow(L10n.tr("Requests"), claudeValueSummary(claudeSnapshot.requests))
                        infoRow(L10n.tr("Requests 重置"), formattedDate(claudeSnapshot.requests.resetAt))
                        infoRow(L10n.tr("Input Tokens"), claudeValueSummary(claudeSnapshot.inputTokens))
                        infoRow(L10n.tr("Input Tokens 重置"), formattedDate(claudeSnapshot.inputTokens.resetAt))
                        infoRow(L10n.tr("Output Tokens"), claudeValueSummary(claudeSnapshot.outputTokens))
                        infoRow(L10n.tr("Output Tokens 重置"), formattedDate(claudeSnapshot.outputTokens.resetAt))
                        infoRow(L10n.tr("来源"), claudeSnapshot.source.displayName)
                        infoRow(L10n.tr("采集时间"), claudeSnapshot.capturedAt.formatted(date: .abbreviated, time: .standard))
                    }
                    .padding(24)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else if account.authKind == .claudeProfile {
                    Text(L10n.tr("这是本地 Claude Profile；应用不会在线刷新 claude.ai 登录态，可直接从应用启动 Claude CLI 验证。"))
                        .foregroundStyle(.secondary)
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else {
                    Text(L10n.tr("还没有刷新过 Anthropic 限额。手动更新状态后，应用会读取响应头中的 requests 和 token 限额信息。"))
                        .foregroundStyle(.secondary)
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.tr("账号状态"))
                .font(.title2.bold())

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                infoRow(L10n.tr("上次检查"), account.lastStatusCheckAt?.formatted(date: .abbreviated, time: .standard) ?? L10n.tr("尚未手动更新"))
                infoRow(L10n.tr("最近结果"), account.lastStatusMessage ?? L10n.tr("尚未手动更新"))
                infoRow(L10n.tr("说明"), statusDescriptionText)
            }
            .padding(24)
            .background(statusBackgroundColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var quickActionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.tr("快捷操作"))
                .font(.title2.bold())

            HStack {
                Button(model.isRefreshingStatus(for: account.id) ? L10n.tr("正在更新状态...") : L10n.tr("手动更新状态")) {
                    onRefreshStatus()
                }
                .buttonStyle(.bordered)
                .disabled(model.isRefreshingStatus(for: account.id) || model.isRefreshingAllStatuses || model.isSwitchInProgress)

                Button(switchButtonTitle) {
                    onSwitch()
                }
                .buttonStyle(.borderedProminent)
                .disabled(account.isActive || model.isRefreshingStatus(for: account.id) || model.isSwitchInProgress)

                if account.platform == .codex {
                    Button(isolatedInstanceButtonTitle) {
                        Task { await model.launchIsolatedCodex(for: account) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(
                        !model.canLaunchIsolatedCodex(for: account)
                            || model.isLaunchingIsolatedInstance(for: account.id)
                            || model.isLaunchingCLI(for: account.id)
                            || model.isSwitchInProgress
                    )
                }

                Button(model.isLaunchingCLI(for: account.id) ? L10n.tr("正在打开 CLI...") : L10n.tr("选择目录并打开 CLI")) {
                    chooseDirectoryAndOpenCLI()
                }
                .buttonStyle(.bordered)
                .disabled(
                    model.isRefreshingStatus(for: account.id)
                        || model.isRefreshingAllStatuses
                        || model.isLaunchingCLI(for: account.id)
                        || model.isLaunchingIsolatedInstance(for: account.id)
                        || model.isSwitchInProgress
                )

                if model.shouldOfferRestartCodex(for: account) {
                    Button(model.isRestartingCodex ? L10n.tr("正在重启 Codex...") : L10n.tr("重启 Codex")) {
                        Task { await model.performBannerAction(.restartCodex) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isRestartingCodex)
                }
            }

            if account.platform == .codex {
                Text(isolatedLaunchHelpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var cliDirectoryHistorySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.tr("已打开目录"))
                .font(.title2.bold())

            if recentCLIDirectories.isEmpty {
                Text(L10n.tr("还没有打开过目录。先选择一个目录打开 CLI，后续就能从这里快速启动。"))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(recentCLIDirectories, id: \.self) { path in
                        CLIDirectoryHistoryCard(
                            path: path,
                            isDisabled: model.isLaunchingCLI(for: account.id)
                                || model.isLaunchingIsolatedInstance(for: account.id)
                                || model.isSwitchInProgress,
                            onOpen: {
                                launchCLI(in: URL(fileURLWithPath: path, isDirectory: true))
                            }
                        )
                    }
                }
            }
        }
        .padding(20)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var deleteSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.tr("删除账号"))
                .font(.title2.bold())

            Button(L10n.tr("删除账号"), role: .destructive) {
                onDelete()
            }
            .buttonStyle(.bordered)
            .disabled(model.isRefreshingStatus(for: account.id) || model.isSwitchInProgress)
        }
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

    private var isolatedLaunchHelpText: String {
        if model.hasLaunchedIsolatedInstance(for: account.id) {
            return L10n.tr("该账号的独立实例已在当前会话中启动，为避免重复拉起，当前已禁用再次启动。")
        }
        if account.isActive && account.authKind == .chatgpt {
            return L10n.tr("打开 CLI 会直接使用当前 ~/.codex；当前活跃的 ChatGPT 账号不能再起独立实例，避免触发 refresh_token_reused。")
        }
        if account.isActive {
            return L10n.tr("打开 CLI 会直接使用当前 ~/.codex；独立实例仍会使用独立 CODEX_HOME 和 user-data 目录启动，不会改写当前 ~/.codex。")
        }
        return L10n.tr("打开 CLI 时会为该账号使用独立 CODEX_HOME；独立实例也会使用独立 CODEX_HOME 和 user-data 目录启动，不会改写当前 ~/.codex。")
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

    private var recentCLIDirectories: [String] {
        model.cliWorkingDirectories(for: account.id)
    }

    private func chooseDirectoryAndOpenCLI() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = account.platform == .codex ? L10n.tr("打开 CLI") : L10n.tr("打开 Claude CLI")
        panel.message = account.platform == .codex
            ? L10n.tr("选择一个目录作为 Codex CLI 的启动目录。")
            : L10n.tr("选择一个目录作为 Claude CLI 的启动目录。")
        if let path = recentCLIDirectories.first {
            panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        }

        guard panel.runModal() == .OK, let directoryURL = panel.url else { return }
        launchCLI(in: directoryURL)
    }

    private func launchCLI(in directoryURL: URL) {
        Task {
            await model.openCodexCLI(for: account, workingDirectoryURL: directoryURL)
        }
    }

    private var pathSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(account.platform == .codex ? L10n.tr("当前写入路径") : L10n.tr("配置路径"))
                .font(.title2.bold())
            Text(authFilePath)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var statusBackgroundColor: Color {
        switch account.lastStatusLevel ?? .info {
        case .info:
            return Color.green.opacity(0.08)
        case .warning:
            return Color.yellow.opacity(0.12)
        case .error:
            return Color.red.opacity(0.12)
        }
    }

    private var statusDescriptionText: String {
        switch (account.platform, account.authKind) {
        case (.codex, _):
            return L10n.tr("手动更新会在线刷新该账号凭据并同步在线额度；界面统一按剩余百分比展示。")
        case (.claude, .claudeProfile):
            return L10n.tr("手动更新只记录本地 Claude Profile 状态，不会同步 claude.ai 登录态。")
        case (.claude, .anthropicAPIKey):
            return L10n.tr("手动更新会向 Anthropic 发起极小探测请求，并读取响应头中的 requests 与 token 限额。")
        case (.claude, _):
            return L10n.tr("手动更新会刷新当前账号状态。")
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
    let path: String
    let isDisabled: Bool
    let onOpen: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 8) {
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .font(.headline)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(L10n.tr("点击启动 CLI"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(isDisabled ? .tertiary : .secondary)
                }

                Text(path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(backgroundColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(overlayColor, lineWidth: isHovering && !isDisabled ? 1 : 0)
            )
            .scaleEffect(isHovering && !isDisabled ? 1.01 : 1)
            .animation(.easeOut(duration: 0.12), value: isHovering)
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .disabled(isDisabled)
        .help(isDisabled ? L10n.tr("当前不可点击") : L10n.tr("点击快速启动 CLI"))
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private var backgroundColor: Color {
        if isDisabled {
            return Color.secondary.opacity(0.08)
        }
        return isHovering ? Color.accentColor.opacity(0.16) : Color.accentColor.opacity(0.08)
    }

    private var overlayColor: Color {
        Color.accentColor.opacity(0.35)
    }
}

private struct BannerView: View {
    let state: BannerState
    let isActionInProgress: Bool
    let onAction: (BannerAction) -> Void

    var body: some View {
        HStack {
            Image(systemName: iconName)
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
            return .green.opacity(0.16)
        case .warning:
            return .yellow.opacity(0.18)
        case .error:
            return .red.opacity(0.18)
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
