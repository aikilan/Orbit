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
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
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
        if model.isEditingProviderAccount {
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
        }
    }

    private var browserSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(AddAccountMode.chatgptBrowser.title)
                .font(.title3.bold())

            if let authorizeURL = model.browserAuthorizeURL {
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
                Text(L10n.tr("点击底部按钮开始浏览器登录。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
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

            TextField(L10n.tr("默认模型"), text: $model.addAccountDefaultModel)
                .textFieldStyle(.roundedBorder)

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

    private var footer: some View {
        HStack {
            Button(L10n.tr("取消")) {
                model.dismissAddAccountSheet()
                dismiss()
            }
            .buttonStyle(.bordered)

            Spacer()

            Button(actionButtonTitle) {
                Task {
                    switch model.addAccountMode {
                    case .chatgptBrowser:
                        await model.startBrowserLogin()
                    case .providerAPIKey:
                        await model.startAPIKeyLogin()
                    case .claudeProfile:
                        await model.importClaudeProfile()
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isAuthenticating || !model.canAddAccountsInSheet)
        }
        .padding(.horizontal, OrbitSpacing.section)
        .padding(.vertical, 18)
        .background(OrbitPalette.panel)
    }

    private var actionButtonTitle: String { model.addAccountActionButtonTitle }
}
