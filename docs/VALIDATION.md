# 验证记录

本记录只包含通用测试方法与结果，不包含真实企业网关、账号、配置或日志。

## 已通过

- 核心检查程序：95/95，包括流解析、用量校正、并发、HTTP framing、月度与窗口配额、费用、本地网关发现和隔离的本机 Codex JSONL 扫描边界。
- 集成联测：最终 `./script/test.sh` 通过，核心检查 95/95，原生应用构建成功，隔离代理工作流、正常代理启动，以及独立 `CODEX_HOME` 下的合成嵌套会话启动均通过。测试只用虚构数据；本地模式没有启动代理监听器或继承企业配额。
- 完整 Xcode：最终原生项目 Release 编译成功，使用 `CODE_SIGNING_ALLOWED=NO` 验证源码与目标配置。使用者可以自行选择签名方式。
- Universal：最终 `./script/build_and_run.sh --universal` 成功，分别构建 arm64 与 x86_64 Release slice 并合并为本地通用 App；两种架构均构建通过。该结果不替代 Intel 硬件实测、Developer ID 签名或公证。
- AppKit 诊断：标题、模拟来源标记、黄色/红色配额告警、正常启动未采集状态正确。
- 视图渲染：10 个合成预览输出成功，包括 8 个浅色 / 深色代理模式 Dashboard、Settings、窗口额度缺失和窗口数据过期预览，以及 2 个本地 Codex 用量概览。已检查本地 Codex 浅色和深色图像；导航切换行为由源码审查确认，本轮没有单独模拟点击交互。
- 对称留白：隐藏两处纵向滚动指示器后，浅色和深色概览与设置预览显示左右各约 16 pt 留白；设置页实际 NSScrollView 内容视口从 443 pt 扩展至 460 pt 面板宽度。源码确认两页均保留纵向滚动；设置页已验证可滚动到文档底部并返回起始位置。概览页仅完成渲染与源码检查，未测量其滚动终点；未单独模拟按钮点击或滚动手势。
- 本地发现联测：读取隔离的虚构 Codex 配置，候选数量正确；发现结果未自动改变上游配置，诊断文件不包含测试认证字段。
- 本地代理联测：四类路由、流式/非流式、三个并发请求、usage 替换、错误、取消、chunked 输入、重定向拒绝与日志脱敏均通过。
- SnapshotTesting 1.19.6：SwiftPM `TokenStatUITests` 仅为测试目标依赖，四个真实 `DashboardView` 工具栏浅色/深色图像均与经审阅基线匹配；URL 绑定账户名与内存图像差异检测通过。CI 只编译 UI 测试目标并运行这两项 OS 无关检查，不在 macOS 15 上比较 macOS 27 基线。
- 本地 Codex 合成扫描：覆盖子目录、UUID 大小写别名、最后累计记录、整数精度与溢出、截断尾行、额度时间戳、符号链接拒绝及枚举/字节上限；未读取真实会话目录。

网关发现测试覆盖：活动 provider/profile 优先级、企业自定义路径、模型归属、含认证值的 URL 拒绝、重复配置拒绝、多行指令内容不冒充配置、白名单环境变量与 1MB 文件上限。测试均使用虚构域名和纯测试认证值。

执行方式：

```bash
swift run --build-system native TokenStatCoreChecks
./script/test.sh
xcodebuild -project TokenStatMenu.xcodeproj -scheme TokenStatMenu -configuration Release -derivedDataPath /tmp/TokenStatMenu-Verify CODE_SIGNING_ALLOWED=NO build
python3 script/package_source.py
python3 script/check_public_content.py
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter TokenStatUISnapshotTests
```

## 数值口径

没有采集到请求时显示 `T:—`，并非真实用量为零。请求结束后无活跃请求才显示 `T:0.0tok/s`。实时输出速度和缺失 usage 的累计量带 `≈` 标记。测试参数 `--test-fixture` 会在菜单栏和面板显式标注模拟来源。

完成请求的速度窗口不影响新的活跃请求；重复 usage 只替换、不重复累加；`error: null` 不记为失败。联测最后会重新启动正常模式，检查没有继承测试配额。测试默认关闭模拟 App 与服务。

## 验证边界

- 没有用真实企业认证或账单证明端到端接入成功。网关发现只是本地配置解析，不代表认证、网络或配额接口可用。
- 没有模型 tokenizer 或实时服务端 token 计数时，SSE 文本速度仍是启发式估算。固定 5 秒窗口会使启动阶段低于全程平均速度。
- 代理模式统计仅包含启动后经过本机代理的请求，不包含历史 Codex 对话。`localCodex` 模式则读取本机 Codex 会话 JSONL 中有界的历史用量记录；它不代表企业总量或实时流量。两种模式都不把请求次数等同于会话数。
- 已生成并检查浅色/深色 SwiftUI + AppKit 离线视图预览；全部使用明确标记的模拟数据。它不等于对系统菜单栏展开、滚动和键盘交互的完整人工验收。
- Snapshot 基线在 macOS 27.0.1、Xcode 27.1、Retina 2x 环境录制；按 `docs/UI_TESTING.md` 在相同系统和显示比例下比较。自然焦点诊断的合成 NSPopover 未成为 key window（`appActive=false`、`keyWindow=false`），键盘焦点/绿色焦点环仍未验证。工具栏图像只验证静态外观。
- macOS 13 为部署目标；没有逐个系统版本的实机覆盖。Intel 构建不能替代 Intel 硬件测试。
- 本机 ad hoc 签名或未签名编译不能替代 Developer ID 签名与公证。
- 原生框架、有限缓冲与限频刷新用于控制开销，但没有承诺固定运行时内存或 CPU 数值。

## 公开内容检查

公开内容由 `script/package_source.py` 中的文件清单生成。`check_public_content.py --git-index` 读取实际暂存文件，拒绝未列入清单的文件和符号链接，并扫描常见敏感模式。唯有清单中指定的 4 个合成 SnapshotTesting PNG 允许作为二进制；扫描器逐个核对 PNG 签名与 SHA-256。扫描器是辅助检查，仍须人工审查发布差异；它不会上传扫描内容。
