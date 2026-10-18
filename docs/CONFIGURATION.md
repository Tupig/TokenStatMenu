# 可选偏好

[返回文档中心](wiki/Home.md)

## 无需配置即可使用

正式 App 仅面向 Seasun Token Hub。默认启动自动发现本机已运行、已登录的 Hub，读取必要的既有连接与会话材料，在内存中完成只读额度交换。无需填写接口、API Key、模型、价格或手工额度，也无需创建 plist。

没有登录、会话过期、入口不可用或响应无法核验时，界面如实显示未知或不可用，不回退到旧配置里的任意 API。直接来源不依赖辅助功能权限；界面兼容读取是可选补充。

## 在设置页调整

点击菜单栏打开面板，再点击右上角设置按钮。改动后选择“保存偏好”写入；“重新加载偏好”只重新读取文件。保存失败时保留原内存设置并显示通用错误，不展示原始路径或系统错误。

| 偏好键 | 设置项 | 默认值 | 合法范围与效果 |
| --- | --- | --- | --- |
| `refreshSeconds` | 刷新秒数 | `60` | 15–3600 秒的有限数值；非法类型、布尔值、非有限数值或越界值回到 60 |
| `tokenHubCompatibilityReadEnabled` | Token Hub 界面兼容读取 | `true` | 必须是 Boolean；仅控制辅助功能界面快照，关闭不停止企业后台直接来源 |

刷新偏好用于 Hub 自动刷新与快照时效；并不把本地事件变成逐 Token 数据。当前本地记录采用独立的有界刷新调度。实时估算在最后活动事件超过 15 秒后失效，与 Hub 刷新间隔无关。

界面兼容读取仅在已有系统信任且目标额度区域可访问时尝试，不自动弹出权限提示。需要使用时，用户可主动点击“请求辅助功能访问…”。该权限不用于企业后台交换，详见 [常见问题](wiki/常见问题.md)。

## 可选 plist

默认文件位置为本用户的：

```text
~/Library/Application Support/TokenStatMenu/config.plist
```

示例见 [Resources/config.example.plist](../Resources/config.example.plist)。手工维护时只需两项：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>refreshSeconds</key>
    <real>60</real>
    <key>tokenHubCompatibilityReadEnabled</key>
    <true/>
</dict>
</plist>
```

无需复制这个例子；界面保存会创建所需目录并原子写入。启动或重新加载不会写文件，缺失文件保持缺失。`--config <path>` 可在开发时选择隔离偏好位置，见 [命令行参数](wiki/命令行参数.md)。

## 旧配置如何处理

| 输入情况 | 行为 |
| --- | --- |
| 新的兼容读取键存在且是 Boolean | 使用新键，优先于旧键 |
| 新键不存在 | 允许旧 `tokenHubAutomaticReadingEnabled` 作为兼容偏好读取 |
| 新键存在但类型错误 | 使用默认 `true`，不再回退旧键 |
| 旧 API、代理、endpoint、模型、价格、配额或密钥字段 | 忽略；不启动旧代理、不访问旧接口、不读取已保存密钥 |
| 损坏 plist、非字典根、无文件 | 使用安全默认偏好 |
| 偏好文件读取/保存失败 | 保留已接受的运行状态，显示安全错误；不发出替代 API 请求 |

启动和重新加载保持旧文件原样。用户主动保存后，文件只包含两项允许偏好，旧接入字段会移除。若要保留历史配置作为私人备份，应由用户在仓库外管理，不提交到公开项目。

## 开发隔离与日志

`--disable-background-services` 关闭本地扫描、Hub 直接读取、辅助功能读取、观察者和计时器，用于隔离验证；不是正常使用选项。`--test-fixture` 单独使用不能替代这个隔离开关。

当前正式设置没有统计日志开关、真实数据导出、价格或币种切换。`--diagnostics-output` 只生成本机就绪状态和资源计数，不提供 Token/额度导出；构建脚本的 `--logs` 是本机统一日志查看，不是远程遥测。详情见 [命令行参数](wiki/命令行参数.md)。

相关页面：[安装与使用](wiki/安装与使用.md) · [统计口径](wiki/统计口径.md) · [常见问题](wiki/常见问题.md) · [隐私说明](../PRIVACY.md)
