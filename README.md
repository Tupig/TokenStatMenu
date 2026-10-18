# TokenStatMenu

<img src="Resources/AppIcon.png" width="96" alt="TokenStatMenu 应用图标">

面向 **Seasun Token Hub** 用户的原生 macOS 菜单栏统计工具，使用 Swift、SwiftUI 和 AppKit，提供中文界面。在本机 Token Hub 已运行并登录的前提下，自动读取 5 小时、7 天与月度额度，并展示当前配置关联的本地 Codex 记录，无需填写接口、密钥、模型或字段。

**从这里开始：[文档中心](docs/wiki/Home.md) · [安装与使用](docs/wiki/安装与使用.md) · [统计口径](docs/wiki/统计口径.md) · [常见问题](docs/wiki/常见问题.md)**

> [!IMPORTANT]
> 菜单栏的“实时≈”是本地活动记录的 token/s 估算；“上轮均”包含工具、网络与等待时间。权威服务端瞬时吞吐尚未接通，见 [Issue #37](https://github.com/Tupig/TokenStatMenu/issues/37)。本地记录小计、企业额度金额和完整账户账单是不同数据，不能互相替代。

## 功能与适用范围

| 能看到什么 | 来源与实际含义 |
| --- | --- |
| 菜单栏速度 | 有新鲜、连续的活动累计记录时显示输入／输出速率估算；没有依据时显示未知或上轮均速 |
| 5 小时与 7 天额度 | Token Hub 后台只读响应中的金额额度、剩余比例和重置时间；缺失窗口保持未知 |
| 月度用量 | 后台提供的月度金额，与本地 Token 量分开显示 |
| 本地 Token 与对话分类 | 有界扫描内可核算的输入、输出、总量与线程分类；不代表本次启动消耗或侧栏全部对话 |
| 可选界面兼容快照 | 已有辅助功能信任时的回退来源，明确标注“界面”；关闭它不会关闭后台直接读取 |
| 中文菜单栏界面 | 无主窗口、适配深浅色，不使用 Electron，不引入第三方运行时框架 |

应用目前专用于 Seasun Token Hub。通用 API、Ollama、手填网关、价格和代理接入不属于正式界面；核心库保留的旧协议代码用于回归测试，不能据此推断正式 App 已支持这些接入方式。

当前配置只能关联同名 provider 的本地记录，不能反向证明全部历史会话的实际网关路由。无法核算、超出覆盖范围或来源缺失的部分会标为未知，不当作零。完整解释见 [统计口径](docs/wiki/统计口径.md)。

## 快速开始

需要 macOS 13 或更新版本，Apple Silicon 或 Intel Mac。Homebrew 安装从正式版本源码在本机编译，需要完整 Xcode 15 或更新版本；Homebrew 对宿主系统的支持范围另以其要求为准。Apple Silicon 为优先验证平台，Intel 已有交叉构建；不能把交叉构建当作 Intel 硬件验收。

先正常启动并登录 Seasun Token Hub，再通过项目的 [Homebrew tap](https://github.com/Tupig/homebrew-tokenstatmenu) 安装和打开：

```bash
brew install Tupig/tokenstatmenu/tokenstatmenu
tokenstatmenu
```

安装与升级只更新磁盘上的应用，不会自动启动、退出或重启已有实例。更新时先从 TokenStatMenu 菜单退出应用，再执行：

```bash
brew update
brew upgrade Tupig/tokenstatmenu/tokenstatmenu
tokenstatmenu
```

Homebrew 从正式 Release 的校验源码包构建原生 App，使用本机 ad hoc 签名；正式 App 仅依赖系统框架。它不会替换个人“应用程序”目录中的手动安装副本，也没有应用内自动更新器。完整说明见 [安装与使用](docs/wiki/安装与使用.md)。

开发者也可直接构建源码：

1. 在本机正常启动并登录 Seasun Token Hub。
2. 克隆仓库并构建应用：

   ```bash
   git clone https://github.com/Tupig/TokenStatMenu.git
   cd TokenStatMenu
   ./script/build_and_run.sh --build-only
   ```

3. 先退出已运行的旧版 TokenStatMenu，再打开新产物：

   ```bash
   open dist/TokenStatMenu.app
   ```

正常启动只显示菜单栏条目，点击后展开面板；没有主窗口属于预期行为。不需要创建 plist，也不需要授予辅助功能权限来连接后台。设置里的辅助功能入口仅用于可选界面兼容读取。

首次 SwiftPM 构建可能需要联网解析测试依赖。当前 1.1.4/build6 历史 Release 保持 ZIP-only；下一版目标 1.1.5/build7 在同一 Universal App ZIP 和源码 ZIP 之外增加 Finder 友好的 DMG 安装包装。DMG 不是新运行时或更新器，必须与同一已审核 App、源码、manifest 和 SHA256SUMS 绑定；实际发布页是否已有五资产仍以远端证据为准。二进制发行使用 ad hoc 签名，尚未完成 Developer ID 签名或 Apple 公证；Homebrew 通过在本机编译源码安装。固定路径安装、升级、回退和首次打开说明见 [安装与使用](docs/wiki/安装与使用.md)。

## 文档导航

文档采用 README 入口、文档中心和专题页的结构。可以按下面的任务选择阅读路径，也可从 [文档目录](docs/README.md) 查找全部页面。

| 你要做什么 | 建议阅读 |
| --- | --- |
| 第一次运行或更新应用 | [安装与使用](docs/wiki/安装与使用.md) → [可选偏好](docs/CONFIGURATION.md) |
| 看懂速度、额度和会话数 | [统计口径](docs/wiki/统计口径.md) → [常见问题](docs/wiki/常见问题.md) |
| 了解读取范围和会话复用 | [隐私说明](PRIVACY.md) → [设计说明](docs/DESIGN.md) |
| 编译、测试或调试 | [编译指南](docs/wiki/编译指南.md) → [测试指南](docs/wiki/测试指南.md) → [命令行参数](docs/wiki/命令行参数.md) |
| 查看自动检查与交付状态 | [CI/CD](docs/wiki/CI-CD.md) → [实现范围](docs/IMPLEMENTATION.md) → [验证记录](docs/VALIDATION.md) |
| 报告问题或贡献代码 | [贡献指南](docs/wiki/贡献指南.md) → [Issues](https://github.com/Tupig/TokenStatMenu/issues) |
| 按文件阅读全部源码 | [完整源码文档](docs/FULL_SOURCE.md) |

## 整体架构

```text
AppKit NSStatusItem + NSPopover
  └─ AppModel：专用启动、来源状态、可选偏好与后台调度
      ├─ Token Hub 只读会话交换 → 5 小时／7 天／月度后台额度
      ├─ 当前 provider 与 Hub origin 匹配 → 有界本地 Codex 记录扫描
      │   └─ Token 小计、线程分类、活动速率估算、完整轮次均速
      └─ 已有系统信任下的可选 AX 兼容读取 → 独立界面快照
SwiftUI：概览、数据来源、偏好设置
```

后台额度、界面快照与本地记录各自保留来源语义。后台直接读取不受可选 AX 开关影响；目标退出或身份变化会失效旧结果，重新运行后再识别并读取。正式运行不启动旧代理、不改 Hub／Codex 连接配置，也不调用任意用户填写的企业 URL。

来源流程、计量边界、刷新时效与安全失败条件见 [设计说明](docs/DESIGN.md)。

## 文件与职责

| 位置 | 职责 |
| --- | --- |
| `Sources/TokenStatMenu/` | AppKit 菜单栏与弹出面板、SwiftUI 界面、来源调度、偏好存储与 AX 适配 |
| `Sources/TokenStatCore/` | 本地记录核算、后台额度交换与解析、窗口模型及旧协议回归组件 |
| `Resources/` | 应用元数据、图标与仅含可选偏好的示例 plist |
| `Tests/` | 纯合成核心检查、原生状态与界面快照测试 |
| `script/` | 原生构建、隔离集成、离线渲染、文档校验与源码导出 |
| `docs/wiki/` | 面向使用者、开发者和贡献者的专题指南 |
| `docs/DESIGN.md`、`docs/IMPLEMENTATION.md` | 设计细节、当前支持范围与剩余工作 |
| `docs/VALIDATION.md` | 有日期和范围的验证记录；历史通过不自动等于当前全部能力已验收 |
| `docs/FULL_SOURCE.md` | 由脚本生成的架构、分文件完整源码和构建说明，不手工编辑 |

## 构建与运行

在仓库根目录执行。构建不会按进程名关闭其他应用，打开新实例前应先退出旧版，避免误看另一份构建。

| 命令 | 结果 |
| --- | --- |
| `./script/build_and_run.sh --build-only` | 构建本机架构 Debug `.app`，不启动应用 |
| `./script/build_and_run.sh --universal` | 构建 arm64 与 x86_64 Release 通用 `.app`，不启动应用 |
| `./script/build_and_run.sh` | 构建并运行本机架构 Debug `.app` |
| `./script/build_and_run.sh --release` | 构建后运行本机架构 Release `.app`，不是只编译模式 |
| `swift build --force-resolved-versions -c release --product TokenStatMenu` | 按审核锁文件编译 SwiftPM 可执行目标；不会单独完成 `.app` 资源打包 |

也可打开 `TokenStatMenu.xcodeproj`，选择 TokenStatMenu Scheme 和 My Mac 编译。若默认开发目录仍指向 Command Line Tools，可只为当前命令选择完整 Xcode：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project TokenStatMenu.xcodeproj \
  -scheme TokenStatMenu \
  -configuration Release build
```

更多环境准备、图标资源、双架构、构建身份和常见错误见 [编译指南](docs/wiki/编译指南.md)；发布前检查与签名限制见 [CI/CD](docs/wiki/CI-CD.md)。

SwiftPM 构建和测试使用 `--force-resolved-versions`，只接受已提交的 `Package.resolved`。测试依赖在不同 Swift 工具链下会选择不同的兼容清单，锁文件包含这两条依赖图的审核版本；缺少必要 pin 或版本冲突时应停止，不能通过自动解析、构建后恢复锁文件或跳过源码一致性检查来掩盖。正式 App 的运行时依赖不因此增加。

## 验证与维护

```bash
# 纯合成核心检查
swift run --force-resolved-versions TokenStatCoreChecks

# 原生 XCTest 与界面回归
swift test --force-resolved-versions

# 核心、只构建及隔离启动集成
./script/test.sh

# 更新完整源码文档，并按白名单打包源码
python3 script/package_source.py

# 检查文档链接与公开内容
python3 script/check_docs.py
python3 script/check_public_content.py

# 发布资产合同（合成 Git/ZIP 与隔离的本机签名样本）
python3 -B script/test_release_assets.py
```

正式版本推送 `vMAJOR.MINOR.PATCH` 标签后，由 [macOS release 工作流](.github/workflows/release.yml) 检查版本、源码提交和 `main` 归属，构建 arm64 + x86_64 Universal App。当前 1.1.4 历史合同发布四项资产；从 1.1.5/build7 起，目标是五项资产：应用 ZIP、源码 ZIP、同一 App 的 Universal DMG、`release-manifest.json` 和 `SHA256SUMS`。构建检查与写入 Release 的作业分开授权；相同内容可安全重跑，不会覆盖不同内容的既有资产。DMG 只提供将 App 拖入“应用程序”的 Finder 包装，不声明 Developer ID 或公证。维护者步骤和失败恢复见 [CI/CD](docs/wiki/CI-CD.md)。

真实机器核验与合成测试分开记录；后者不能证明企业账号、完整账单或真实服务器吞吐正确。视觉参考图只使用合成数据，录制图像本身不算通过。详细方法见 [测试指南](docs/wiki/测试指南.md) 和 [UI 测试说明](docs/UI_TESTING.md)，最近的结果与限制见 [验证记录](docs/VALIDATION.md)。

## 隐私与开源

应用只读获取 Token Hub 必要的连接与现有登录材料，在内存中向其既有 HTTPS 来源交换短期会话并读取额度。它不会把令牌、账号、实际额度或响应正文写入正常日志、配置或源码仓库；本地会话文件在解析时可能短暂接触正文，但仅提取允许的计量和身份字段，不保存或上传正文。完整读取边界与开源检查方法见 [隐私说明](PRIVACY.md)。

采用 [MIT 许可证](LICENSE)。报告问题时只提交版本、状态描述、操作步骤和合成示例，不提交凭据、企业地址、账户数据库、会话正文或原始运行截图。贡献流程见 [贡献指南](docs/wiki/贡献指南.md)。

界面布局参考 codexU 的紧凑分组思路；文档组织参考 [TuPigGHD2Chinese](https://github.com/Tupig/TuPigGHD2Chinese) 的文档中心与专题导航，内容依据本项目的实际实现编写。
