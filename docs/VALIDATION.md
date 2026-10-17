# 验证记录

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

上述检查不证明真实企业额度、账号归属、后台刷新或瞬时 token/s 已接通。无需新增权限的安装即用目标仍未完成。非阻断的现有构建警告另行跟踪；本地 ad hoc 签名不等于 Developer ID 分发或公证。

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
