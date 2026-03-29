# Tasks

## 1. 安装并吸收 frontend-skill 约束

- [x] 使用 `skill-installer` 安装 `frontend-skill`
- [x] 读取 `frontend-skill` 的 app UI 约束，并转译为适合 macOS 工具界面的规则

## 2. 完成 OpenSpec 文档

- [x] 创建 `proposal.md`
- [x] 创建 `design.md`
- [x] 创建 `tasks.md`
- [x] 创建 `specs/platform-account-management/spec.md`

## 3. 重做主窗口

- [ ] 以 `账号轨道 / 主工作区 / 检视区` 重排 `ContentView`
- [ ] 让 `打开 CLI` 成为唯一首屏主操作，压低次级动作权重
- [ ] 去掉详情区的同级卡片堆叠，改成连续 inspector
- [ ] 将最近目录从卡片画廊改为轻量列表行
- [ ] 在不改行为的前提下补最小 UI tokens 与局部 surface style
- [ ] 在 `960x620` 与常规桌面宽度下人工验证主窗口层级和可达性

## 4. 重做新增账号窗口

- [ ] 将 `AddAccountSheet` 改为单任务引导布局
- [ ] 固定底部主操作条，确保模式切换只替换当前表单内容
- [ ] 收短辅助文案，只保留当前步骤必须的信息
- [ ] 验证三种模式在 `620x520` 起始窗口内都可稳定完成
- [ ] 验证中英文切换、键盘 Tab 顺序以及 `hover` / `disabled` / `selected` 三态清晰度
- [ ] 仅在引入新的 UI 状态编排时补最少量测试并运行 `swift test`
