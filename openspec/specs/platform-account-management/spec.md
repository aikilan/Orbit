# Platform Account Management

## Requirements

### Requirement: Platform Selection
应用必须提供平台选择能力，并同时暴露 `Codex` 与 `Claude` 两个平台入口。

#### Scenario: Default platform remains Codex
- Given 应用首次打开或现有本地数据没有平台信息
- When 主界面完成初始化
- Then 当前平台必须默认为 `Codex`

#### Scenario: Switching to Claude shows placeholder state
- Given 用户将当前平台切换为 `Claude`
- When 主界面刷新侧栏与详情区
- Then 账号列表必须只显示 `Claude` 平台账号
- And 当没有 `Claude` 账号时，详情区必须显示占位说明
- And 当前平台上的不可用操作必须显示为禁用态

### Requirement: Codex Behavior Preservation
现有 Codex 账号管理能力必须保持可用，包括账号切换、CLI 启动、独立实例和额度状态刷新。

#### Scenario: Codex account actions remain available
- Given 当前平台为 `Codex`
- When 用户操作现有账号
- Then 应用必须继续使用原有 Codex 凭据、路径和运行态逻辑

### Requirement: Claude Placeholder Runtime
Claude 在本轮必须只作为占位平台出现，不得执行真实凭据写入、进程启动或额度同步。

#### Scenario: Claude runtime blocks real actions
- Given 当前平台或账号属于 `Claude`
- When 用户触发新增账号、切换、CLI 启动或状态刷新
- Then 应用必须阻止真实动作
- And 应用必须展示“即将支持”的说明

### Requirement: Legacy Data Migration
旧版本地数据库与应用支持目录必须在升级后继续可用。

#### Scenario: Legacy accounts default to Codex
- Given 本地数据库中的账号记录没有 `platform` 字段
- When 应用读取旧数据库
- Then 账号平台必须自动补为 `Codex`
- And 数据库版本必须提升到当前版本

#### Scenario: Preferred legacy app support directory migrates once
- Given 旧目录 `~/Library/Application Support/LLMAccountSwitcher` 存在且新目录不存在
- When 应用初始化路径
- Then 旧目录必须整体迁移到 `~/Library/Application Support/Orbit`

#### Scenario: Older legacy app support directory is used as fallback
- Given `~/Library/Application Support/LLMAccountSwitcher` 不存在
- And `~/Library/Application Support/CodexAccountSwitcher` 存在
- And `~/Library/Application Support/Orbit` 不存在
- When 应用初始化路径
- Then `~/Library/Application Support/CodexAccountSwitcher` 必须整体迁移到 `~/Library/Application Support/Orbit`

#### Scenario: Existing new directory wins
- Given `~/Library/Application Support/Orbit` 已存在
- When 应用初始化路径
- Then 应用必须使用新目录
- And 不得自动合并或覆盖旧目录

#### Scenario: LLM legacy directory wins when both legacy directories exist
- Given `~/Library/Application Support/LLMAccountSwitcher` 与 `~/Library/Application Support/CodexAccountSwitcher` 同时存在
- And `~/Library/Application Support/Orbit` 不存在
- When 应用初始化路径
- Then 应用必须优先迁移 `~/Library/Application Support/LLMAccountSwitcher`
- And 不得自动合并或覆盖 `~/Library/Application Support/CodexAccountSwitcher`

### Requirement: Product Naming
产品展示名称必须统一为 `Orbit`。

#### Scenario: User-facing surfaces show the new name
- Given 用户查看窗口标题、状态栏 tooltip、打包产物或 README
- When 相关界面或文档被加载
- Then 应显示 `Orbit`
