# Orbit

[English README](README.md)

Orbit 是一个原生 macOS 菜单栏工具，用来在一台机器上管理本地 LLM 账号工作区。本轮保留完整 Codex 能力，并露出 Claude 占位入口；它会集中管理本地账号信息，并通过原子更新 `~/.codex/auth.json` 来切换当前激活的 Codex 账号。

## 功能

- 通过菜单栏工具和独立主窗口统一管理本地 LLM 账号工作区。
- 支持在 Codex / Claude 平台视图间切换；本轮 Claude 仅展示占位入口。
- 支持通过浏览器 OAuth 添加 ChatGPT 账号。
- 支持添加 API Key 账号做本地凭据切换。
- 无需手动编辑 `~/.codex/auth.json` 就能切换当前账号。
- 查看账号详情，包括套餐类型、Codex 使用状态、可用性、额度限制、最后刷新时间和最后使用时间。
- 可以在账号详情里直接为当前选中的账号打开 Codex CLI。
- 打开 CLI 前可以先选择工作目录，右侧还会按账号保存最近打开过的目录，方便后续快速重开。
- 当前激活账号打开 CLI 时直接使用全局 `~/.codex`；其他账号会使用独立 `CODEX_HOME` 启动，不会改写当前全局 auth 文件。
- 从本地 Codex 产物中归档额度快照：`~/.codex/sessions/*.jsonl` 与 `~/.codex/state_5.sqlite`。
- 对支持的 ChatGPT 账号，通过 `/wham/usage` 刷新在线额度数据。
- 当当前账号的 5 小时额度偏低时，给出切换建议。
- 切换后检测运行中的 Codex 是否仍持有旧登录态，并在需要时提示重启 Codex。
- 将应用元数据保存在 `~/Library/Application Support/Orbit/accounts.json`，将凭据缓存保存在 `~/Library/Application Support/Orbit/credentials-cache.json`，且不会触发钥匙串授权弹窗。

## 环境要求

- macOS 14 及以上
- 如果通过终端构建，需要 Swift 6 工具链
- 本地已有使用 `~/.codex` 的 Codex 环境

## 命令

### 运行应用

```bash
swift run
```

也可以直接用 Xcode 打开 `Package.swift`，按 macOS App 方式运行。

### 运行测试

```bash
swift test
```

### 打包分发版本

```bash
./scripts/package_app.sh
```

打包脚本会在 `dist/` 下生成这些产物：

- `Orbit.app`
- `Orbit.zip`
- `assets/AppIcon.icns`
- `assets/AppIcon-master.png`
- `assets/MenuBarIcon-template.png`

## 说明

- 额度统一按“剩余百分比”展示，以便和 Codex 状态面板保持一致。
- 手动刷新会先拉取在线额度，之后如果本地会话里出现更新的事件，快照仍可能被更新的数据覆盖。
- API Key 账号支持本地切换，但不支持在线额度刷新。
- 本轮 Claude 仅接入平台框架和界面入口，不包含真实账号登录、切换、CLI 启动和额度同步。
- 项目已移除钥匙串依赖，因此切换账号或打开主窗口时不应再触发系统凭据授权提示。
