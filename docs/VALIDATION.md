# 验证记录

## 阶段 1 — 数据准确性与菜单口径（2026-10-18）

本节记录阶段 PR #70 合并提交 `60cba98`，以及后续时钟一致性修正提交 `459a106` 所覆盖的阶段 1 复验。它们分别让 Dashboard 额度卡、标题和诊断报告使用 `AppModel` 的 model clock，缓存可选诊断输出参数，并为 C29 的完整/受限本机记录标签加入合成回归。这些提交是阶段证据，不代表当前工作分支；本节只记录本机证据，不表示企业服务端已提供权威瞬时 token/s。

| 检查 | 实际结果 | 口径和限制 |
| --- | --- | --- |
| `TokenStatCoreChecks` | `swift run --skip-build --force-resolved-versions` 退出 0；程序报告 `611/611 checks passed` | 使用隔离合成输入，不能证明真实网关数据或实时服务端吞吐 |
| 完整 Swift/XCTest | `swift test --force-resolved-versions` 退出 0；`69/69` 通过（Dashboard 4、Seasun 启动 12、Token Hub 状态 42、UI 快照 11） | 合成与原生 XCTest 通过不等于真实 Settings AX 树验收；#33 仍开放 |
| 隔离脚本 | `DEVELOPER_DIR=... ./script/test.sh` 退出 0；Core `611/611` | 脚本不会读取会话正文、Keychain 或企业私有日志；CLT linker warning 仍按 #52 记录 |
| Xcode Release | 完整 Xcode `xcodebuild ... CODE_SIGNING_ALLOWED=NO build` 退出 0，`BUILD SUCCEEDED` | 这是本机构建证据，不是 Intel 实机、Developer ID 或公证证据 |
| 文档检查 | `check_docs.py --self-test` 退出 0；21 篇公开 Markdown 链接/锚点通过 | 不替代产品行为测试 |
| 公开内容 | `check_public_content.py --git-index` 退出 0；`85` 个白名单文件通过 | 扫描不包含账号、企业地址、额度、会话正文或个人路径；模式扫描不等同于任意 PII 的全面证明 |
| 源码导出幂等 | `package_source.py` 连续运行两次；`docs/FULL_SOURCE.md` SHA-256 均为 `4467ac18e5544d8275c83d7a7f74bc7cba1de4242d221ed39598f427ff9687c4` | 生成文件需随本阶段源码和文档一起审查 |
| 依赖锁 | 以上命令前后 `Package.resolved` SHA-256 均为 `dd9d4ec707661dfd30768ea6437231e00ca5f892832fcc415599334f96b0fea0` | 未执行自动解析或恢复锁 |

阶段 1 的真实限制保持明确：5 小时/7 天/月度额度使用企业只读来源；本机 Codex 统计保留来源、扫描范围、新鲜度和未核验线程标签；没有权威企业 server token/s 时间序列时，实时状态显示未知或明确标注为本机活动估算。`liveTokenSpeedPresent=false` 只代表本轮没有新鲜活动 token_count 证据，不是服务端吞吐为零。AX 树的真实可访问性验收继续留在 #33，CLT 默认 SwiftPM linker warning 继续留在 #52；本阶段没有关闭 #19 或 #37。

## 1.1.5 — DMG 分发候选（2026-10-18）

本节记录 BP32 当前本机候选的 DMG 相关合同检查，不代表已经创建正式 GitHub Release。版本元数据已切换为 1.1.5/build7；当前工作树仍需完成最终来源、隐私、索引和发布审查。1.1.4/build6 的真实历史仍是 ZIP-only，见下一节及其既有 Release 边界，不追溯增加 DMG。

