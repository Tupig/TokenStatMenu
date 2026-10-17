# 可选偏好说明

正式 App 仅面向 Seasun Token Hub；无需填写接口、密钥、模型、价格或额度。当前直接企业统计源尚未完成，填写旧配置也不能使它接通。界面会如实显示未知或不可用。

不需要创建 plist。默认刷新间隔为 60 秒，界面快照兼容读取开关为开启；后者只在系统已有信任且目标额度区域可访问时读取，不自动弹出权限提示。它仍是可选兼容方式，不是安装即用的验收结果。

仅支持两项可选偏好：

| 键 | 默认值 | 规则 |
| --- | --- | --- |
| `refreshSeconds` | `60` | 有限数值，15 至 3600 秒；其他输入回到默认 |
| `tokenHubCompatibilityReadEnabled` | `true` | Boolean；关闭只停用兼容界面读取 |

示例位于 `Resources/config.example.plist`。配置存放在应用自己的 Application Support 目录。无需复制示例；设置页可主动保存偏好。

旧 `tokenHubAutomaticReadingEnabled` 仅在新键不存在时作为兼容偏好读取。新键存在但不是 Boolean 时使用 `true`，不回退到旧键。旧 API、代理、价格和配额字段被忽略，错误 endpoint 不会阻止启动；损坏 plist 或非字典输入使用默认偏好。启动和重新加载不会写文件，主动保存才原子替换为两项允许的偏好，旧接入字段随之移除。保存失败保持原有内存状态并显示通用错误。

`--config <path>` 供开发时选择隔离偏好文件；`--disable-background-services` 供隔离启动验证，禁止自动本地扫描、AX 信任/读取、通知观察者和计时器。两者都不是用户正常使用的前置步骤。不要把 `--diagnostics-output` 的测试就绪输出当作统计来源。
