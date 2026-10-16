# 验证记录

本记录只包含通用测试方法与结果，不包含真实企业网关、账号、配置或日志。

## 已通过

- 核心检查程序：49/49，包括流解析、用量校正、并发、HTTP framing、配额、费用和本地网关发现。
- 完整 Xcode：原生项目 Release 编译成功，使用 `CODE_SIGNING_ALLOWED=NO` 验证源码与目标配置。使用者可以自行选择签名方式。
- SwiftPM：原生 App 编译成功，实际 App 与本机模拟接口的联测通过。
- AppKit 诊断：标题、模拟来源标记、黄色/红色配额告警、正常启动未采集状态正确。
- 本地发现联测：读取隔离的虚构 Codex 配置，候选数量正确；发现结果未自动改变上游配置，诊断文件不包含测试认证字段。
- 本地代理联测：四类路由、流式/非流式、三个并发请求、usage 替换、错误、取消、chunked 输入、重定向拒绝与日志脱敏均通过。

网关发现测试覆盖：活动 provider/profile 优先级、企业自定义路径、模型归属、含认证值的 URL 拒绝、重复配置拒绝、多行指令内容不冒充配置、白名单环境变量与 1MB 文件上限。测试均使用虚构域名和纯测试认证值。

执行方式：

```bash
swift run --build-system native TokenStatCoreChecks
./script/test.sh
xcodebuild -project TokenStatMenu.xcodeproj -scheme TokenStatMenu -configuration Release -derivedDataPath /tmp/TokenStatMenu-Verify CODE_SIGNING_ALLOWED=NO build
python3 script/package_source.py
python3 script/check_public_content.py
```

## 数值口径

没有采集到请求时显示 `T:—`，并非真实用量为零。请求结束后无活跃请求才显示 `T:0.0tok/s`。实时输出速度和缺失 usage 的累计量带 `≈` 标记。测试参数 `--test-fixture` 会在菜单栏和面板显式标注模拟来源。

完成请求的速度窗口不影响新的活跃请求；重复 usage 只替换、不重复累加；`error: null` 不记为失败。联测最后会重新启动正常模式，检查没有继承测试配额。测试默认关闭模拟 App 与服务。

## 验证边界

- 没有用真实企业认证或账单证明端到端接入成功。网关发现只是本地配置解析，不代表认证、网络或配额接口可用。
- 没有模型 tokenizer 或实时服务端 token 计数时，SSE 文本速度仍是启发式估算。固定 5 秒窗口会使启动阶段低于全程平均速度。
- 统计仅包含启动后经过代理的请求，不包含历史 Codex 对话，不把请求次数等同于会话数。
- 已生成并检查浅色/深色 SwiftUI + AppKit 离线视图预览（概览与设置）；全部使用明确标记的模拟数据。它不等于对系统菜单栏展开、滚动和键盘交互的完整人工验收。
- macOS 13 为部署目标；没有逐个系统版本的实机覆盖。Intel 构建不能替代 Intel 硬件测试。
- 本机 ad hoc 签名或未签名编译不能替代 Developer ID 签名与公证。
- 原生框架、有限缓冲与限频刷新用于控制开销，但没有承诺固定运行时内存或 CPU 数值。

## 公开内容检查

公开内容由 `script/package_source.py` 中的文件清单生成。`check_public_content.py --git-index` 读取实际暂存文件，拒绝未列入清单的文件、二进制、符号链接及常见敏感模式。扫描器是辅助检查，仍须人工审查发布差异；它不会上传扫描内容。
