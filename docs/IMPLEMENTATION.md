# 实现范围与模块

[返回文档中心](wiki/Home.md)

## 当前一致性、额度与响应性修复

本轮把 5 小时、7 天和月度字段的来源边界固定下来。直接解码器保留月度可选总额和窗口 `resetAt`；总额缺失时只显示已用，剩余、百分比和进度保持未知。缺失或歧义的 5 小时、7 天窗口分别保持未知，不能从另一窗口、本地历史或月度字段推断。显示百分比统一使用最多两位小数，告警阈值和进度始终使用未四舍五入的 `Decimal`。

本地 JSONL 读取器在文件没有末尾换行时保留完整 JSON；截断片段仍是连续性屏障。顶层累计事件必须按物理顺序保持时间、输入、输出和总量单调，并满足 `total_tokens >= input_tokens + output_tokens`；回退、未来事件和不一致总量只让受影响线程变成未知。一个模型时钟值 `observationNow` 同时传给本地扫描、直接额度 freshness 和菜单展示。

本地路由发现、Token Hub 进程/设置/SQLite 读取和直接额度请求都在 worker actor 内进行。跨 actor 只返回 `DirectQuotaTransportSnapshot` 的脱敏额度、来源、时钟和 freshness 字段，不携带 PID、可执行路径、数据库 inode、UUID、URL、会话、bearer、原始响应或 route fingerprint。主 actor 通过 generation 和取消检查拒绝迟到结果；主线程不执行同步来源发现。

菜单面板只在打开时采集新鲜本地活动估算并维护最近十分钟、最多 1200 点的曲线；过期或未知样本不会写成零。设置/退出按钮共用中性色样式和 30×30 命中区域，活动指示点使用新鲜本地 live estimate。直接额度卡为 5 小时、7 天和月度总额提供进度条，月度 used-only 响应保持明确的未知状态。

网络策略移除了全局 `NSAllowsArbitraryLoads`。远程来源必须 HTTPS，Token Hub 继续校验同源重定向和 URL 字段；loopback/local compatibility 只由合成检查单独覆盖。远程明文 HTTP、userinfo、query/fragment、主机/端口变化和不安全 `Location` 均拒绝。当前真实企业权威 token/s 时间序列仍未接通，无法用本地估算代替该结论。

## 正式 App 能力矩阵

### 本地缓存与完整轮次明细

`LocalCodexUsageReader` 将缓存读取解析为合法值、未提供或无效三种状态。输入包含缓存读取，未缓存输入只在同一合法输入/缓存覆盖内作差；汇总使用同覆盖的总和比例。基础累计贡献与完整轮次独立验证，不能用其中一项补齐另一项缺失的证据。

reader 的数值摘要每文件最多保留最新 16 个完整轮次及裁剪标识；公开快照最多 32 个线程和 128 个轮次。明细裁剪与基础小计分开，`lastTurn` 从同一完整轮次投影中选取。公开数据只包含数值、日期、有限状态和进程内编号；内部映射随覆盖、来源与生命周期失效清理，不持久化明细。

Dashboard 默认折叠该明细区；展开只读取已经发布的快照，不启动额外扫描。Tooltip 与面板共用缓存覆盖和两位百分比口径。重新加载、停止和 shutdown 先清公开快照，再让同一 worker 串行清理内部缓存；旧 generation 不能重新发布，同代晚到的失效通知不会清掉已建立的新缓存。

该功能保留完成后至少五秒的本地扫描调度。模型调用用时、平均 TTFT、decode TPS、跨重启账本和逐 Token 实时同步仍不属于已交付的来源能力；详情见 [统计口径](wiki/统计口径.md)。

### 阶段 1 数据口径修正（2026-10-18）

Dashboard 额度有效期与 `AppModel` 使用同一时钟。可选诊断路径在 `StatusBarController` 初始化时解析一次，刷新菜单不再重复扫描启动参数，诊断输出仍独立限频。C29 回归覆盖完整扫描与达到上限时的显示：菜单栏仅保留速度和 Hub 额度，详情保留 Token 用量、线程分类和文件范围。

