import SwiftUI

struct AddAccountSheet: View {
    @ObservedObject var model: AppViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: OrbitSpacing.section) {
                    modeSelectorSection
                    formSection

                    if let error = model.addAccountError {
                        Text(error)
                            .foregroundStyle(.red)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .orbitSurface(.danger)
                    }
                }
                .padding(OrbitSpacing.section)
                .frame(maxWidth: 720, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .center)
            }

            Divider()

            footer
        }
        .background(OrbitPalette.background)
        .tint(OrbitPalette.accent)
        .animation(.easeOut(duration: 0.18), value: model.addAccountMode)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: model.addAccountCloseRequestID) { _, requestID in
            guard requestID != nil else { return }
            dismiss()
        }
        .onDisappear {
            model.dismissAddAccountSheet()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: AppIconArtwork.appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 34, height: 34)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.tr("Orbit"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(model.addAccountSheetTitle)
                    .font(.system(size: 28, weight: .bold, design: .rounded))

                Text(model.addAccountStatus)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Button(L10n.tr("关闭")) {
                model.dismissAddAccountSheet()
                dismiss()
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, OrbitSpacing.section)
        .padding(.top, OrbitSpacing.section)
        .padding(.bottom, OrbitSpacing.regular)
    }

    @ViewBuilder
    private var modeSelectorSection: some View {
        if model.isReauthorizingAccount {
            Text(model.selectedAddAccountMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .orbitSurface()
        } else if model.isEditingProviderAccount {
            Text(L10n.tr("仅支持编辑 Provider API Key 账号；规则已锁定，API Key 留空表示继续使用当前凭据。"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .orbitSurface()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.tr("接入方式"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Picker(L10n.tr("接入方式"), selection: $model.addAccountMode) {
                    ForEach(model.availableAddAccountModes) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: model.addAccountMode) { _, mode in
                    model.addAccountError = nil
                    model.addAccountStatus = model.selectedAddAccountMessage
                    if mode == .providerAPIKey {
                        model.addAccountProviderRule = .openAICompatible
                        model.applyProviderPreset(ProviderCatalog.preset(id: "openai"))
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .orbitSurface()
        }
    }

    @ViewBuilder
    private var formSection: some View {
        switch model.addAccountMode {
        case .chatgptBrowser:
            browserSection
        case .providerAPIKey:
            providerSection
        case .claudeProfile:
            claudeProfileSection
        case .githubCopilot:
            copilotSection
        }
    }

    private var browserSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(AddAccountMode.chatgptBrowser.title)
                .font(.title3.bold())

            if let authorizeURL = model.browserAuthorizeURL {
                if model.isBrowserAuthorizationPending {
                    progressRow(L10n.tr("等待浏览器授权完成，或在下方粘贴回调结果。"))
                } else if model.isAuthenticating {
                    progressRow(L10n.tr("正在验证授权结果。"))
                }

                Link(L10n.tr("重新打开授权页面"), destination: authorizeURL)

                Text(L10n.tr("OpenClaw 文档使用的是固定回调地址 `http://localhost:1455/auth/callback`。如果浏览器没有自动返回，请把最终跳转 URL 或 code 粘贴到下面。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField(L10n.tr("粘贴 redirect URL 或 authorization code"), text: $model.browserCallbackInput, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...6)

                HStack {
                    Text(L10n.tr("优先粘贴完整 URL；如果只能拿到 `code`，也可以单独粘贴。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.tr("提交回调")) {
                        Task { await model.submitBrowserCallback() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isAuthenticating)
                }
            } else {
                if model.isReauthorizingAccount {
                    reauthorizationStartPanel
                } else {
                    Text(L10n.tr("点击底部按钮开始浏览器登录。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .orbitSurface(.neutral, radius: OrbitRadius.hero)
    }

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(AddAccountMode.providerAPIKey.title)
                .font(.title3.bold())

            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.tr("规则"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Picker(L10n.tr("规则"), selection: $model.addAccountProviderRule) {
                    Text(ProviderRule.openAICompatible.displayName).tag(ProviderRule.openAICompatible)
                    Text(ProviderRule.claudeCompatible.displayName).tag(ProviderRule.claudeCompatible)
                }
                .pickerStyle(.segmented)
                .disabled(model.isEditingProviderAccount)
                .onChange(of: model.addAccountProviderRule) { _, rule in
                    let defaultPresetID = rule == .claudeCompatible ? "anthropic" : "openai"
                    model.applyProviderPreset(ProviderCatalog.preset(id: defaultPresetID))
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.tr("供应商"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Picker(L10n.tr("供应商"), selection: $model.addAccountProviderPresetID) {
                    ForEach(model.availableProviderPresets) { preset in
                        Text(preset.displayName).tag(preset.id)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: model.addAccountProviderPresetID) { _, presetID in
                    model.applyProviderPreset(ProviderCatalog.preset(id: presetID))
                }
            }

            TextField(L10n.tr("显示名称（可选）"), text: $model.apiKeyDisplayName)
                .textFieldStyle(.roundedBorder)

            TextField(L10n.tr("供应商名称"), text: $model.addAccountProviderDisplayName)
                .textFieldStyle(.roundedBorder)

            providerModelSettingsSection

            SecureField(model.addAccountAPIKeyPlaceholder, text: $model.apiKeyInput)
                .textFieldStyle(.roundedBorder)

            if model.isEditingProviderAccount {
                Text(L10n.tr("留空表示继续使用当前 API Key。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField(L10n.tr("Base URL"), text: $model.addAccountProviderBaseURL)
                .textFieldStyle(.roundedBorder)
                .disabled(model.selectedProviderPreset?.isCustom == false)

            TextField(L10n.tr("API Key 环境变量"), text: $model.addAccountProviderAPIKeyEnvName)
                .textFieldStyle(.roundedBorder)
                .disabled(model.selectedProviderPreset?.isCustom == false)

            Text(L10n.tr("保存后账号本身就是唯一权限来源。打开 CLI 时，应用会按账号配置自动决定 provider、模型和桥接方式。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .orbitSurface(.neutral, radius: OrbitRadius.hero)
    }

    private var providerModelSettingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.tr("模型与参数"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    model.addProviderModelSettingRow()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
                .help(L10n.tr("新增模型"))
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.addAccountProviderModelSettings.indices, id: \.self) { index in
                    HStack(spacing: 8) {
                        Button {
                            model.selectDefaultProviderModel(model.addAccountProviderModelSettings[index].model)
                        } label: {
                            Image(systemName: isDefaultProviderModel(at: index) ? "checkmark.circle.fill" : "circle")
                        }
                        .buttonStyle(.plain)
                        .help(L10n.tr("设为默认模型"))

                        TextField(
                            L10n.tr("模型"),
                            text: Binding(
                                get: { model.addAccountProviderModelSettings[index].model },
                                set: { model.updateProviderModelName(at: index, model: $0) }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 220)

                        TextField(
                            L10n.tr("关联多模态模型"),
                            text: Binding(
                                get: { model.addAccountProviderModelSettings[index].multimodalModel ?? "" },
                                set: { model.updateProviderModelMultimodalModel(at: index, model: $0) }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 170)
                        .help(L10n.tr("有附件时先用该模型解析，再交给主模型执行"))

                        TextField(
                            "temperature",
                            value: Binding(
                                get: { model.addAccountProviderModelSettings[index].temperature },
                                set: { model.updateProviderModelTemperature(at: index, temperature: $0) }
                            ),
                            formatter: providerParameterFormatter
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)

                        TextField(
                            "top_p",
                            value: Binding(
                                get: { model.addAccountProviderModelSettings[index].topP },
                                set: { model.updateProviderModelTopP(at: index, topP: $0) }
                            ),
                            formatter: providerParameterFormatter
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)

                        Button(role: .destructive) {
                            model.removeProviderModelSetting(at: index)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .help(L10n.tr("删除模型"))
                    }
                }
            }

            Text(L10n.tr("默认 temperature = 0.3，top_p = 0.95；关联多模态模型为空时不会启用附件预处理。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var providerParameterFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.minimum = NSNumber(value: 0)
        formatter.maximumFractionDigits = 3
        formatter.minimumFractionDigits = 0
        formatter.numberStyle = .decimal
        return formatter
    }

    private func isDefaultProviderModel(at index: Int) -> Bool {
        guard model.addAccountProviderModelSettings.indices.contains(index) else {
            return false
        }
        return model.addAccountDefaultModel == model.addAccountProviderModelSettings[index].model
    }

    private var claudeProfileSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(AddAccountMode.claudeProfile.title)
                .font(.title3.bold())

            Text(L10n.tr("导入当前 `~/.claude` 与 `~/.claude.json`，保存为可切换的本地 Claude Profile。"))
                .font(.callout)
                .foregroundStyle(.secondary)

            TextField(L10n.tr("显示名称（可选）"), text: $model.apiKeyDisplayName)
                .textFieldStyle(.roundedBorder)

            Text(L10n.tr("这只会保存本地配置快照，不代表 claude.ai 或 Console 的官方登录态。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .orbitSurface(.neutral, radius: OrbitRadius.hero)
    }

    private var copilotSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(AddAccountMode.githubCopilot.title)
                .font(.title3.bold())

            Text(L10n.tr("Orbit 会先尝试导入当前机器已有的 GitHub Copilot 登录态；如果没有可导入的授权，就会打开浏览器完成 GitHub 授权。"))
                .font(.callout)
                .foregroundStyle(.secondary)

            if model.isAuthenticating {
                progressRow(model.addAccountStatus)
            }

            if !model.isReauthorizingAccount {
                TextField(L10n.tr("显示名称（可选）"), text: $model.apiKeyDisplayName)
                    .textFieldStyle(.roundedBorder)
            }

            TextField(L10n.tr("GitHub Host"), text: $model.copilotHostInput)
                .textFieldStyle(.roundedBorder)

            Text(L10n.tr("完成接入后，Codex CLI、Codex.app 和 Claude Code 都会复用 Orbit 提供的本地 GitHub provider bridge，不再依赖 `copilot` 命令。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .orbitSurface(.neutral, radius: OrbitRadius.hero)
    }

    private var footer: some View {
        HStack {
            Button(L10n.tr("取消")) {
                model.dismissAddAccountSheet()
                dismiss()
            }
            .buttonStyle(.bordered)

            Spacer()

            if !usesInlineReauthorizationPrimaryAction {
                Button {
                    submitPrimaryAction()
                } label: {
                    HStack(spacing: 8) {
                        if model.isAddAccountActionInProgress {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(actionButtonTitle)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isAddAccountActionInProgress || !model.canAddAccountsInSheet)
            }
        }
        .padding(.horizontal, OrbitSpacing.section)
        .padding(.vertical, 18)
        .background(OrbitPalette.panel)
    }

    private var actionButtonTitle: String {
        if model.isBrowserAuthorizationPending {
            return L10n.tr("等待浏览器授权")
        }
        if model.isAuthenticating {
            return L10n.tr("正在授权...")
        }
        return model.addAccountActionButtonTitle
    }

    private var usesInlineReauthorizationPrimaryAction: Bool {
        model.isReauthorizingAccount && model.addAccountMode == .chatgptBrowser
    }

    private var reauthorizationStartPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(OrbitPalette.accent)

                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("重新连接当前账号"))
                        .font(.headline)

                    Text(L10n.tr("打开浏览器完成授权，Orbit 会自动更新本地凭据并激活该账号。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button {
                submitPrimaryAction()
            } label: {
                HStack(spacing: 10) {
                    if model.isAddAccountActionInProgress {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Text(actionButtonTitle)
                        .font(.headline)

                    Spacer(minLength: 0)

                    Image(systemName: "arrow.up.forward.app.fill")
                        .font(.callout.weight(.semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isAddAccountActionInProgress || !model.canAddAccountsInSheet)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .orbitSurface(.accent, radius: OrbitRadius.panel)
    }

    private func submitPrimaryAction() {
        Task {
            switch model.addAccountMode {
            case .chatgptBrowser:
                await model.startBrowserLogin()
            case .providerAPIKey:
                await model.startAPIKeyLogin()
            case .claudeProfile:
                await model.importClaudeProfile()
            case .githubCopilot:
                await model.startCopilotLogin()
            }
        }
    }

    private func progressRow(_ message: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .orbitSurface()
    }
}
