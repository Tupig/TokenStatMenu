# TokenStatMenu

面向 Seasun Token Hub 用户的原生 macOS 菜单栏统计工具，使用 Swift、SwiftUI 和 AppKit，提供中文界面。安装后自动发现本机已登录的 Token Hub，并在内存中交换短期会话后读取只读额度；不要求用户填写接口、密钥、模型或字段。本机记录按当前 Codex provider 与 Token Hub origin 的匹配关系筛选；这不能证明同名历史会话的实际路由，记录小计与企业额度分开显示。活动轮次有连续、新鲜的累计事件时显示“实时估算” token/s，事件停止推进则回退为上轮均速或未知。

正式 App 已收敛为 Seasun 专用入口：不再提供通用 API 配置、代理模式、模型与价格填写。旧代理配置不会启动代理、访问旧接口或读取保存的密钥；无配置和损坏的旧配置都使用安全默认偏好。企业额度来源只依赖本机已登录 Token Hub 的只读会话。

## 当前可用数据

| 显示内容 | 来源与限制 |
| --- | --- |
| 输入、输出、总 Token 小计与线程分类 | 当前配置关联的本机 Codex 有界会话记录，历史路由未核验；不是本次启动消耗、企业完整账单或全部对话 |
| 实时估算 token/s | 活动 `token_count` 累计值短窗口差分；最后事件超过 15 秒显示未知，不伪造网关权威速度 |
| 上轮记录均速 | 有完整开始/用量/完成证据的轮次；包含工具、网络与等待，作为实时估算回退 |
| 5 小时、7 天剩余额度、重置时间与月度金额 | 自动复用本机已登录 Token Hub 的会话，读取其既有后台额度响应；来源缺失的字段保持未知，金额不转换为 Token |
| 可选金额界面快照 | 直接来源不可用时的辅助功能兼容读取；依赖已有系统信任与可访问的额度区域，明确标注界面来源 |
| 本地历史窗口 | Codex 记录中的历史参考；账号、组织归属未核验，不作企业当前额度 |
| 无权限、无来源或缺失字段 | 明确显示不可用或未知，不以零、其他窗口或历史数据代替 |

默认接入的前提是本机已正常运行并登录 Seasun Token Hub。直接额度读取不依赖辅助功能权限，也不受兼容读取开关影响；正常启动不会请求额外系统权限。工具只复用 Token Hub 自有数据库内必要的现有登录材料，不修改企业网关或 Codex 的连接设置。会话材料仅用于向该配置中既有的 HTTPS 来源完成交换，不发送到遥测或其他第三方服务。

## 整体架构

```text
AppKit NSStatusItem + NSPopover
  └─ AppModel：固定专用入口、可选偏好、来源状态与刷新
      ├─ 当前 Seasun origin 配置匹配 + 本地 Codex 有界记录扫描 → 小计、分类、实时估算/上轮均速
      ├─ Token Hub 只读会话交换 → 企业 5 小时/7 天/月度额度
      ├─ Token Hub 兼容界面扫描 → 无直连时的可选独立金额/窗口快照
SwiftUI：概览、来源说明、可选偏好
```

菜单标题由主线程低频刷新，仅在内容或颜色变化时更新；标题、详情与诊断共用实时值的 15 秒时效判断。后台扫描串行、有界、可取消，目标退出或来源身份变化使旧结果失效；目标重新启动后自动重试直接来源。正式运行不启动本机代理，不调用任意企业 URL，不解析保存的 API 密钥。历史协议实现保留在核心库中供回归测试，不属于正式 App 的接入功能。

## 文件与职责

- `Sources/TokenStatMenu/`：菜单栏、弹出面板、专用启动与偏好、兼容界面读取。
- `Sources/TokenStatCore/`：记录解析、核算、窗口模型和历史协议组件。
- `Tests/`：合成数据的核心检查、原生界面及专用启动回归。
- `Resources/`：应用元数据与仅含可选偏好的示例 plist。
- `script/`：构建、隔离集成、截图和公开源码导出。
- `docs/FULL_SOURCE.md`：按架构、分文件源码、构建步骤生成的完整源码文档。