数据口径保持分层。5 小时、7 天和月度值仍来自 Token Hub 的只读额度来源；本机 Codex 输入/输出/总量和会话分类仍是有界扫描的小计或完整扫描量；活动 token/s 只能在有新鲜累计事件时显示本机短窗口估算。当前没有企业网关提供的权威瞬时 token/s 时间序列，因此 `liveTokenSpeedPresent` 在缺少新鲜活动证据时继续为 `false`，界面显示未知，不用刷新间隔或历史差值代替。真实 Settings AX 树验收仍属于 [Issue #33](https://github.com/Tupig/TokenStatMenu/issues/33) 的后续环境阶段；CLT linker warning 继续由 [Issue #52](https://github.com/Tupig/TokenStatMenu/issues/52) 跟踪。

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
| 本地历史额度 | 正式界面隐藏 | 仅供显式开启的离线预览与回归测试，不补齐企业额度缺失窗口 |
| 可选偏好 | 两项 | 刷新间隔和界面兼容读取开关 |
| 合成核心/状态/视觉检查 | 已提供 | 测试与真实本机、安装验收分开，见 [测试指南](wiki/测试指南.md) |
| 通用 API、Ollama、代理转发、价格/汇率、成本和失败延迟统计 | 正式入口不提供 | 历史核心组件不表示产品可以启用这些功能 |
| 正式 Release 流水线 | 已提供标签触发流程 | 1.1.4 历史为四资产；1.1.5/build7 已按 App ZIP、源码 ZIP、Universal DMG、manifest、SUMS 五资产正式发布 |
| Homebrew 源码安装与 tap 跟进 | 独立源码配方与更新流程 | 完整 Xcode 本机构建；先测试后更新 Formula，用户手动 brew upgrade；正式 pin 取自真实 Release |
| App 内自动更新、Developer ID / Apple 公证 | 未提供 | ad hoc 签名和摘要不能代替 Apple 信任验证 |
| 服务端瞬时 token/s | 未接通权威来源 | [Issue #37](https://github.com/Tupig/TokenStatMenu/issues/37) 持续跟踪 |

## 运行结构

```text
NSApplication（accessory，无主窗口）
  ├─ StatusBarController：NSStatusItem、NSPopover、标题与本机就绪诊断
  └─ AppModel：来源状态、偏好、时效、后台调度与失效
      ├─ TokenHubDirectQuotaClient：现有本机会话 → 内存交换 → 固定只读额度
      ├─ LocalCodexScanWorker actor：独占缓存 → LocalCodexUsageReader 有界核算
      └─ NativeTokenHubAXWorker actor：独占 TokenHubAXReader → 有界兼容快照
DashboardView / SettingsView / Quota Cards：中文 SwiftUI 展示
```

## 源文件职责

| 文件或目录 | 职责 |
| --- | --- |
| [TokenStatMenuApp.swift](../Sources/TokenStatMenu/TokenStatMenuApp.swift) | accessory 生命周期、显式检查参数、退出清理 |
| [StatusBarController.swift](../Sources/TokenStatMenu/StatusBarController.swift) | 持有菜单栏条目、弹出面板，避免条目被释放；按变化刷新标题 |
| [AppModel.swift](../Sources/TokenStatMenu/AppModel.swift) | 允许偏好、正式来源、后台资源、generation、统一新鲜度与展示状态；本地扫描 actor 与异步值边界 |
| [DashboardView.swift](../Sources/TokenStatMenu/DashboardView.swift)、[SettingsView.swift](../Sources/TokenStatMenu/SettingsView.swift) | 概览和仅两项偏好，来源/未知/过期文案 |
| [TokenHubDirectQuota.swift](../Sources/TokenStatCore/TokenHubDirectQuota.swift) | 数据库安全只读、连接与会话验证、内存交换、响应解码 |
| [LocalCodexUsageReader.swift](../Sources/TokenStatCore/LocalCodexUsageReader.swift) | 有界文件扫描、缓存、线程核算、继承边界和活动/完整轮速度 |
| [TokenHubAXReader.swift](../Sources/TokenStatMenu/TokenHubAXReader.swift) | 辅助功能适配、唯一目标发现；native actor 私有持有 reader，值请求和不可变来源保留原生/合成身份 |
| [TokenHubAXScanning.swift](../Sources/TokenStatCore/TokenHubAXScanning.swift)、[TokenHubQuota.swift](../Sources/TokenStatCore/TokenHubQuota.swift) | 界面扫描预算、双读比较及独立金额模型 |
| [Storage.swift](../Sources/TokenStatMenu/Storage.swift) | 偏好路径与原子保存；保留的身份辅助函数不作 Keychain I/O |
| [RenderAppIcon.swift](../script/RenderAppIcon.swift)、[make_app_icon.sh](../script/make_app_icon.sh) | 从零绘制原创图标并生成原生尺寸资源，进入 SwiftPM App 与 Xcode 打包 |
| [Tests](../Tests) | 合成核心、原生状态与 UI 检查 |
| [script](../script) | 构建、隔离集成、离线预览、隐私检查与显式源码导出 |
| [release_assets.py](../script/release_assets.py)、[CI 与发布工作流](../.github/workflows/ci.yml) | 当前四资产历史与下一版五资产 DMG 契约、原生包装、远端一致性检查及分离权限的发布 |

SwiftPM 构建与测试使用经审阅的精确依赖锁和 `--force-resolved-versions`。锁同时保留 custom-dump 1.7.3 的工具链兼容图需要的 issue-reporting 2.1.2 与 overlay 1.13.1；SnapshotTesting 1.19.6 精确依赖和 App 仅依赖系统框架的边界不变。必要 pin 缺失或约束冲突应失败，不静默更新或事后恢复锁。1.1.3 的正式 Release 因真实 CI 锁漂移被干净源码检查拒绝，修正候选版本为 1.1.4/build6；本机实验、最终 CI、Release 和安装仍分别验收，见 [编译指南](wiki/编译指南.md#固定测试依赖与跨工具链锁) 与 [验证记录](VALIDATION.md)。

BP32 的 DMG 仍是同一 App 的分发包装：`release_assets.py` 只在 1.1.5 及更新版本生成 `TokenStatMenu-<版本>-universal.dmg`，创建前后复用 Universal App 的版本、来源、四文件树、双架构和严格签名检查；挂载验证只读且拥有自己的临时 mountpoint，完成后 detach/清理。Homebrew 继续从已验证的源码 ZIP 构建，不从 DMG 提取或安装；当前 1.1.4 四资产/Formula 事实保持不变，1.1.5 公开 tap 端点待真实 Release 后验收。

Dashboard 的实际 `overviewContent` 同时用于生产面板和渲染测试。正式面板为 320×420 点，字号不缩小，顶部与底栏固定，中间内容滚动。保留企业额度、本地 Token/线程/速度和可展开的缓存明细；不显示本地历史额度入口。历史额度仅供显式开启的离线预览与回归测试，不改变模型数据、企业额度、告警或读取流程。

## 后台读取流程

### Hub 企业额度

生产路径只读打开 Hub 自有数据库中的必要连接/SSO 会话，向既有 HTTPS 来源构造固定回调请求，拦截而不跟随重定向。回调 Location 必须匹配预期 origin 与路径；片段中的短期令牌只保存在内存，用于固定只读额度入口。回调前后及额度返回后重新比较本机来源身份，变化则拒绝结果。

401 最多重新读取会话并交换一次，不无限重试；其他错误按状态安全失败。额度响应按明确种类解析 5 小时、7 天和月度金额，不从本机 Token 计数或金额变化猜测接口数据。详细 URL 与身份边界见 [设计说明](DESIGN.md)。

金额字符串必须完整符合 ASCII JSON number 语法，允许小数与指数；不能只解析开头的数字。转换前将表示长度限制在 128 个 UTF-8 字节，并将去除前后零后的尾数有效数字保守限制为 38 位，避免 `Decimal(string:)` 静默截取前缀或丢失低位。随后仍要求有限、非负且不大于 `10^18`；必要的滚动窗口额度字段不能为 null，月度可选上限缺失不补造数值。

这不是任意精度 JSON 解析：原生 JSON number 先经 Foundation `JSONSerialization` 成为 `NSNumber`，其原始数字写法可能已被规范化；后续校验不能还原或保证保留原始 JSON 的任意精度。对字符串可校验完整原文，最终仍受 Decimal 表示和窗口比例运算范围限制。

### 本地记录

读取当前 Codex provider 配置并与 Hub 的既有 origin 关联，再接受匹配 provider 的记录。扫描最多枚举 5,000 项、读取 32 文件；每文件最多头 64 KiB / 尾 256 KiB，单次总读取最多 10 MiB。文件身份、读取变化和路由指纹参与缓存与失效判断。

逻辑线程去重、子代理/分叉继承和贡献核算需要明确证据；不足的单独标记未知。活动速度与完整轮均速各用独立模型，详情见 [统计口径](wiki/统计口径.md)。

`LocalCodexScanWorker` 在自己的 actor 中创建、私有持有并按 generation 重建可变缓存。一次扫描期间没有挂起点，缓存不会跨执行器共享；仅数字快照和诊断值返回主 actor。主 actor 解析允许的输入，异步等待结果，再比较 generation 决定是否发布；重载期间的旧结果不能覆盖新状态。

### 可选界面兼容来源

已有辅助功能信任时，读取唯一额度区域，不自动操作 Hub 界面。双读规范化比较、身份校验以及节点/字符/时间预算防止混合或无限扫描。它的金额快照与本地 Token、后台直接响应保持来源区别。

`NativeTokenHubAXWorker` 私有创建并持有真实 reader，完整同步扫描在该 actor 内完成，不在持有 AX 对象期间挂起。跨边界的 `TokenHubAXRequest` 只含时间、信任状态、刷新间隔、模式和 generation；AX 引用、进程对象与可变遍历表不离开 worker。不可变 `TokenHubAXSource` 通过初始化注入，原生来源的主 actor 闭包只等待 worker；内部 native/synthetic 标记保留测试 fixture 对真实界面读取的抑制。没有用 `@unchecked Sendable` 放行可变 reader 或缓存。

## 调度、资源与性能边界

两种扫描各自串行、有界；本地扫描完成后至少间隔 5 秒，可选 AX 扫描完成后按配置间隔调度，不积压同来源读取。双 actor 改造保护可变对象的归属，不减少扫描预算或延长数据有效期。菜单栏展示在主线程，内容或颜色未变时避免重复写入。统一新鲜度用于菜单、详情与诊断；超过 15 秒的活动事件不继续当实时。

正式本地模式不在每个空闲 tick 发布相同的旧代理 MetricsSnapshot；只有测量或时效边界变化时才通知相关界面。首次打开面板前不创建 Dashboard 的 SwiftUI hosting；创建后复用，以保留面板状态。Tooltip 在值、来源、时效或区域/时区变化后重新格式化，空闲检查复用已生成文字。0.5 秒菜单检查、15 秒活动时效与本地采集调度保持不变。

1.1.1 的历史样本使用同编译器、SDK 与 `-Onone` 的 10,000 次指定合成菜单循环，三轮中位耗时从约 562.0 ms 降至 81.2 ms，减少约 85.6%。这组结果包含两次 tick 之间数据更新后的过期通知修复，只描述该次热路径，不能作为 1.1.2 双 actor 或 1.1.3 展示/发布改造的整 App CPU、内存下降幅度；可复现方法和限制见 [性能与基准](PERFORMANCE.md)。

直接读取不依赖辅助功能权限，也不受兼容开关影响。Hub 退出、重新启动、身份变化、设置重载或关闭服务会推进 generation，迟到结果不能覆盖当前实例。退出时清理自己拥有的计时器、观察者及排队任务。性能改进需要同输入、同场景的测量，不仅凭代码看起来更少就宣称 CPU 或内存下降。

## 历史核心协议的保留范围

`Configuration`、`HTTPDecoder`、`StreamParser`、`ProxyServer`、`MetricsEngine`、`RateWindow` 及通用额度解析组件仍在核心库中，供合成协议与核算回归使用。正式偏好不加载旧接入字段，不启动该代理，不调用任意旧 endpoint，也不读取旧密钥。

SSE 块数不是 Token 数；历史核心测试中的协议解析与速率窗口不能证明正式 Seasun App 已获得服务端流式吞吐。离线预览可能构造这些历史状态，须始终标记为合成材料。

## 验证和交付边界

无配置、旧配置、损坏配置、偏好优先级、非法数值、原子保存失败、Preview 惰性和后台资源隔离都有对应检查。隔离集成只管理自己的子进程；真实本机验收另行核对默认自动读取、Hub 重启恢复、窗口就绪与活动速度时效。

异步 Hub 合成渲染测试用可取消的 `Task.sleep` 让出主 actor，恢复后再次 display/layout，再生成真实 hosting 位图并核对 PNG 和尺寸。窗口通过 `defer` 关闭，取消或断言失败也会清理。它替换的是异步测试中的 RunLoop 等待，不声称移除了所有同步预览中的 RunLoop，也不能代替实际原生辅助功能树验收。

1.1.3 的历史展示检查渲染同一实际概览的浅/深、初始折叠/展开四张完整合成图，并比较模型和注入 I/O 守恒；图像由独立审查核对。它不执行原生 disclosure 点击。私有 Settings XCUITest 已能构建，但 runner 在启用自动化时超时，A01–A07 未执行；[Issue #33](https://github.com/Tupig/TokenStatMenu/issues/33) 仍未完成，不能从这些渲染推断 AX 成功或失败。

发布源 ZIP 使用显式白名单，Release manifest/SUMS 与实际资产互相核对。Homebrew 从该源码包构建后使用 `release-source` 和已校验的标签提交，不借用 tap 的 Git revision；严格签名在最终安装前缀复验。主仓库、tap 的流水线源码验证、正式 Actions 执行、公开资产下载和本机安装是不同验收阶段，最新事实见 [验证记录](VALIDATION.md)。

验证报告应区分源码/合成测试、视觉检查、真实本机、安装路径和公开发布。公开交付还要检查显式白名单、精确暂存内容、构建身份及发布产物一致性，不能仅凭历史通过关闭问题。

相关页面：[统计口径](wiki/统计口径.md) · [设计说明](DESIGN.md) · [性能与基准](PERFORMANCE.md) · [编译指南](wiki/编译指南.md) · [测试指南](wiki/测试指南.md) · [CI/CD](wiki/CI-CD.md)
