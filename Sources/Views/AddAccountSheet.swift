import SwiftUI

struct AddAccountSheet: View {
    @ObservedObject var model: AppViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
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

            Picker(L10n.tr("登录方式"), selection: $model.addAccountMode) {
                ForEach(AddAccountMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(model.addAccountStatus)
                .foregroundStyle(.secondary)

            if model.addAccountMode == .browser, let authorizeURL = model.browserAuthorizeURL {
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

            if model.addAccountMode == .apiKey {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.tr("API Key 接入"))
                        .font(.headline)
                    Text(L10n.tr("将 API Key 写入 `~/.codex/auth.json` 并缓存到本地账号库，后续可以像其它账号一样切换。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField(L10n.tr("显示名称（可选）"), text: $model.apiKeyDisplayName)
                        .textFieldStyle(.roundedBorder)

                    SecureField(L10n.tr("输入 OPENAI_API_KEY"), text: $model.apiKeyInput)
                        .textFieldStyle(.roundedBorder)

                    Text(L10n.tr("会按官方 CLI 当前写法生成 `auth.json`：仅包含 `OPENAI_API_KEY`。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }

            if let error = model.addAccountError {
                Text(error)
                    .foregroundStyle(.red)
            }

            Spacer()

            HStack {
                Button(L10n.tr("取消")) {
                    model.dismissAddAccountSheet()
                    dismiss()
                }
                Spacer()
                Button(model.addAccountMode == .browser ? L10n.tr("开始浏览器登录") : L10n.tr("保存并激活 API Key")) {
                    Task {
                        switch model.addAccountMode {
                        case .browser:
                            await model.startBrowserLogin()
                        case .apiKey:
                            await model.startAPIKeyLogin()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isAuthenticating)
            }
        }
        .padding(24)
    }
}
