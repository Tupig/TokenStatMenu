# 项目文档

安装、使用、构建与测试说明统一见 [文档中心](wiki/Home.md)。数据处理方式见 [隐私说明](../PRIVACY.md)。

## 目录

| 路径 | 用途 |
| --- | --- |
| `Sources/` | 核心逻辑、菜单栏应用、Widget 及独立开发探针 |
| `Tests/` | 核心检查、界面回归、Widget 协议测试与图像基线 |
| `Resources/` | 图标、Info.plist、签名权限与配置示例 |
| `script/` | 构建、测试、预览、打包与发布工具 |
| `TokenStatMenu.xcodeproj/` | 原生应用及扩展的 Xcode 工程 |
| `docs/wiki/` | 使用与维护指南 |
| `.build/` | 可重新生成的构建缓存，不提交 |
| `dist/` | 本机构建与打包产物，不提交 |

实现细节见 [实现范围](IMPLEMENTATION.md)、[设计说明](DESIGN.md) 和 [性能与基准](PERFORMANCE.md)。测试结果见 [验证记录](VALIDATION.md)。

相关页面：[项目首页](../README.md) · [文档中心](wiki/Home.md)