| 检查 | 当前证据 | 限制 |
| --- | --- | --- |
| DMG 合同与反例 | `script/test_release_assets.py` 实际运行 47 tests、0 failures；其中覆盖五资产 manifest/SUMS、DMG 缺失/重复/篡改/错误身份/不安全成员/镜像错误以及发布集合冲突 | 合成 fixture 和 checker 通过不等于远端 Release 已发布 |
| 本机 DMG 逻辑 | 使用 `hdiutil imageinfo` 与只读 attach/detach 的实现已完成；镜像只允许 App 与 `/Applications` 别名，并复用四文件 App、版本、来源、双架构、严格签名检查 | 正式本机 DMG 创建/挂载结果、最终 byte/hash、Finder 拖拽和用户安装仍待本轮完整执行 |
| 发布资产合同 | 下一版目标为 App ZIP、源码 ZIP、Universal DMG、manifest、SHA256SUMS 五项；Homebrew 仍从源码 ZIP 构建 | 1.1.4 四资产历史不变；1.1.5 Actions/Release、下载回读和 tap 端点尚未通过 |
| 数据与运行边界 | DMG 不增加运行时、企业数据源、权限或自动更新逻辑；验证设计不启动 App、不替换现有安装、不读配置/Hub/Codex 数据 | 本节不证明正常启动、企业额度或菜单栏统计 |

DMG 文件名规则为 `TokenStatMenu-1.1.5-universal.dmg`，但只有实际 Release 中出现且 manifest/SHA256SUMS 一致时才可作为下载入口。安装说明使用 Finder 打开镜像并将 App 拖入“应用程序”；不自动退出旧进程，不绕过 Gatekeeper，不声明 Developer ID 或 Apple 公证。若下一版失败，保留失败标签并创建新的不可变版本；不移动或覆盖 v1.1.4。

## 1.1.4 — 跨工具链依赖锁修正候选（2026-10-18）

本节分别记录 1.1.4（build 6）方案的隔离实验与修正后本机候选复验。实验克隆自公开提交 `30ea1ba0971e0f317bc08ec70acc45ebf6ebddbe`；之后对实际修改后的候选重新运行了下表中的整套本机检查，没有将旧 1.1.3 的通过结果直接转写。本轮截止于 `modified` 来源候选，最终干净提交、源码/隐私独立审查、远端 CI、Release 和 Homebrew 端点尚待对应证据。

| 检查 | 已取得的实际证据 | 尚不能证明 |
| --- | --- | --- |
| 上游来源 | 官方精确 tag/revision 与版本化 manifest 已逐份核对，现有本机 checkout 字节与官方一致 | 历史 tag 从未移动或维护者密码学签名 |
| 完整锁的正向实验 | 本机 Apple Swift 6.4 执行 forced resolve、arm64/x86_64 路径查询、本机 App build、CoreChecks、一个不作 Keychain I/O 的原生测试，六项全部退出 0；每次完整锁原始字节均不变 | 较旧工具链已通过；两个路径查询也不是双架构实际构建 |
| 实验内部断言 | Core 611/611、筛选原生测试 1/1 通过 | 最终候选的完整 64 项套件或真实企业数据验收 |
| 缺少必要 pin | 移除当前图所需 issue-reporting 后，forced resolve 退出 1，诊断明确为禁用自动解析时拒绝过期锁；输入锁字节不变 | 任意网络错误不能替代该预期诊断 |
| 精确版本冲突 | SnapshotTesting 锁到合法旧版本 1.19.5，与根要求 1.19.6 冲突，forced resolve 退出 1；诊断明确约束已变，输入锁字节不变 | 不把失败当作成功解析，未自动修复锁 |
| 本机候选 Core 与隔离集成 | 实际 `script/test.sh` 退出 0，Core 611/611 与五组隔离启动通过 | 后台关闭的测试不证明真实企业链路 |
| 本机候选完整原生套件 | 实际 `swift test --force-resolved-versions` 64/64、0 失败，退出 0 | 不包含被自动化 runner 阻塞的 Settings 原生 AX 验收 |
| 本机候选 Release 合同 | 实际 Release 工具检查 41/41 通过，退出 0 | 合成/原生 fixture 不能代替真实 Actions 发布 |
| 本机候选 Xcode Release | `BUILD SUCCEEDED`，退出 0 | SDK 仍提示没有 AppIntents 依赖而跳过元数据提取，不宣称全日志零 warning |
| 本机候选 Universal | arm64/x86_64 实际 Release 构建退出 0；独立核对 1.1.4/6、四文件 Bundle、两架构与严格签名 | 来源状态为 `modified`，本地 ad hoc；不是最终干净提交产物、Intel 实机或 Apple 公证 |
| 复验后的完整依赖锁 | 全部上述命令后仍为 `dd9d4ec707661dfd30768ea6437231e00ca5f892832fcc415599334f96b0fea0`，独立 SHA-256 核对与实验组合锁相同 | 较旧工具链实际 CI 仍待运行；不靠恢复文件匹配摘要 |
| 最终来源审查与交付 | 等待源码/隐私独立审查、精确暂存与归档、干净提交及远端证据 | 尚不声称 CI、正式 Release 下载、production Formula、公开 tap 或最终安装已通过 |

