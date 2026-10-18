# 实现范围与模块

[返回文档中心](wiki/Home.md)

## 正式 App 能力矩阵

这里描述当前产品入口，而不是核心库中所有历史代码的能力。正式 App 聚焦 Seasun Token Hub，不要求用户配置自定义 API、代理、密钥、模型、单价或配额。

| 能力 | 当前状态 | 说明与限制 |
| --- | --- | --- |
| 原生菜单栏、点击弹出面板、中文界面 | 已实现 | SwiftUI + AppKit，无主窗口，深浅外观使用系统颜色 |
| 原生应用图标 | 已实现 | Swift 几何绘制 PNG / `.icns`，构建时使用系统工具，无新运行时依赖 |
| 自动发现本机 Hub | 已实现 | 需要 Hub 已运行、已登录且目标唯一；不代登录 |
| 企业 5 小时、7 天额度与重置时间 | 已接通只读后台来源 | 从明确窗口字段解析金额/百分比，缺失字段保持未知 |
| 月度已用 | 已接通后台月度金额 | 不推算月度 Token、完整账单或自定义成本 |
| 本地输入、输出与总 Token 小计 | 已实现有界记录核算 | 当前配置关联，不证明历史路由；不是所有对话或本次启动量 |
| 顶层对话、子代理、分叉与未知分类 | 已实现 | 以扫描范围、身份和继承证据为限，不等于网络请求数 |
| 活动 Token 速度 | 已实现本机区间估算 | 需要连续累计事件，15 秒失效；不等于服务端权威瞬时速度 |
| 上轮均速 | 已实现 | 完整轮次输出增量/时长，包含工具、网络与等待 |
| Hub 界面兼容快照 | 可选独立来源 | 仅在已有辅助功能信任与可访问额度区域时尝试；不阻断直接读取 |
| 可选偏好 | 两项 | 刷新间隔和界面兼容读取开关 |
| 合成核心/状态/视觉检查 | 已提供 | 测试与真实本机、安装验收分开，见 [测试指南](wiki/测试指南.md) |
| 通用 API、Ollama、代理转发、价格/汇率、成本和失败延迟统计 | 正式入口不提供 | 历史核心组件不表示产品可以启用这些功能 |
| 正式 Release、自动更新、Developer ID/公证流水线 | 当前未提供自动化 | 以实际发布资产与验证记录为准 |
| 服务端瞬时 token/s | 未接通权威来源 | [Issue #37](https://github.com/Tupig/TokenStatMenu/issues/37) 持续跟踪 |

## 运行结构

```text
NSApplication（accessory，无主窗口）
  ├─ StatusBarController：NSStatusItem、NSPopover、标题与本机就绪诊断
  └─ AppModel：来源状态、偏好、时效、后台调度与失效
      ├─ TokenHubDirectQuotaClient：现有本机会话 → 内存交换 → 固定只读额度
      ├─ LocalCodexUsageReader：当前 provider 关联 → 有界记录 → 核算与速度估算
      └─ TokenHubAXReader：已有信任 → 有界界面扫描 → 独立兼容快照
DashboardView / SettingsView / Quota Cards：中文 SwiftUI 展示
```

## 源文件职责

| 文件或目录 | 职责 |
| --- | --- |
| [TokenStatMenuApp.swift](../Sources/TokenStatMenu/TokenStatMenuApp.swift) | accessory 生命周期、显式检查参数、退出清理 |
| [StatusBarController.swift](../Sources/TokenStatMenu/StatusBarController.swift) | 持有菜单栏条目、弹出面板，避免条目被释放；按变化刷新标题 |
| [AppModel.swift](../Sources/TokenStatMenu/AppModel.swift) | 允许偏好、正式来源、后台资源、generation、统一新鲜度与展示状态 |
| [DashboardView.swift](../Sources/TokenStatMenu/DashboardView.swift)、[SettingsView.swift](../Sources/TokenStatMenu/SettingsView.swift) | 概览和仅两项偏好，来源/未知/过期文案 |
| [TokenHubDirectQuota.swift](../Sources/TokenStatCore/TokenHubDirectQuota.swift) | 数据库安全只读、连接与会话验证、内存交换、响应解码 |
| [LocalCodexUsageReader.swift](../Sources/TokenStatCore/LocalCodexUsageReader.swift) | 有界文件扫描、缓存、线程核算、继承边界和活动/完整轮速度 |
| [TokenHubAXReader.swift](../Sources/TokenStatMenu/TokenHubAXReader.swift) | AppKit 辅助功能适配、信任状态和唯一目标发现 |
| [TokenHubAXScanning.swift](../Sources/TokenStatCore/TokenHubAXScanning.swift)、[TokenHubQuota.swift](../Sources/TokenStatCore/TokenHubQuota.swift) | 界面扫描预算、双读比较及独立金额模型 |
| [Storage.swift](../Sources/TokenStatMenu/Storage.swift) | 偏好路径与原子保存；保留的身份辅助函数不作 Keychain I/O |
| [RenderAppIcon.swift](../script/RenderAppIcon.swift)、[make_app_icon.sh](../script/make_app_icon.sh) | 从零绘制原创图标并生成原生尺寸资源，进入 SwiftPM App 与 Xcode 打包 |
| [Tests](../Tests) | 合成核心、原生状态与 UI 检查 |
| [script](../script) | 构建、隔离集成、离线预览、隐私检查与显式源码导出 |

## 后台读取流程

### Hub 企业额度

生产路径只读打开 Hub 自有数据库中的必要连接/SSO 会话，向既有 HTTPS 来源构造固定回调请求，拦截而不跟随重定向。回调 Location 必须匹配预期 origin 与路径；片段中的短期令牌只保存在内存，用于固定只读额度入口。回调前后及额度返回后重新比较本机来源身份，变化则拒绝结果。

401 最多重新读取会话并交换一次，不无限重试；其他错误按状态安全失败。额度响应按明确种类解析 5 小时、7 天和月度金额，不从本机 Token 计数或金额变化猜测接口数据。详细 URL 与身份边界见 [设计说明](DESIGN.md)。

### 本地记录

读取当前 Codex provider 配置并与 Hub 的既有 origin 关联，再接受匹配 provider 的记录。扫描最多枚举 5,000 项、读取 32 文件；每文件最多头 64 KiB / 尾 256 KiB，单次总读取最多 10 MiB。文件身份、读取变化和路由指纹参与缓存与失效判断。

逻辑线程去重、子代理/分叉继承和贡献核算需要明确证据；不足的单独标记未知。活动速度与完整轮均速各用独立模型，详情见 [统计口径](wiki/统计口径.md)。

### 可选界面兼容来源

已有辅助功能信任时，读取唯一额度区域，不自动操作 Hub 界面。双读规范化比较、身份校验以及节点/字符/时间预算防止混合或无限扫描。它的金额快照与本地 Token、后台直接响应保持来源区别。

## 调度、资源与性能边界

本地扫描串行、有界，完成后保留刷新间隔，不积压工作。菜单栏展示在主线程，内容或颜色未变时避免重复写入。统一新鲜度用于菜单、详情与诊断；超过 15 秒的活动事件不继续当实时。

正式本地模式不在每个空闲 tick 发布相同的旧代理 MetricsSnapshot；只有测量或时效边界变化时才通知相关界面。首次打开面板前不创建 Dashboard 的 SwiftUI hosting；创建后复用，以保留面板状态。Tooltip 在值、来源、时效或区域/时区变化后重新格式化，空闲检查复用已生成文字。0.5 秒菜单检查、15 秒活动时效与本地采集调度保持不变。

同编译器、SDK 与 `-Onone` 的 10,000 次指定合成菜单循环，三轮中位耗时从约 562.0 ms 降至 81.2 ms，减少约 85.6%。这组结果包含两次 tick 之间数据更新后的过期通知修复，只描述该热路径，不能作为整 App CPU 或内存下降幅度；可复现方法和限制见 [性能与基准](PERFORMANCE.md)。

直接读取不依赖辅助功能权限，也不受兼容开关影响。Hub 退出、重新启动、身份变化、设置重载或关闭服务会推进 generation，迟到结果不能覆盖当前实例。退出时清理自己拥有的计时器、观察者及排队任务。性能改进需要同输入、同场景的测量，不仅凭代码看起来更少就宣称 CPU 或内存下降。

## 历史核心协议的保留范围

`Configuration`、`HTTPDecoder`、`StreamParser`、`ProxyServer`、`MetricsEngine`、`RateWindow` 及通用额度解析组件仍在核心库中，供合成协议与核算回归使用。正式偏好不加载旧接入字段，不启动该代理，不调用任意旧 endpoint，也不读取旧密钥。

SSE 块数不是 Token 数；历史核心测试中的协议解析与速率窗口不能证明正式 Seasun App 已获得服务端流式吞吐。离线预览可能构造这些历史状态，须始终标记为合成材料。

## 验证和交付边界

无配置、旧配置、损坏配置、偏好优先级、非法数值、原子保存失败、Preview 惰性和后台资源隔离都有对应检查。隔离集成只管理自己的子进程；真实本机验收另行核对默认自动读取、Hub 重启恢复、窗口就绪与活动速度时效。

验证报告应区分源码/合成测试、视觉检查、真实本机、安装路径和公开发布。公开交付还要检查显式白名单、精确暂存内容、构建身份及发布产物一致性，不能仅凭历史通过关闭问题。

相关页面：[统计口径](wiki/统计口径.md) · [设计说明](DESIGN.md) · [性能与基准](PERFORMANCE.md) · [编译指南](wiki/编译指南.md) · [测试指南](wiki/测试指南.md) · [CI/CD](wiki/CI-CD.md)
