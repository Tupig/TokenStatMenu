# TokenStatMenu

面向 Seasun Token Hub 用户的原生 macOS 菜单栏统计工具，使用 Swift、SwiftUI 和 AppKit，提供中文界面。目标是安装后自动取得可信的额度与用量，不要求用户填写接口或密钥。**当前仍在开发：企业额度的直接自动接入和真实瞬时 token/s 尚未完成。**

正式 App 已收敛为 Seasun 专用入口：不再提供通用 API 配置、代理模式、模型与价格填写。旧代理配置不会启动代理、访问旧接口或读取保存的密钥；无配置和损坏的旧配置都使用安全默认偏好。此改动消除了手工接入流程，但不代表已经取得缺失的企业数据。

## 当前可用数据

| 显示内容 | 来源与限制 |
| --- | --- |
| 输入、输出、总 Token 小计与线程分类 | 本机 Codex 有界会话记录；不是企业完整账单或全部对话 |
| 上轮记录均速 | 有完整开始/用量/完成证据的轮次；包含工具、网络与等待，不是瞬时生成速度 |
| 5 小时、7 天与月度金额界面快照 | 可选的 Token Hub 辅助功能兼容读取；依赖已授予的系统权限与可访问的额度区域 |
| 本地历史窗口 | Codex 记录中的历史参考；账号、组织归属未核验，不作企业当前额度 |
| 无权限、无来源或缺失字段 | 明确显示不可用或未知，不以零、其他窗口或历史数据代替 |

辅助功能兼容方式不是“安装即用”目标的验收结果。正常启动不会请求系统权限。工具不会读取其他应用的登录凭据，也不会修改企业网关或 Codex 的连接设置。

## 整体架构

```text
AppKit NSStatusItem + NSPopover
  └─ AppModel：固定专用入口、可选偏好、来源状态与刷新
      ├─ 本地 Codex 有界记录扫描 → 小计、分类、上轮均速
      ├─ Token Hub 兼容界面扫描 → 独立金额/窗口快照
      └─ Seasun 直接统计源 → 尚未建立，保持未知
SwiftUI：概览、来源说明、可选偏好
```

菜单标题由主线程低频刷新，仅在内容或颜色变化时更新。后台扫描串行、有界、可取消，退出或来源身份变化使旧结果失效。正式运行不启动本机代理，不调用任意企业 URL，不解析保存的 API 密钥。历史协议实现保留在核心库中供回归测试，不属于正式 App 的接入功能。

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

运行后从右上角菜单栏打开面板，无主窗口。设置只包含可选的刷新与界面快照兼容偏好；不需要创建配置文件。详情见 [偏好说明](docs/CONFIGURATION.md)。如果直接企业来源尚未接通，界面会保留真实状态，不要求用户用手填接口补齐。

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

集成测试使用临时配置和禁用后台服务的独立子进程，只清理自己持有的进程句柄。它不会调用企业网关、读取真实会话或触发系统授权。截图测试使用真实 SwiftUI/NSHostingView 与合成数据；新的参考图需独立视觉审查，录制本身不算通过。最新验证范围见 [验证记录](docs/VALIDATION.md)。

扫描有覆盖上限；身份与继承证据不足时单独标记未核算，不把未知贡献当零。金额与 Token 不互换；界面快照的 `$` 不自动认定为某一币种。不根据重置短文本猜测年份或时区。更多处理边界见 [隐私说明](PRIVACY.md) 和 [设计说明](docs/DESIGN.md)。

## 开源

采用 [MIT 许可证](LICENSE)。请在 GitHub Issue 中使用合成示例报告问题，不提交真实凭据、企业地址、账户信息、会话正文、截图或运行日志。界面布局参考 codexU 的紧凑分组思路，采用原生系统颜色适配深浅外观；未复制其实现代码。