## 构建与运行

需要 macOS 13 或更新版本，以及支持 Swift 5.9 的 Xcode/命令行工具。项目运行时只使用系统框架；UI 截图测试依赖精确版本的 swift-snapshot-testing，正式 App 不链接它。

```bash
# 在项目目录内只构建，不关闭已运行的 App
./script/build_and_run.sh --build-only

# 打开构建产物
open dist/TokenStatMenu.app

# 仅编译 Release，不启动应用
swift build -c release --product TokenStatMenu

# 同时构建 Apple Silicon 与 Intel
./script/build_and_run.sh --universal
```

也可打开 `TokenStatMenu.xcodeproj`，选择 TokenStatMenu Scheme 和 My Mac 后编译运行。若默认开发目录指向 Command Line Tools，可仅为当前命令设置：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project TokenStatMenu.xcodeproj -scheme TokenStatMenu -configuration Release build
```

`--release` 是构建后运行模式，验证时不要把它当作只构建选项；需要隔离检查请使用测试脚本。

构建脚本的本地 ad hoc 签名不是 Developer ID 签名或公证。对外分发应另行使用开发者证书、公证并验证下载后的 Gatekeeper 行为。辅助功能授权也可能因本地开发构建身份变化而失效。

## 使用与偏好

应用版本为 1.1.0（build 2），便于区分早期构建。运行后从右上角菜单栏打开面板，无主窗口。设置只包含可选的刷新与界面快照兼容偏好；不需要创建配置文件。详情见 [偏好说明](docs/CONFIGURATION.md)。应用会读取 Token Hub 自有数据库中的必要连接/登录材料到内存，拦截 SSO 回调重定向并用短期令牌请求只读额度；不会把会话或额度写入日志、配置或仓库。会话过期、变化、多实例或入口不可用时，界面显示具体不可用状态。

旧配置在启动和重新加载时保持原文件不变，仅读取允许的偏好。用户主动保存偏好时，原子写入两项偏好并去除旧的通用接入字段。读取或保存失败不会回退到代理或发出企业请求。

## 验证与限制

```bash
# 核心检查
swift run TokenStatCoreChecks

# 原生 XCTest，使用合成数据与隔离偏好
swift test

# 核心、构建及独立子进程的专用启动集成
./script/test.sh
```

集成测试使用临时配置和禁用后台服务的独立子进程，只清理自己持有的进程句柄。合成测试不会调用企业网关或读取真实会话；真实本机核验只记录 HTTP 状态、字段结构和布尔就绪信息。截图测试使用真实 SwiftUI/NSHostingView 与合成数据；新的参考图需独立视觉审查，录制本身不算通过。最新验证范围见 [验证记录](docs/VALIDATION.md)。

扫描有覆盖上限；身份与继承证据不足时单独标记未核算，不把未知贡献当零。损坏 JSON、读取缺口、不完整尾行、重叠轮次、未来或倒序时间都不能跨过去继续生成实时估算。当前配置匹配不能回溯认证历史路由，真实服务端瞬时吞吐仍由 [Issue #37](https://github.com/Tupig/TokenStatMenu/issues/37) 跟踪。金额与 Token 不互换；界面快照的 `$` 不自动认定为某一币种。不根据重置短文本猜测年份或时区。更多处理边界见 [隐私说明](PRIVACY.md) 和 [设计说明](docs/DESIGN.md)。

## 开源

采用 [MIT 许可证](LICENSE)。请在 GitHub Issue 中使用合成示例报告问题，不提交真实凭据、企业地址、账户信息、会话正文、截图或运行日志。界面布局参考 codexU 的紧凑分组思路，采用原生系统颜色适配深浅外观；未复制其实现代码。
