## ADDED Requirements

### Requirement: Primary Workspace Hierarchy
Orbit 主窗口必须把当前账号的 CLI 打开动作呈现为首屏唯一主操作。

#### Scenario: Selected account shows one dominant action
- Given 用户在主窗口选中任一账号
- When 详情区完成刷新
- Then 首屏必须出现且只出现一个绝对主按钮，用于打开当前账号的 CLI
- And 目标选择、最近目录、手动更新、切换账号等内容必须从属于该主按钮

#### Scenario: Minimum window keeps focus intact
- Given 主窗口尺寸为 `960x620`
- When 当前账号详情被展示
- Then 账号轨道、主按钮、最近目录首项和 inspector 起始内容必须同时可见
- And 主要操作不得折叠、换到二级菜单或与其他动作产生同级竞争

### Requirement: Inspector Hierarchy
主窗口必须把账号详情、额度、状态和路径作为次级检视信息呈现，并与危险操作分层。

#### Scenario: Secondary information remains accessible
- Given 用户查看任一已保存账号
- When 检视区完成刷新
- Then 账号详情、额度或限额、状态和路径信息必须继续可达
- And 这些信息必须按稳定顺序分段呈现

#### Scenario: Destructive action is isolated
- Given 用户查看账号检视区
- When 删除账号操作可用
- Then 删除账号必须位于检视区底部的独立危险区
- And 不得与常规状态或主操作共享同一视觉优先级

### Requirement: Guided Add Account Flow
新增账号窗口必须作为单任务引导面板工作，而不是同时展示多种流程的状态表单。

#### Scenario: Only current mode fields are shown
- Given 用户打开新增账号窗口
- When 用户选择任一接入方式
- Then 中部只应显示该模式当前所需字段与说明
- And 其他模式的字段不得继续占位或干扰扫描

#### Scenario: Primary action stays stable
- Given 用户在新增账号窗口切换模式或滚动内容
- When 窗口刷新
- Then 取消与主操作必须保持在底部固定操作区
- And 用户必须始终能明确当前下一步动作

#### Scenario: All three modes remain operable in one window
- Given 窗口最小尺寸为 `620x520`
- When 用户分别执行 ChatGPT 浏览器登录、API Key Provider 和 Claude Profile 流程
- Then 三种模式都必须在同一窗口中稳定完成
- And 中英文切换后字段、按钮和说明不得相互遮挡

### Requirement: Restrained Visual System
Orbit 主界面与新增账号窗口必须遵守克制的产品 UI 视觉系统。

#### Scenario: Single accent and minimal chrome
- Given 用户浏览主窗口或新增账号窗口
- When 首屏被渲染
- Then 界面必须使用单一强调色表达主操作、选中态和关键链接
- And 不得依赖装饰性渐变、厚重边框或同级卡片马赛克来建立层级

#### Scenario: Copy stays utility-first
- Given 用户扫描标题、按钮和说明文案
- When 界面完成刷新
- Then 文案必须以操作、状态和方向提示为主
- And 不得出现营销式 slogan、重复解释或与当前步骤无关的长说明
