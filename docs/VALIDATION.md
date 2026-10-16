# 验证记录

本记录只包含通用测试方法与结果，不包含真实企业网关、账号、配置、日志或会话内容。BP07 C12-b 使用固定时间和纯合成 JSONL / UI 数据。

## BP07 C12-b 当前验证

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
