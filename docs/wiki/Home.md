# TokenStatMenu 文档中心

**简体中文** | [English](#documentation-hub-english)

[项目首页](../../README.md) · [下载](https://github.com/Tupig/TokenStatMenu/releases) · [问题反馈](https://github.com/Tupig/TokenStatMenu/issues)

TokenStatMenu 在菜单栏、面板和小组件中展示 Seasun Token Hub 额度。仅支持 Apple Silicon（M 系列）。普通使用只需先登录 Hub，无需填写接口或密钥。

## 快速开始

```bash
brew install Tupig/tokenstatmenu/tokenstatmenu
tokenstatmenu
```

当前公开版本是 [1.2.1](https://github.com/Tupig/TokenStatMenu/releases/tag/v1.2.1)。1.1.5 已淘汰，不要安装。Homebrew 需要完整 Xcode 15+，从 Release 源码包编译；正式小组件嵌在同一个 App 里。更新步骤见[安装与使用](安装与使用.md)。

## 文档导航

| 使用者 | 内容 |
| --- | --- |
| [安装与使用](安装与使用.md) | Homebrew 安装、更新、卸载、偏好与小组件 |
| [统计口径](统计口径.md) | 金额、百分比、本地 Token、速度与未知值 |
| [常见问题](常见问题.md) | 无数据、不同步、签名与多副本排查 |

| 开发者 | 内容 |
| --- | --- |
| [编译指南](编译指南.md) | SwiftPM、Xcode、签名与 arm64 发布 |
| [命令行参数](命令行参数.md) | App 参数、脚本模式和环境变量 |
| [测试指南](测试指南.md) | 回归、图像基线、安装与升级验证 |
| [CI/CD](CI-CD.md) | 无签名构建、GitHub Release 与 Homebrew 配方 |
| [贡献指南](贡献指南.md) | 修改流程、双语文档与隐私要求 |

文档只保留根 README 和 `docs/wiki/`，每页先中文、后英文。数字和命令以源码为准；当前发布版本以 Releases 和 Homebrew 配方为准。

---

# Documentation Hub (English)

[简体中文](#tokenstatmenu-文档中心) | **English**

[Project](../../README.md#tokenstatmenu-english) · [Downloads](https://github.com/Tupig/TokenStatMenu/releases) · [Issues](https://github.com/Tupig/TokenStatMenu/issues)

TokenStatMenu shows Seasun Token Hub quotas in the menu bar, panel and widget. Apple Silicon (M-series) only. Sign in to Hub first; no endpoint or API Key entry is needed.

## Quick Start

```bash
brew install Tupig/tokenstatmenu/tokenstatmenu
tokenstatmenu
```

The current public release is [1.2.1](https://github.com/Tupig/TokenStatMenu/releases/tag/v1.2.1). Version 1.1.5 is retired and must not be installed. Homebrew needs full Xcode 15+ and builds from the Release source archive. The shipping widget is embedded in that same App. See [Installation](安装与使用.md#installation-and-usage-english) for upgrades.

## Documentation

| For Users | Contents |
| --- | --- |
| [Installation and Usage](安装与使用.md#installation-and-usage-english) | Homebrew install, upgrade, uninstall, preferences and widget |
| [Metric Definitions](统计口径.md#metric-definitions-english) | Amounts, percentages, local Tokens, rates and unknown values |
| [FAQ](常见问题.md#faq-english) | Missing data, stale widgets, signing and duplicate copies |

| For Developers | Contents |
| --- | --- |
| [Build Guide](编译指南.md#build-guide-english) | SwiftPM, Xcode, signing and arm64 releases |
| [CLI Options](命令行参数.md#cli-options-english) | App arguments, script modes and environment |
| [Testing Guide](测试指南.md#testing-guide-english) | Regressions, image references, install and upgrade checks |
| [CI/CD](CI-CD.md#cicd-english) | Unsigned build, GitHub Release and Homebrew formula |
| [Contributing](贡献指南.md#contributing-english) | Workflow, bilingual docs and privacy |

Documentation lives only in the root README and `docs/wiki/`. Each page has Chinese first and English second. Source code defines behavior; Releases and the Homebrew formula identify what is publicly available.
