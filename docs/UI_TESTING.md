# UI 快照检查

`TokenStatUITests` 使用固定的合成 `AppModel(preview: true)`，对真实 `DashboardView` 的工具栏和设置页工具栏截图。4 张 PNG 只包含应用标题、中文标题和工具栏图标，不使用用户屏幕截图或本机配置。SnapshotTesting 1.19.6 仅是 SwiftPM 测试目标的依赖；应用目标和 TokenStatCore 均不链接该库。

运行视觉检查：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter TokenStatUISnapshotTests
```

普通测试显式使用 `.never` 记录模式；缺少基线时会失败，不会自动生成。只有在确实要创建或替换基线时才设置 `TOKENSTAT_RECORD_SNAPSHOTS=1`：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer TOKENSTAT_RECORD_SNAPSHOTS=1 swift test --filter TokenStatUISnapshotTests.testDashboardLightAndDark
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer TOKENSTAT_RECORD_SNAPSHOTS=1 swift test --filter TokenStatUISnapshotTests.testSettingsLightAndDark
```

记录模式会写出 PNG，并按设计让测试失败。接受前须逐张检查。当前基线在 macOS 27.0.1、Xcode 27.1 和 Retina 2x 显示环境下生成；请在相同 macOS 版本、显示比例和系统字体/渲染环境中进行比较。系统或渲染环境变化可能导致像素差异，须人工审核，不能自动接受。仓库 CI 使用 macOS 15，只编译并运行不依赖操作系统版本的检查，不比较这些基线。内存中的图像差异检查用于确认改变像素会触发匹配失败，不会写入基线。快照只覆盖外观，不能证明点击或辅助功能行为。自然键盘焦点诊断未成为 key window，因此仍未验证；这里的快照也不代表自然焦点状态。


## 专用设置页的完整内容检查

专用启动测试使用正式 AppModel 配合临时偏好及关闭后台服务的注入配置，不访问真实会话、网关或系统辅助功能。它从真实 NSHostingView 生成合成 bitmap，再用系统 Vision 的中英文识别检查来源、刷新与兼容选项可见，同时排除旧的通用 API 设置与误导连接文案。Vision 只用于测试，不进入应用运行时。

原可访问性树遍历在测试环境中未取得可见文字，已保留为待核验问题；OCR 通过不等于辅助功能行为通过。完整浅色/深色图片还需要独立检查可见内容、留白与布局，不能仅凭 PNG 文件非空判定成功。公开快照仍只包含经审阅的合成工具栏，不包含真实屏幕或账户数据。
