# CI/CD

[返回文档中心](Home.md)

## 当前自动化范围

仓库的 [macOS build 工作流](../../.github/workflows/build.yml) 在 `main` 的 push 和 pull request 上运行，使用 `macos-15` runner。工作流仅有读取仓库内容的权限，checkout 关闭凭据持久化。当前 checkout 固定为官方 `v7.0.1` 的完整提交 `3d3c42e5aac5ba805825da76410c181273ba90b1`，其运行时为 Node 24；升级时重新核对官方 release/tag 与完整 SHA，不只移动标签。官方要求 Actions Runner 至少为 `v2.327.1`，自托管 runner 需同步满足此版本；GitHub 托管 runner 由平台维护。来源见 [checkout v7.0.1](https://github.com/actions/checkout/tree/v7.0.1)。

| 顺序 | 检查 | 当前实际覆盖 |
| --- | --- | --- |
| 1 | 文档链接与检查器自测 | `python3 script/check_docs.py --self-test` 检查本地链接/锚点，并用合成材料检查错误是否会被发现 |
| 2 | 公开内容防线 | 检查 Git index 中白名单文件的精确内容 |
| 3 | Release 校验器测试 | 虚构发布材料、路径/版本/摘要错误、无网络写入及私有原生包装 fixture |
| 4 | 核心与发现检查 | 运行 `TokenStatCoreChecks` 的合成回归 |
| 5 | 原生测试目标编译及不依赖 OS 像素的检查 | 凭据用途/URL 绑定的纯身份检查，以及刻意图像差异可被检测的检查 |
| 6 | Xcode Release 构建 | 使用明确绑定 App target 的共享 Scheme，禁用代码签名完成原生工程构建 |

CI 不比较受特定 macOS 渲染环境约束的工具栏基线，也不调用真实 Seasun 网关、不读取企业账号或本地会话。当前工作流不是完整 `swift test`、隔离 `script/test.sh`、Universal 构建或本机安装验收的替代。性能基准也不在 CI 中作为时间阈值运行，以免把共享 runner 的负载变化当作性能回归。

## CI 通过应怎样解读

CI 绿色说明该提交完成了工作流声明的检查，不能据此声称：

- 真实 Hub 登录、5 小时/7 天、重置时间或实时活动事件已在用户机器验证。
- 所有浅色/深色布局、自然键盘焦点和可访问性行为均通过。
- arm64 与 Intel 实机都运行成功。
- 已生成可下载 Release、完成 Developer ID 签名或 Apple 公证。
- 正在运行的 App 与该提交构建产物一致。

每项交付报告都应把本地测试、CI、真实环境、安装和发布证据分别写清楚。

## 本地到推送的建议流程

1. 用合成数据复现问题，为确认的问题建立或关联 Issue。
2. 实现最小改动，执行与改动相符的核心、状态或视觉验证。
3. 按 [测试指南](测试指南.md) 完成本地回归、原生构建及必要的真实本机验收。
4. 更新文档、公开文件白名单与完整源码汇编，检查差异及隐私边界。
5. 审阅暂存内容并执行 `check_public_content.py --git-index`，本地验证完成后再推送。
6. 创建可审查的 PR，写明问题、最终行为、测试结果和未覆盖范围；等待该提交的 CI 结果。

## 标签触发的正式 Release

[macOS release 工作流](../../.github/workflows/release.yml) 在 `v*` 标签 push 时运行。宽触发模式不是版本校验：发布工具仍只接受数字稳定版本 `vMAJOR.MINOR.PATCH`，核对 Info.plist 的版本/构建号、标签实际提交、干净工作区及 `main` 祖先关系。分支名不能代替源码提交。

流水线分成 `build` 与 `publish` 两个 job：

| 阶段 | 权限与实际动作 |
| --- | --- |
| `build` | `macos-15`、仓库只读；运行公开内容/文档/核心及指定原生检查，构建 Xcode 工程，再构建并 ad hoc 签名 Universal App；导出白名单源码并要求生成文档没有未提交差异；创建和核验四个资产后上传 Actions artifact |
| `publish` | Ubuntu，仅此 job 有 `contents: write`；下载同一 run 的 artifact，再次按源码、版本、结构、摘要核验；只对固定主仓库的该标签处理 Release，支持继续匹配的草稿，远端逐个核验后才公开 |

正式 Release 恰好包含以下四个手动上传资产，GitHub 自动提供的 Source code 归档不属于这四项：

| 文件 | 用途 |
| --- | --- |
| `TokenStatMenu-<版本>-universal.zip` | 包含 arm64 与 x86_64 的原生 App |
| `TokenStatMenu-<版本>-source.zip` | 显式白名单导出的源码、原生工程和资源，统一 `TokenStatMenu/` 根目录 |
| `release-manifest.json` | 版本、构建、标签、40 位公开提交，以及两个 ZIP 的文件名、字节数和 SHA-256 |
| `SHA256SUMS` | 三行排序校验和，覆盖两个 ZIP 和 manifest，不包含自身摘要 |

应用包检查版本/架构、图标、Info/二进制/图标/签名四个文件和严格签名。源归档检查白名单及路径/类型/摘要。校验器不会因资产已经存在就直接成功；已有资产内容冲突会失败，不覆盖未知发布材料。工具的入口和边界见 [release_assets.py](../../script/release_assets.py) 与 [对应合成测试](../../script/test_release_assets.py)。

App 使用 **ad hoc 签名**，没有配置 Developer ID 证书或 Apple 公证。资产摘要和 Git 提交用于核对完整性与来源，不是 Apple 信任证明，也不能证明用户机器上的企业链路可用。工作流不安装 App 到用户目录，不自动启动应用、不操作企业服务或系统权限。

首次正式标签、Actions 实际完成、四资产下载核验及安装验收需分别记录在 [验证记录](../VALIDATION.md)。工作流文件存在、合成检查通过或草稿已创建，都不能直接称为发布完成。

## Homebrew 源码安装和自动跟进

独立 [Homebrew tap](https://github.com/Tupig/homebrew-tokenstatmenu) 使用正式 Release 的**源码 ZIP**。Formula 以完整 Xcode 15+ 的原生工程构建主机架构，安装在 Homebrew 的 `libexec`，生成无参数的 `tokenstatmenu` 启动器；不通过 SwiftPM 下载测试依赖。它在最终安装位置 ad hoc 签名，并写入 Release 提交及 `release-source` 来源状态。

tap 的定时/手动更新有三个阶段：只读 `check` 核验公共 Release；只读 macOS `smoke` 重建同一候选，执行单元检查、`brew style`、`brew audit`、真实源码安装和 `brew test`；最后 Ubuntu `publish` 再核对全部候选字段和旧 Formula Git blob SHA，仅改写本 tap 的 Formula 文件。无版本、不变、降级、同版本冲突、测试失败或并发变更均不会强行更新。

公开下载不用企业凭据或跨仓库 PAT。仅最后的 job 使用 tap 自身的 `GITHUB_TOKEN`，写入前不执行下载的应用源码。GitHub token 产生的提交通常不会再次触发普通 push CI，因此同一工作流中的 macOS 测试必须先完成。相关平台规则见 [GitHub 工作流触发说明](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow)。

该机制更新的是公开 Formula；用户仍需 `brew update` / `brew upgrade`，且先退出旧 App。安装命令、Xcode 前提和回退方式见 [安装与使用](安装与使用.md)。实际正式 Release 下载、两版本隔离升级和最终公开 tap 安装分别验收，不用合成下载或本地 URL 适配替代公开端点验证。

相关页面：[测试指南](测试指南.md) · [编译指南](编译指南.md) · [贡献指南](贡献指南.md) · [验证记录](../VALIDATION.md)
