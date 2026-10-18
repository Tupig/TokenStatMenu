# TokenStatMenu 数据准确性与验收环境优化设计

日期：2026-10-18
状态：待用户审阅
关联 Issue：#19、#37、#33、#52
主规格：`spec.md` 的 R04、R07、R10、R12、R13、R14、R15、R16

## 目标

分两个可独立验收的阶段完善 TokenStatMenu：第一阶段让菜单栏、面板和诊断输出始终使用有来源、有新鲜度、有覆盖范围说明的统计口径，并减少一项无语义变化的空闲开销；第二阶段把 AX 自动化和 SwiftPM/CLT 工具链问题变成可重复、不会误报成功的验收流程。

## 不变的产品边界

- 没有企业网关提供的逐事件时间序列时，实时 token/s 保持未知或明确标记为本机活动估算；不使用刷新间隔、额度变化、历史差值或金额推导瞬时速度。
- 5 小时、7 天、月度金额、会话数、已核验小计和完整账单继续分别标注来源；缺失、过期、未来时间戳或有限扫描覆盖不能显示成已知的当前企业额度。
- 不读取 Keychain、认证数据库或会话正文；不修改 Token Hub/Codex 配置，不自动授予 TCC/Accessibility 权限，不绕过 Gatekeeper。
- 不修改 SwiftPM、SDK 或创建假目录来隐藏 CLT 上游 warning；完整 Xcode 仅作为已验证的选择工具链。
- 现有 `v1.1.5` 标签、Release、Homebrew Formula 和单一 `ci.yml` 不被回写或覆盖。

## 阶段一：数据口径、菜单显示与低风险热路径

### 现状问题

`AppModel` 已实现本地记录、Token Hub 额度和未知状态的主要边界，但菜单栏和面板中仍有两类容易误读的细节：Dashboard 的 Token Hub 卡片直接使用 `Date()`，与模型可注入时钟不同；诊断输出每 0.5 秒重新扫描 `CommandLine.arguments`。现有菜单栏速度和额度边界本身不改。

### 设计

1. 在 `AppModel` 保留当前标题格式和来源语义，补齐回归断言：
   - 有新鲜本机活动轮次时显示 `实时≈`，来源为活动 `token_count` 短窗口估算。
   - 活动轮次过期、未来或缺失时显示 `上轮均` 或 `—`，不显示旧实时值。
   - 完整核算时显示总量和顶层对话数；有未核验线程/文件时显示“小计”和未核验数量。
   - Token Hub 5 小时/7 天只有新鲜快照时进入菜单栏紧凑后缀，缺失或过期保持未知；tooltip 和面板给出完整来源、观察时间和重置语义。
2. 在 `DashboardView.tokenHubCard` 使用 `model.tokenHubNow()` 获取快照时间，避免生产视图和测试/状态模型使用不同的时钟。
3. 在 `StatusBarController` 初始化时解析一次可选 `--diagnostics-output` URL；`refreshTitle()` 只使用缓存 URL 和现有一秒节流，不改变诊断字段或写入线程。
4. 保持 0.5 秒 Timer、15 秒活动新鲜度、5 秒本地扫描间隔、额度刷新边界和权限轮询语义不变；不在本阶段合并 Timer Task，也不放宽扫描上限。

### 阶段一验收

- 新增/更新 `TokenHubQuotaStateTests` 与 Dashboard 渲染检查，覆盖新鲜/过期/未来/缺失窗口、完整与有限核算、菜单栏后缀和注入时钟一致性。
- 新增 `StatusBarController` 诊断 URL 缓存的单元/集成断言，确认诊断开关关闭时不写文件，开启时仍只写脱敏布尔值和资源计数。
- 运行核心检查、完整 `swift test`（使用完整 Xcode）、隔离集成、Xcode Release、Universal/签名检查、文档和公开内容扫描。
- 可选性能采样只记录同一版本的 CPU/RSS 原始非敏感指标；没有受控对照时不声称整 App 性能提升。

## 阶段二：AX 验收与 CLT 诊断

### Issue #33：AX 自动化

新增一个受限的设置页验收入口/说明，复用现有固定、无真实数据 fixture 和 A01–A07 断言。运行器必须把 `build-for-testing` 与 `test-without-building` 分开记录：

- runner 初始化成功时才允许报告 AX 节点/文字断言结果；
- 出现 `Timed out while enabling automation mode`、pipe 关闭或其他启动失败时，记录 `automation_environment_blocked`，保留退出码和日志位置，命令失败退出，不把阻塞转换成通过；
- 不使用 OCR、离屏 getter、源码标签、TCC 修改或降低断言替代真实 AX 树。

### Issue #52：CLT/SwiftPM

补充工具链诊断和文档：默认 CLT SwiftBuild 复现缺失搜索路径时，报告 Swift、CLT、SDK、`DEVELOPER_DIR` 和上游 Issue #10557 的公开版本信息；完整 Xcode 路径继续作为逐命令规避。诊断不得创建目录、修改 SDK、修改全局 `xcode-select` 或将 warning 静默。

### 阶段二验收

- 在当前环境运行 AX 入口并输出真实结果：若 runner 仍阻塞，Issue #33 保持 OPEN，记录为环境阻塞；只有 A01–A07 实际执行并通过才可关闭。
- 在 CLT 与完整 Xcode scratch 目录各运行一次最小 Hello 和项目命令；记录 warning/exit code，确认项目构建仍成功且没有篡改 Package.resolved。
- 更新测试指南、编译指南和 VALIDATION 记录，明确“环境诊断通过”与“产品 AX/CLT 缺陷已修复”的区别。

## 文件边界

第一阶段预计修改：`Sources/TokenStatMenu/DashboardView.swift`、`Sources/TokenStatMenu/StatusBarController.swift`、`Tests/TokenStatUITests/TokenHubQuotaStateTests.swift`、相关 Dashboard/集成测试和实现/验证文档。除非回归断言证明现有格式与来源边界矛盾，否则不修改 `AppModel.swift` 的统计语义。

第二阶段预计修改：AX 验收脚本或私有 runner 说明、`docs/wiki/测试指南.md`、`docs/wiki/编译指南.md`、`docs/VALIDATION.md`，以及不改变生产数据路径的合成/环境检查。若 runner 仍不可用，只提交诊断和证据，不修改产品 AX 语义。

两个阶段都必须更新 `script/package_source.py` 的公开白名单并重新生成 `docs/FULL_SOURCE.md`；不加入原始截图、运行日志、企业地址、凭据或个人路径。

## 完成标准

每个阶段单独建立/更新对应 Issue 评论和治理构建包，完成本机测试、独立 PE/SecOps 隐私审查、PR CI、main CI 后再报告阶段完成。#37 只有在获得权威企业时间序列并完成真实来源验收后才可关闭；#33 只有真实 AX runner 断言执行后才可关闭；#52 只有上游修复或明确新的工具链证据后才可关闭。
