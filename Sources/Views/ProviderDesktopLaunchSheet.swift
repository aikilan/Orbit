import SwiftUI

struct ProviderDesktopLaunchSheet: View {
    @ObservedObject var model: AppViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: OrbitSpacing.section) {
                    formSection

                    if let error = model.desktopLaunchError {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

                Text(L10n.tr("预设启动 Codex"))
                    .font(.system(size: 28, weight: .bold, design: .rounded))

                Text(model.desktopLaunchStatus)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Button(L10n.tr("关闭")) {
                model.dismissProviderDesktopLaunch()
                dismiss()
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, OrbitSpacing.section)
        .padding(.top, OrbitSpacing.section)
        .padding(.bottom, OrbitSpacing.regular)
    }

    private var formSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.tr("OpenAI 兼容预设"))
                .font(.title3.bold())

            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.tr("供应商"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Picker(L10n.tr("供应商"), selection: $model.desktopLaunchPresetID) {
                    ForEach(model.availableDesktopLaunchPresets) { preset in
                        Text(preset.displayName).tag(preset.id)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: model.desktopLaunchPresetID) { _, presetID in
                    model.applyDesktopLaunchPreset(ProviderCatalog.preset(id: presetID))
                }
            }

            TextField(L10n.tr("显示名称（可选）"), text: $model.desktopLaunchDisplayName)
                .textFieldStyle(.roundedBorder)

            TextField(L10n.tr("默认模型"), text: $model.desktopLaunchDefaultModel)
                .textFieldStyle(.roundedBorder)

            SecureField(L10n.tr("输入 API Key"), text: $model.desktopLaunchAPIKeyInput)
                .textFieldStyle(.roundedBorder)

            Text(L10n.tr("保存后会复用本地账号记录，并直接打开独立 Codex 首页；不会改写当前 ~/.codex/auth.json。"))
                .font(.caption)
                .foregroundStyle(.secondary)

            if let preset = model.selectedDesktopLaunchPreset, !preset.supportsResponsesAPI {
                Text(L10n.tr("当前预设会通过本地桥接把 OpenAI Responses API 转成 chat/completions 后再启动。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .orbitSurface(.neutral, radius: OrbitRadius.hero)
    }

    private var footer: some View {
        HStack {
            Button(L10n.tr("取消")) {
                model.dismissProviderDesktopLaunch()
                dismiss()
            }
            .buttonStyle(.bordered)

            Spacer()

            Button(model.isLaunchingDesktopLaunch ? L10n.tr("正在启动...") : L10n.tr("保存并启动 Codex")) {
                Task {
                    let didLaunch = await model.startProviderDesktopLaunch()
                    if didLaunch {
                        dismiss()
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isLaunchingDesktopLaunch)
        }
        .padding(OrbitSpacing.section)
    }
}
