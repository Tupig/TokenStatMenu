# 验证记录

## BP19 — 自动恢复、数值边界与固定安装验收（2026-10-18）

本节记录本轮最终源码与本机候选安装产物的实际验证。BP17/BP18 的诊断来自当时启动的开发产物，只证明那些进程的就绪状态，不能代替固定路径安装或退出、重新启动后的生命周期验收。当前 provider 配置与 Hub origin 匹配也不证明相同 provider 名称的全部历史记录经过同一网关。

- 最终核心检查：416/416 通过；原生 XCTest：44/44 通过。
- 隔离启动：无配置、旧代理配置、无效旧 endpoint、损坏 plist、非字典根节点五种场景全部通过；后台服务关闭、未请求权限，启动前后配置字节保持一致。build-only 隔离检查通过，包含普通源码导出及嵌在无关父 Git 仓库下的导出，确认不调用全局进程名终止、保留版本信息且不继承父仓库 HEAD。
- 原生构建：Xcode arm64 Release 通过；Universal Release 同时包含 arm64 与 x86_64；`codesign --verify --deep --strict` 通过。产物使用本机 ad hoc 签名，未进行 Developer ID 签名或公证。Intel 仅完成构建，没有 Intel 硬件验收。
- 固定安装：候选已安装到 `~/Applications/TokenStatMenu.app`，独立比较构建候选与安装副本的完整文件 manifest，结果相等。默认启动通过 `NSWorkspace` 辅助程序启动并核验目标应用归属，避免把另一份开发产物或同名进程误当成安装验收；该辅助程序本次 `--test-only` 运行退出码为 0，`exactInstalledProcess=true`。
- 该安装副本本次真实默认启动的脱敏布尔结果为：`directQuotaPresent=true`、`fiveHourPresent=true`、`sevenDayPresent=true`、`fiveHourResetPresent=true`、`sevenDayResetPresent=true`、`monthlyUsagePresent=true`、`statusItemVisible=true`、`defaultReadinessPassed=true`、`permissionPromptRequested=false`。
- 同次诊断的 `liveTokenSpeedPresent=false`：当时没有新鲜的双计数活动事件，不能声称本次实机已验证实时 token/s。服务端权威吞吐仍由 [Issue #37](https://github.com/Tupig/TokenStatMenu/issues/37) 跟踪，保持未完成；本地估算与上轮均速保留各自标识，缺少依据时显示未知。

本轮合成回归覆盖以下边界：

- 无 AX 权限时自动直接读取；Hub 退出、重启、身份变化和迟到结果丢弃；关闭 AX 兼容或撤销权限后，直接来源继续恢复与调度。这里的 Hub 重启和权限变更是注入的生命周期回归，不替代额外的真实 Hub 重启验收。
- 当前 provider/origin 匹配筛选、累计计数基线、缺口、乱序和重叠轮次；暖缓存及扫描时钟变化；活动估算超过 15 秒、未来时间、非有限或负速率失效。菜单栏、详情和诊断共用新鲜度判断。
- 回调 Location 的精确 HTTPS 同源、固定路径及默认端口；拒绝 userinfo、query、重复令牌或 redirect，片段只解码一次，不跟随重定向。AI Manager/SSO sibling 来源关联仍是有限域后缀兼容规则，不是完整 PSL 或任意组织归属证明。
- 200 正常响应、401 最多一次重试、会话字段变化，以及字段相同但 dev/inode 改变的原子数据库替换。首次回调、额度 200、额度 401、重试回调四个替换阶段均拒绝发布快照，并在需要时阻止下一次外部请求。上述测试只使用合成 SQLite、会话值和响应，不读取真实 Hub 数据库。
- 关闭 AX 兼容时仍显示直接来源的失败状态，AX-only preview 保留关闭状态；空重置文本明确显示未知。浅色和深色 Dashboard header 的两张合成候选经独立视觉审查后更新基线，再以普通模式通过；Settings 基线保持原样。这两张 header 快照不代表完整面板或系统交互验收。

公开内容工作树扫描检查了 61 个白名单文件；源码历史中的 201 个历史 blob 及最终候选二进制使用常见 token、key 和个人 home 路径模式检查，均未发现命中。扫描与构建身份信息没有包含实际账号、企业地址、额度、会话或个人绝对路径。这类模式检查不能保证发现任意敏感信息或 PII，仍需审查实际发布差异；本节不把扫描无命中等同于全面隐私证明。

本节对应当前已验证的候选。后续干净提交会改变公开 source revision，需重新写入 bundle 并再次验证安装产物；本记录不预称该后续步骤已经执行。

## BP18 — Seasun 路由归属与活动速度回归（2026-10-18）

- 核心检查：358/358 通过。新增合成 rollout 覆盖当前 `model_provider` 与 Token Hub connection origin 匹配/不匹配两种情况；未验证路由的文件保持未知，不会混入 Token 总量。
- 活动速度回归覆盖未完成 `task_started` 轮次的两条累计 `token_count` 差分，以及超过 15 秒没有新事件时回到未知。实现只保留输入/输出速率与观测时间，不保留正文、URL 或会话标识。
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`：31/31 通过；`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./script/test.sh`：通过，包含隔离 no-config 启动场景和公开文件检查。
- 当前本机实际启动当前构建并使用不存在的临时配置文件时，脱敏诊断为 `directQuotaPresent=true`、`monthlyUsagePresent=true`、`resetTimePresent=true`、`permissionPromptRequested=false`、`liveTokenSpeedPresent=true`；临时配置文件保持不存在。
- 本轮未把实时估算称作网关权威速度；没有新鲜本地事件时菜单栏回退为上轮均速或未知。

## BP17 — 零配置实机自动读取（2026-10-18）

- 在本机已运行的 Seasun Token Hub 环境中，使用一个不存在的临时配置文件路径启动当前构建；应用没有创建该配置文件，也没有请求辅助功能授权。
- 菜单栏 App 的脱敏布尔诊断在等待后台刷新后为：`seasunOnlyMode=true`、`backgroundServicesStarted=true`、`permissionPromptRequested=false`、`directQuotaPresent=true`、`monthlyUsagePresent=true`、`resetTimePresent=true`、`liveTokenSpeedPresent=false`。
- 本次只读取诊断布尔值和状态文本，没有输出或保存真实额度、账号、网关 URL、会话值、令牌或会话正文；测试结束后只终止本次启动的 TokenStatMenu 进程。
- 该历史证据仅证明当时开发产物的零配置自动读取路径已连通，不能证明固定安装副本或重启恢复；本轮固定安装证据见 BP19。不同 Token Hub 版本、未登录状态、过期会话或企业网络策略仍可能安全地显示未知/不可用。

## BP16 — 直接额度来源实机核验（2026-10-18）

- 只读静态检查确认 Token Hub 的回调参数、短期令牌边界、额度路径和 401 单次重试规则；源码不包含本机域名、账号、会话值或额度值。
- CoreChecks：347/347 通过；Xcode `swift test`：31/31 通过；TokenStatMenu debug 构建通过。
- 在本机已登录且正在运行的 Token Hub 上，默认启动 TokenStatMenu 后只记录布尔诊断：`directQuotaPresent=true`、`monthlyUsagePresent=true`、`resetTimePresent=true`、`permissionPromptRequested=false`、`sourceStatus=unknown`（历史字段）。实际额度、令牌、账号和 URL 未写入诊断或仓库。
- 直接客户端从 Token Hub 数据库只读读取连接与 SSO 会话，内存完成回调交换，拦截重定向，再读取三类窗口；请求前后重读设置，身份变化时丢弃结果。无 Accessibility 授权也能完成该来源；界面兼容读取仍是可选回退。
- 真实瞬时 token/s 未宣称完成；菜单栏继续显示有完整轮次证据的均速或未知。

上述实机证据只证明当前本机环境的来源与字段一致性，不代表所有账号、Token Hub 版本、网络策略或企业组织都相同。

## Seasun 专用启动修正

本轮完成独立契约、实际检查充分性及实现审查。正式启动只读取两项可选偏好；旧代理配置不再激活监听、密钥读取或任意企业请求。默认/旧配置/损坏配置、原子保存、失败保留、preview 惰性、后台资源隔离与正式菜单详情均有合成检查。

- 核心检查：330/330 通过。最后一处仅恢复设置页的属性包装器别名，核心代码未改变。
- 原生 XCTest：最终源代码 31/31 通过，其中专用启动检查 11 项，原有界面与兼容状态回归 20 项。正式启动的合成小计、完整值、未知项、分类、上轮均速与直接来源未知可以同时展示。
- 界面：独立核对完整设置页的浅色/深色真实 NSHostingView 渲染。四张合成工具栏基线因已批准的来源文案更新，经过独立视觉接受后录制；随后普通非录制模式全量测试通过。故意像素差异检查继续有效。
- 可见内容：真实合成 bitmap 经过系统 Vision 检查来源、刷新与兼容选项，并排除通用 API 设置。原 SwiftUI 虚拟可访问性树未取得可见文字，OCR 不构成辅助功能行为通过的证据，该项仍单独跟踪。
- 隔离集成：五种临时配置场景通过；后台服务关闭、配置字节未被启动改写。脚本只终止自身创建的子进程，另以无信号 stub 检查 build-only 不调用全局进程名终止。
- Xcode Release：最终代码构建通过。
- Universal Release：最终产物同时包含 Apple Silicon arm64 与 Intel x86_64，严格签名检查通过。设置页使用已有 ValueState 别名规避 SDK 同名宏冲突；未跳过最初失败的双架构验收。

本轮保留一次验证偏差：曾误用会在编译后运行 App 的 Release 脚本选项，短暂启动非隔离的开发产物。已按精确可执行路径关闭该实例，原有安装实例保留。该实例可能执行了正常的本地或界面后台读取；没有采集或发布实际数值，但不能声称整个验证过程完全没有真实读取。后续 Release 编译使用不启动应用的 SwiftPM 命令，双架构模式仅构建。此偏差不作为真实额度或自动接入验证结果。

上述历史检查不覆盖 BP16 的直接额度实机核验；本节首段记录的 BP16 证据优先。瞬时 token/s 仍未完成；非阻断的现有构建警告另行跟踪；本地 ad hoc 签名不等于 Developer ID 分发或公证。

以下保留以前版本的验证记录作为历史基线，不代替本轮结果。

---

# 验证记录

本记录只包含通用测试方法与结果，不包含真实企业网关、账号、配置、日志或会话内容。BP07 C12-b 使用固定时间和纯合成 JSONL / UI 数据。

## BP08 C13 当前验证

- 核心合成检查：330/330 通过。覆盖身份与属性 allowlist、共享 R15 遍历预算及边界、双读归一化、残缺窗口拒绝、权限与生命周期状态。等值数值的不同文本精度通过；不同数值或无效读数拒绝。
- XCTest：20/20 通过，其中 Token Hub 状态测试 9 项；覆盖 fixture 原生读取抑制、注入扫描器保留、权限与模式切换、目标退出/重启后的 generation 失效、旧扫描结果丢弃、设置草稿不覆盖即时开关，以及显示精度。
- 合成图像：Dashboard 与完整额度卡片各有浅色、深色图。卡片位于本地 Dashboard 顶部；人工检查确认完整显示 5 小时、7 天、月度、重置、来源说明，且 `62.5%`、`$3.75`、`$12.5` 未被取整。图像保存在被忽略的 `Tests/.build/c13-render/`，没有改动 SnapshotTesting 基线或加入发布清单。
- 集成脚本：`python3 script/integration.py` 通过。代理路径检查路由、并发、流式、失败处理和日志脱敏；正常启动无测试状态继承；local Codex 使用隔离的合成会话，fixture 的辅助功能已授予/需授权两个 readiness 布尔值均保持 false，且不启动代理监听器。fixture 不请求系统授权或读取真实 AX 内容。
- Xcode Release：arm64 项目构建通过，日志位于本地忽略路径 `.build/c13-xcode-release.log`。
- Universal Release：`./script/build_and_run.sh --universal` 通过，最终二进制架构为 `x86_64 arm64`；`codesign --verify --deep --strict` 通过。二进制 SHA-256：`14e74cf4211adb45e87aa06153a71eacc0d650a59abb9d17956817dd3292cbc6`。构建和集成日志分别位于 `.build/c13-universal.log` 与 `.build/c13-integration.log`。
- Swift 编译仍输出已跟踪的非阻断 warning：异步合成渲染使用 `RunLoop.current.run(until:)`（Issue #28）以及现有 Sendable 捕获/AX 常量转换提示。本轮未扩大到 warning 清理。

所有 BP08 自动化输入均为合成值；没有发起系统辅助功能授权请求、读取实际 Token Hub AX 内容、安装或提升新应用。真实权限与实际窗口就绪情况仍未验证。

## BP07 C12-b 历史验证

- 核心检查程序：227/227 通过。覆盖本地 Codex 首记录身份、source/lineage 分类、重复 rollout 冲突与去重、fork delta、quota 快照更新、坏记录和未知贡献、缓存、生命周期、额度、路径安全与读取边界。
- 原生 XCTest：11/11 测试通过。包括已核验小计、未知线程与未识别文件文案、顶层会话和子代理分类、完整/不完整总量标记，以及现有配额与快照回归。
- 合成 Dashboard：导出并检查六张临时图像，涵盖“只有已识别子代理、无顶层对话”、部分核算和零个已核验线程三种状态，各有浅色和深色版本。图像只用于本轮人工检查，没有增加或改写 SnapshotTesting 基线。
- 集成脚本：`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./script/test.sh` 通过。代理路径覆盖四类路由、流式和非流式请求、并发、usage 更正、错误、取消、重定向拒绝、chunked 输入及日志脱敏；随后正常模式启动检查没有继承测试状态；独立 `CODEX_HOME` 合成会话启动成功，且本地模式没有打开代理监听器或继承企业额度。合成 rollout 首条记录包含合法 `session_meta`。
- Xcode Release：arm64 原生项目构建通过，使用默认本机签名设置 `Sign to Run Locally`。命令为 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project TokenStatMenu.xcodeproj -scheme TokenStatMenu -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/TokenStatMenu-C12-XcodeDerivedData build`。
- Universal：`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./script/build_and_run.sh --universal` 通过，生成包含 arm64 与 x86_64 的通用二进制；脚本执行本机 ad hoc 签名，`codesign --verify --deep --strict` 通过。二进制 SHA-256：`681b971f3633e9455a94dd46c921c7d8f29045d5b1a34322817acafb711ae028`。

## 仍适用的先前验证

以下 BP06 记录是历史证据，不是本轮重新执行的结果：此前核心检查 145/145、UI XCTest 9/9、四张静态 Dashboard / Settings SnapshotTesting 基线及 BP06 runtime readiness 检查。BP07 当前结果以上一节实际数字为准。

## 执行方式

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run --build-system native TokenStatCoreChecks
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-system native
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./script/test.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project TokenStatMenu.xcodeproj -scheme TokenStatMenu -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/TokenStatMenu-C12-XcodeDerivedData build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./script/build_and_run.sh --universal
python3 script/package_source.py
python3 script/check_public_content.py
```

## 数值口径与验证边界

`localCodex` 显示有界扫描中可核验的来源记录量；遇到未知线程、未识别文件或扫描上限时显示小计，不能称为完整历史总量。顶层对话数与子代理/分叉数分开显示。没有已核验线程时输入、输出和总量保持未知。quota 只作为本地历史快照，不代表企业账户额度，也不参与企业额度告警。

已完成轮速度是累计 output 差除以完整轮时长，包含工具、网络和等待，不是模型瞬时生成速度。缺少可验证的时间戳、累计基线或完整记录区间时速度保持未知。代理模式只统计经过本机代理的请求；它不包含未经过代理的历史会话。

- 以上自动化测试均使用隔离的合成目录，未读取真实会话正文、企业账号、Keychain 或企业配额接口；另行进行的正常运行 readiness 检查只记录布尔状态，不读取或公开会话数值与正文。合成测试不能证明所有用户数据均可核验，也不能证明真实企业账单或配额正确。
- 本地扫描有界：最多枚举 5000 项、处理 32 个物理文件、读取每文件头 64 KiB 与尾 256 KiB，总读取上限 10 MiB。结果不保证覆盖全目录或全部历史。
- 六张离线图与自动快照测试不等于完整系统菜单栏、键盘焦点或所有交互的人工验收。真实数据归属和历史总量仍需用户数据证据；本轮只验证合成契约。
- macOS 13 为部署目标；本轮没有逐个系统版本的实机覆盖。通用二进制构建不替代 Intel 硬件测试、Developer ID 签名或公证。
- 没有承诺固定运行时 CPU 或内存数值。

## 公开内容检查

公开内容由 `script/package_source.py` 中的文件清单生成。`check_public_content.py --git-index` 读取实际暂存文件，拒绝未列入清单的文件和符号链接，并扫描常见敏感模式。唯有清单中指定的四个合成 SnapshotTesting PNG 允许作为二进制；扫描器逐个核对 PNG 签名与 SHA-256。该扫描器不会上传内容，仍须人工审查发布差异。
