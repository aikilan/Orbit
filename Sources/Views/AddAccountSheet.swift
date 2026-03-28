import SwiftUI

struct AddAccountSheet: View {
    @ObservedObject var model: AppViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text(L10n.tr("新增账号"))
                            .font(.largeTitle.bold())
                        Spacer()
                        Button(L10n.tr("关闭")) {
                            model.dismissAddAccountSheet()
                            dismiss()
                        }
                    }

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
                    .onAppear {
                        model.prepareAddAccountSheet()
                    }

                    Text(model.addAccountStatus)
                        .foregroundStyle(.secondary)

                    if model.addAccountMode == .chatgptBrowser, let authorizeURL = model.browserAuthorizeURL {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(L10n.tr("浏览器 OAuth"))
                                .font(.headline)
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
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }

                    if model.addAccountMode == .providerAPIKey {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(L10n.tr("API Key Provider"))
                                .font(.headline)

                            Picker(L10n.tr("规则"), selection: $model.addAccountProviderRule) {
                                Text(ProviderRule.openAICompatible.displayName).tag(ProviderRule.openAICompatible)
                                Text(ProviderRule.claudeCompatible.displayName).tag(ProviderRule.claudeCompatible)
                            }
                            .pickerStyle(.segmented)
                            .onChange(of: model.addAccountProviderRule) { _, rule in
                                let defaultPresetID = rule == .claudeCompatible ? "anthropic" : "openai"
                                model.applyProviderPreset(ProviderCatalog.preset(id: defaultPresetID))
                            }

                            Picker(L10n.tr("Provider"), selection: $model.addAccountProviderPresetID) {
                                ForEach(model.availableProviderPresets) { preset in
                                    Text(preset.displayName).tag(preset.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .onChange(of: model.addAccountProviderPresetID) { _, presetID in
                                model.applyProviderPreset(ProviderCatalog.preset(id: presetID))
                            }

                            TextField(L10n.tr("显示名称（可选）"), text: $model.apiKeyDisplayName)
                                .textFieldStyle(.roundedBorder)

                            TextField(L10n.tr("Provider 名称"), text: $model.addAccountProviderDisplayName)
                                .textFieldStyle(.roundedBorder)

                            TextField(L10n.tr("默认模型"), text: $model.addAccountDefaultModel)
                                .textFieldStyle(.roundedBorder)

                            SecureField(L10n.tr("输入 API Key"), text: $model.apiKeyInput)
                                .textFieldStyle(.roundedBorder)

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
                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }

                    if model.addAccountMode == .claudeProfile {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(L10n.tr("导入当前 Claude Profile"))
                                .font(.headline)
                            Text(L10n.tr("导入当前 `~/.claude` 与 `~/.claude.json`，保存为可切换的本地 Claude Profile。"))
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            TextField(L10n.tr("显示名称（可选）"), text: $model.apiKeyDisplayName)
                                .textFieldStyle(.roundedBorder)

                            Text(L10n.tr("这只会保存本地配置快照，不代表 claude.ai 或 Console 的官方登录态。"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }

                    if let error = model.addAccountError {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button(L10n.tr("取消")) {
                    model.dismissAddAccountSheet()
                    dismiss()
                }
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
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var actionButtonTitle: String {
        switch model.addAccountMode {
        case .chatgptBrowser:
            return L10n.tr("开始浏览器登录")
        case .providerAPIKey:
            return L10n.tr("保存并激活 Provider")
        case .claudeProfile:
            return L10n.tr("导入并激活 Claude Profile")
        }
    }
}