组合锁完整保留四个原 pin，只增加经过官方 tag 核验的 `xctest-dynamic-overlay 1.13.1` / `d9308ad679143c26a30dec52daefe82f54af2b82`。本机图使用既有 `swift-issue-reporting 2.1.2` / `b23bb4493c439d3e05152bc167014235ba3d47fc`，另一工具链兼容图选择 overlay；SnapshotTesting 仍是精确 1.19.6。实验没有通过构建后恢复、覆盖或删除锁掩盖变化，公开源码在实验期间未被修改。

新的当前命令与脚本统一使用 `--force-resolved-versions`，发布流程继续保留干净源码比较。较旧 CI 图必须在实际 PR/main/tag workflow 中成功，并保持完整锁与导出源码不变；本机 Swift 6.4 不能替代这项证据。[Issue #60](https://github.com/Tupig/TokenStatMenu/issues/60) 保留失败 v1.1.3 的原因和后续验证。正式四资产实际下载、production Formula、tap 工作流和受控安装切换另行验收，不能从锁实验或计划版本推断成功。

服务端权威 TPS、完整安装即用统计、Settings 原生 AX 自动化环境和 CLT 上游诊断仍分别属于 #37、#19、#33、#52；本轮依赖锁修正不关闭它们。当前操作命令见 [编译指南](wiki/编译指南.md#固定测试依赖与跨工具链锁) 和 [测试指南](wiki/测试指南.md)。

## 1.1.3 — 发布流程与额度展示层次，本机组合候选（2026-10-18）

本节保留 1.1.3（build 5）组合候选当时的本机源码、测试与构建验收；当时源码仍有未提交改动，构建来源状态为 `modified`。随后公开提交 `30ea1ba0971e0f317bc08ec70acc45ebf6ebddbe` 已合并，但正式标签的 [Release run 39093885964](https://github.com/Tupig/TokenStatMenu/actions/runs/39093885964) 在导出后的干净源码比较中发现 `Package.resolved` 改动，正确失败。Core、指定原生检查、Xcode 和 Universal 构建步骤成功不等于 Release 成功；后续打包、上传与 publish 均跳过，没有 v1.1.3 正式 Release。失败标签保留，由 [Issue #60](https://github.com/Tupig/TokenStatMenu/issues/60) 跟踪，修正使用新候选 1.1.4/build6。以下原始通过记录没有被改写为新版本事实。

| 检查 | 已取得的本机证据 | 覆盖与限制 |
| --- | --- | --- |
| Core 回归 | `TokenStatCoreChecks` 611/611 通过；本轮未改 Core 采集与计量 | 使用合成记录，不能证明真实活动速度 |
| 完整原生套件 | 64/64、0 失败，退出 0 | 12 启动、38 状态、11 快照与 3 项历史展示；不是 Settings 的私有 XCUITest |
| 历史额度展示 | 3/3 通过；独立 PE 与 PM 检查实际概览浅/深、折叠/展开四张完整 460 点合成图 | 主企业卡保留、本地历史默认折叠、缺失/历史语义清楚、对称边距；初始状态渲染不是原生点击 |
| 隔离集成 | build-only 和五组安全启动检查退出 0 | 只管理测试子进程，禁用后台；不证明默认企业链路 |
| Release 工具合同 | 41/41 检查通过，退出 0 | 虚构元数据/下载、失败关闭与原生包装 fixture；不等于 Actions 已公开发布 |
| Homebrew 更新器合同 | 24 methods 中 23 通过、1 项显式本机安装校验跳过 | 默认无真实安装；真实两版本升级及最终公开 Formula 安装另行记录 |
| Xcode arm64 Release | `BUILD SUCCEEDED`，退出 0 | 仍有 SDK 未依赖 AppIntents 而跳过元数据提取的提示，不宣称全日志无 warning |
| Universal 与签名 | arm64/x86_64 Release 构建退出 0；四文件 Bundle manifest、1.1.3/5、两架构和严格签名均核对 | 本地 ad hoc 签名；没有 Intel 硬件或 Apple 公证验收 |
| 文档与公开内容 | 文档检查器自测及 19 篇链接/锚点通过；组合工作树公开内容检查通过 | 精确暂存/最终源码归档和最终发布身份需在冻结后核对 |
| 最终交付 | 尚待对应正式记录 | 干净提交、CI/合并、四资产实际下载、正式 tap 和最终安装不能由上表推断 |

[Issue #57](https://github.com/Tupig/TokenStatMenu/issues/57) 的本机展示修正已有源码与合成视觉证据：生产概览只保留企业当前窗口作为主额度，本地 Token/会话/覆盖与速度仍可见；未核验的本地历史窗口收进“本地历史额度（非企业当前额度）”默认折叠区。展开保留原已用比例、观察/重置时间和缺失文字，不补齐企业数据，不发起读取或改写设置。检查使用相互冲突的虚构直接/本地窗口，模型、菜单、告警及注入 I/O 守恒。合并、安装与 Issue 关闭仍以对应后续证据为准。

[Issue #33](https://github.com/Tupig/TokenStatMenu/issues/33) 的当前阻塞已从锁屏转为原生自动化环境：Mac 已解锁，私有固定 fixture 的 `build-for-testing` 退出 0；`test-without-building` 在 runner 初始化时报 `Timed out while enabling automation mode`，退出 65，A01–A07 测试体均未运行。没有通过 OCR、离屏 getter、放宽断言、TCC 修改或重置权限替代实际 AX 核验，该问题保持未完成。

主项目四资产 Release 与 Homebrew 三阶段更新流程已实装并完成本机合同检查；[Issue #55](https://github.com/Tupig/TokenStatMenu/issues/55)、[Issue #56](https://github.com/Tupig/TokenStatMenu/issues/56) 的实际正式发布、下载和安装结果，以对应 Issue 与 Actions run 证据为准。本节不提前写端到端通过，不以虚构 Formula pin 发布。1.1.3 也没有新的整 App CPU/RSS 降幅测量；历史性能数字仍仅用于其原合成场景。

服务端权威瞬时 TPS 的 [#37](https://github.com/Tupig/TokenStatMenu/issues/37)、完整安装即用统计的 [#19](https://github.com/Tupig/TokenStatMenu/issues/19) 与 CLT 上游警告的 [#52](https://github.com/Tupig/TokenStatMenu/issues/52) 保持原证据边界。额度布局修正、构建或分发自动化不能关闭这些来源/环境缺口。

## 1.1.2 — 金额解析、并发边界与构建维护（2026-10-18）

本节保留 1.1.2（build 4）当时的候选验收快照；“待完成”指该记录形成时的状态，不是当前远端或本机状态。后续该版本已通过 PR #54 合并到公开 `main`，本节不覆盖 1.1.3 的新验收，也不把 1.1.1 的通过结果套用于它。

| 检查 | 当前已取得证据 | 覆盖与限制 |
| --- | --- | --- |
| 核心金额与原有 Core 回归 | 最终隔离集成中 611/611 通过 | 包含实际 decoder 的滚动/月度四类金额字段 |
| 状态与并发回归 | 独立复跑 `TokenHubQuotaStateTests` 38/38，0 失败；该次编译 0 warning / 0 error | 使用完整 Xcode 与独立 scratch；不是完整原生套件、实际 Xcode 工程或真实 AX 正向验收 |
| 独立检查充分性和源码审查 | 金额、local cache actor、native AX actor 均完成对应审查 | 实际检查先于成对实现；源码复核不替代运行验收 |
| 隔离集成 | 最终 `script/test.sh` 退出码 0 | 核心、build-only 不全局终止/不启动、源码身份及五组隔离启动全部通过；不证明真实 Hub 默认接通 |
| Xcode arm64 Release | 最终实际工程 `BUILD SUCCEEDED`，退出码 0 | 原 AX scanner 非 Sendable 捕获 warning 已消失；SDK 仍提示未依赖 AppIntents 而跳过元数据提取，不能写成整个日志零 warning |
| 完整原生套件 | 最终 `swift test` 61/61，0 失败，退出码 0；该次编译 0 warning / 0 error | 12 项专用启动、38 项状态与 11 项快照；合成行为通过不等于真实原生 AX 正向验收 |
| Universal、签名 | 两架构 Release 构建退出码 0，该日志 0 warning / 0 error；独立 `lipo` 确认 `arm64` 与 `x86_64`，严格签名检查通过 | 本机 ad hoc 签名；没有 Intel 硬件、Developer ID 或公证验收 |
| 候选固定安装与默认启动 | 1.1.2（build 4）完整 4 文件 manifest 与构建产物相等，默认就绪 verifier 退出码 0 | 保留 1.1.1 回退副本；正常无诊断参数实例留运行，真实活动速度未验证 |
| 最终干净提交来源、精确暂存/源码包、CI 与合并 | 待最终冻结后核对 | 候选安装通过不等于后续干净提交产物、CI 或发布已通过；公开 main 的 1.1.1 记录见下一节补记 |

金额修正先通过真实 decoder 重现尾缀/空白/不完整数字等失败断言，再修正完整 ASCII JSON number 语法、128 字节和保守 38 位有效数字边界；扩大精度检查后也取得失败断言再修复。Foundation 可能已规范化原生 JSON number，结果不能证明任意精度原文保真；有限、非负、`10^18` 上限和窗口比例约束保持。详见[实现范围](IMPLEMENTATION.md#hub-企业额度)。

`LocalCodexScanWorker` 独占缓存、按 generation 重建，`NativeTokenHubAXWorker` 独占真实 reader；完整同步扫描期间都不挂起，跨执行器只传值。独立状态检查涵盖缓存复用/路由隔离、reload/shutdown、单次扫描、主 actor heartbeat、原生负路径、fixture 标记、迟到结果与较新直接请求隔离。C24 新边界首先取得 API 缺失的 compile-RED；该证据没有执行运行时红断言，也不是实际企业 AX 正向扫描。

异步 Hub 合成渲染改为可取消等待后重新布局，保留真实 PNG/尺寸断言并用 `defer` 清理窗口；未用删除渲染检查换取编译通过。共享 Xcode Scheme 与默认 SwiftPM 引擎已进入上述最终 Xcode/集成和双架构验证；干净提交来源与公开发布检查仍依上表补齐，不预称所有 warning 已消除。

候选固定安装的只读脱敏诊断为：`exactInstalledProcess=true`、`directQuotaPresent=true`、`fiveHourPresent=true`、`sevenDayPresent=true`、`fiveHourResetPresent=true`、`sevenDayResetPresent=true`、`monthlyUsagePresent=true`、`statusItemVisible=true`、`defaultReadinessPassed=true`、`permissionPromptRequested=false`。随后退出诊断实例，重新正常启动并确认 `normalLaunchWithoutDiagnosticArguments=true`、`leftRunning=true`。

同次 `liveTokenSpeedPresent=false`，说明没有完成本轮真实活动速度验收；不能用历史均速或合成测试补为实时通过。诊断只保存布尔就绪信息，不记录实际额度、Token 数、账号、内部地址或会话。候选 manifest 与回退比较也不能自动证明后续提交重新打包后的身份，需要再次核对。

以下事项保持未完成：

- [Issue #33](https://github.com/Tupig/TokenStatMenu/issues/33)：本机锁屏阻止实际 Settings 原生 AX 核验；合成窗口已准备，OCR 和源码标签不是替代证据。
- [Issue #19](https://github.com/Tupig/TokenStatMenu/issues/19) 与 [Issue #37](https://github.com/Tupig/TokenStatMenu/issues/37)：企业额度已存在零配置直接来源，完整安装即用统计及服务端权威瞬时 token/s 仍有来源缺口；本地估算与完整轮均速不能关闭该缺口。
- [Issue #52](https://github.com/Tupig/TokenStatMenu/issues/52)：CLT 默认 SwiftBuild 的搜索路径 warning 已用独立最小包复现，上游尚未修复。逐命令使用完整 Xcode 是已验证的规避路径，不等于消除 CLT 缺陷；见[编译指南](wiki/编译指南.md#clt-默认构建的已知工具链警告)。

1.1.1 的菜单循环与短时进程资源样本保留为历史，见[性能与基准](PERFORMANCE.md)；本次双 actor 修正没有新的整 App CPU/RSS 降幅结论。

## 1.1.1 — 文档、原生图标与空闲展示路径（2026-10-18）

本节区分最终候选的合成验证与既有安装记录。后续各节保留历史；它们不能替代本次候选的重新检查。

- 文档中心采用仓库内 `docs/README.md` → `docs/wiki/Home.md` → 使用、统计口径、排障、编译、测试、CLI、CI/CD 和贡献专题的结构。文档事实已逐项对照当前源码、脚本与 workflow；没有声称同步 GitHub Wiki 或存在尚未发布的 Release。
- 文档检查器的合成自测及 19 个公开 Markdown 文件的本地链接/锚点检查通过，`git diff --check` 通过。链接检查不能证明产品行为，参数与数值口径另以源码核对。
- 设置页状态先用合成直接来源重现：静态“尚不可用”导致未知、成功、过期和会话失败相关的 5 个断言失败；绑定实际新鲜来源后通过。专用启动测试曾完成 12/12，包括设置完整浅/深渲染与 OCR；视觉查看只使用合成材料，不读取真实账号或 Hub 界面。
- 最终核心与隔离集成：`./script/test.sh` 退出码 0，核心 416/416 通过，临时偏好、专用启动、后台禁用及源码构建身份隔离场景通过；测试没有调用全局进程名终止用户应用。
- 最终完整原生测试：`swift test` 54/54 通过，0 失败；不是只执行筛选的状态子集。Xcode arm64 Release 返回 `BUILD SUCCEEDED`。
- Universal Release 构建退出码 0，`lipo` 确认同时包含 `arm64` 与 `x86_64`，`codesign --verify --deep --strict` 通过。本地 ad hoc 签名不等于 Developer ID 签名或公证；Intel 仅完成架构构建，没有 Intel 硬件验收。
- 最终性能候选在独立 scratch 目录执行 `swift test --filter TokenHubQuotaStateTests`，31/31 通过。覆盖原有权限/生命周期/来源隔离回归，以及空闲不重复发布、Tooltip 失效、lazy hosting、15/15.001 秒、120/120.001 秒、时间回拨、两次 tick 间活动/窗口更新后跨边界、近过期 Hub 返回、后台区域/时区通知。
- 性能修正保存每次相关 Published 输入更新后的时效基线，而不是只比较上个 tick，以免漏掉两次 tick 之间已呈现的新鲜值随后过期。原问题已用合成回归重现，最终候选的回归通过；不是通过延长时效或降低采集频率规避。
- 公开基准脚本的最终三轮结果为：旧路径 `562.007 / 564.312 / 560.957 ms`，候选 `80.558 / 81.818 / 81.210 ms`；中位 `562.007 → 81.210 ms`，指定 10,000 次合成循环耗时减少约 85.6%，每轮 `objectWillChange` 为 `10,000 → 0`。两组隔离重编、同编译器/SDK/`-Onone`、共用当前 Core 与其余 App 源码，只替换两个菜单文件。该比例不是整 App CPU、RSS、能耗或启动时间改善；方法见 [性能与基准](PERFORMANCE.md)。
- 图标以项目原创 Swift 几何绘制为最终来源，PNG / `.icns` 通过系统工具生成，进入 SwiftPM App 与 Xcode 的资源链；候选元数据为 1.1.1（build 3）。
- 固定安装候选已完成：安装副本与构建产物的完整 4 文件 manifest 相等，保留旧版供回退；旧进程停止前精确核对 PID、可执行路径、UID 和微秒级启动时间，没有按全局名称终止其他实例。默认启动通过 `NSWorkspace` 归属校验，验证程序退出码 0，正常无参数实例保留运行。
- 同次候选安装验收的脱敏就绪结果为：`directQuotaPresent=true`、`fiveHourPresent=true`、`sevenDayPresent=true`、`fiveHourResetPresent=true`、`sevenDayResetPresent=true`、`monthlyUsagePresent=true`、`statusItemVisible=true`、`defaultReadinessPassed=true`、`permissionPromptRequested=false`。只记录布尔就绪状态，不公开真实额度、Token 数量、账号、企业地址或个人路径。
- 同次 `liveTokenSpeedPresent=false`：没有新鲜活动事件，不能声称本轮真实运行已验证实时 token/s。服务端权威吞吐继续由 [Issue #37](https://github.com/Tupig/TokenStatMenu/issues/37) 跟踪，本地活动估算与上轮均速保留独立标识。
- 正常安装候选完成只读菜单栏空闲采样：20.162 秒内进程 CPU 时间增量 0.0044 秒，折合单核平均约 0.022%；RSS 样本最小/最大均为 67.98 MiB，进程身份全程匹配。旧 1.1.0 的另一个 20.079 秒窗口为 CPU 增量 0.0069 秒、单核约 0.034%、RSS 112.08–112.25 MiB。两个实例年龄及首次面板状态等生命周期条件未完全控制，不能作为整 App 节省百分比；与合成循环证据分开，详见 [性能与基准](PERFORMANCE.md)。

上述合成菜单基准与自动状态检查使用合成输入和手动时钟，不执行真实 SSO、企业请求、AX 读取或新系统授权；真实进程资源采样不属于这组合成检查。候选固定安装验收另行执行正常真实来源读取，仅保留上述布尔结果。当前结论限于本机候选，不能推广到全新机器、所有企业部署或 Intel 硬件。CI 尚未记录为已执行，Developer ID 与公证未做。

本节是候选安装验收。后续干净提交会改变公开源码 revision，必须重新写入 bundle 并核对 provenance 与安装产物一致性，不能将此候选记录套用于尚未构建的后续提交。以下 BP19 安装证据属于 1.1.0 历史。

### 1.1.1 最终发布与安装补记

上述“CI 尚未记录”和“后续干净提交”描述的是候选阶段。其后 [PR #49](https://github.com/Tupig/TokenStatMenu/pull/49) 的 macOS CI 成功并合并，公开 main `82874eeee9931deef9e62b62d3156c1db91303a9` 与已测试提交 `f0f43fc7f96b6ea1152a3087342e3a6b82dff7fd` 的文件树相同；公开 checkout 干净，79 文件源码 manifest 核对通过。

最终固定安装保持 1.1.1（build 3），写入干净提交来源。候选与最终 Universal 的未签名字节相同，Info.plist 与签名的预期差异单独记录；安装副本、构建目录和本地归档 manifest 经独立比较一致。默认无参数启动确认企业 5 小时、7 天、两项重置、月度与菜单栏就绪，未请求权限，实时活动速度未验证；仅保留一个正常安装实例和回退副本。

图标、文档、菜单重复工作和设置来源文案对应的 Issues #45–#48 随合并关闭。本地源码/App 归档已同步；未创建正式 GitHub Release、Developer ID 签名或公证。权威瞬时 TPS、Intel 硬件、真实 Hub 重启与完整历史归属/账单仍不在已完成证据内。本补记只完成 1.1.1 的发布追溯，不预称 1.1.2 已安装或发布。

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

## BP07 当时执行方式（历史）

以下是 BP07 当时的执行记录，不是当前构建建议。当前复验使用带 `--force-resolved-versions` 的[测试指南](wiki/测试指南.md)与[编译指南](wiki/编译指南.md)，不要按历史命令删除或重新生成锁。

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run TokenStatCoreChecks
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
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
