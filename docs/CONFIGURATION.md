# 配置说明

默认配置文件：`~/Library/Application Support/TokenStatMenu/config.plist`。
设置面板保存后生成；也可以复制 `Resources/config.example.plist` 到此位置，再点“重新加载 plist”。
启动参数 `--config /absolute/path/config.plist` 可选择独立配置；它的日志也放在同级 `Logs` 目录。
缺少字段会采用默认值；类型错误或非法 URL/端口会明确报错，不会静默覆盖旧配置。

密钥不写 plist：菜单设置中的推理 Key、企业用量 Key、本机访问令牌存入专用 Keychain service `com.tupig.TokenStatMenu`。
自动化环境可以使用 `TOKENSTAT_API_KEY`、`TOKENSTAT_USAGE_KEY`、`TOKENSTAT_LOCAL_KEY` 覆盖启动时读取值；不要把真实密钥提交到源码或测试脚本。

| 字段 | 默认值/单位 | 说明 |
|---|---|---|
| endpoint | Ollama 本机 Chat 完整 URL | 支持额外路径前缀 |
| model | 空 | 空则保留客户端模型；非空统一覆盖 |
| port | 18765 | 监听 127.0.0.1，范围 1024–65535 |
| includeUsage | true | 给 Chat 流请求合并 `stream_options.include_usage` |
| allowInsecureHTTP | false | 远程 HTTP 必须显式开启；本机 HTTP 默认允许 |
| inputPrice / outputPrice | 0 USD/百万 Token | 使用请求开始时的单价，0 表示尚未设置 |
| currency | USD | USD 或 CNY |
| usdToCNY | 7.0 | 手填参考汇率，不是实时汇率 |
| monthlyLimit | 0 token | 大于 0 覆盖接口总量；0 使用接口总量 |
| usageURL | 空 | 企业月度 Token 接口 GET URL |
| usedPath | data.used_tokens | 数值或可解析数值字符串 |
| limitPath | data.total_tokens | 可留空配合手动上限 |
| periodPath | data.month | 需等于本地本月 yyyy-MM；留空信任接口的本月定义 |
| refreshSeconds | 60 秒 | 15–3600；禁止重叠请求 |
| loggingEnabled | false | 脱敏 JSONL 请求统计 |
| historyEnabled | true | 10 分钟内存曲线 |

样例响应：

```json
{
  "data": {
    "used_tokens": 850000,
    "total_tokens": 1000000,
    "month": "2026-10"
  }
}
```

月份必须改为实际当前月份。该示例得到剩余 150000 Token、使用率 85%，触发黄色标题。
点分路径也支持数组下标，例如 `data.projects.0.used_tokens`。
设置中的 Key 会以 `Authorization: Bearer ...` 发出。需要 Cookie、SSO 签名或自定义请求头的企业接口不属于自动适配范围：应先由企业侧提供一个返回上述 Token 字段的授权适配接口，不能在此冒充已接入。

每次请求超时上限约 20 秒，响应上限 1MB；不跟随重定向。接口失败时保留上次成功值并显示错误；超过 `max(120 秒, 2 × 刷新间隔)` 标记过期；跨月清空旧月数据等待重取。配额统计以系统本地月为界，如企业采用 UTC，应由接口适配返回明确的当前周期。

模型调用入口支持 Content-Length 与 chunked 编码，正文上限 8MB、header 64KB。HTTP `Expect`、重复 header、模糊 Content-Length/Transfer-Encoding 组合会被拒绝。只支持文本/JSON 请求，不是全功能通用 HTTP 代理。

上游 Header 由应用生成，不转发调用方 Bearer，也不任意转发其他 Header。上游只接受固定配置 Endpoint；TLS 校验保持系统默认，不禁用证书验证。`Info.plist` 允许传输层 HTTP 是为本机 Ollama 和用户显式允许的企业内网服务，应用层仍校验远程 HTTP 开关。

如果要求精确的实时 tok/s，企业网关需实时返回已生成 token 计数，或者项目需加入与模型匹配的 tokenizer。标准 OpenAI SSE 文本本身不保证携带此信息；本版本选择轻量、无第三方 tokenizer，并明确标记估算。

测试与真实数据必须分开：本地联测使用独立 plist、日志目录和纯测试令牌，并携带 `--test-fixture` 启动参数。此时菜单栏与面板显示“测试 / 模拟测试”。移除参数不会验证上游是否真实；不要将模拟接口配置用于日常运行。正常首次启动若尚无请求，标题为 `T:—`、累计为 `—`。

## 本机自动发现

自动读取已知 Codex 配置位置中的非认证字段，也可重新扫描。来源路径只显示 `~/.codex/config.toml` 或 `$CODEX_HOME/config.toml` 标签。选择候选后会填入准确的 Endpoint 和当前 provider 的模型，手动保存生效。不会读取 `auth.json`、API Key 字段、Cookie、请求头值、其他应用的钥匙串或 SSO 会话。

例如 Codex 中 `base_url = "https://gateway.example/airoute"` 与 `wire_api = "responses"` 会生成 `https://gateway.example/airoute/responses`，不会额外插入 `/v1`。使用 `https://gateway.example/v1` 则保留 `/v1`。对活动 profile 的 model/provider 覆盖优先于根配置。复杂 TOML 形式或重复值会被跳过；仍可手动填写。

`--disable-discovery` 可在本次启动禁用发现。不使用定时文件扫描，不发网络探测，不上报发现结果。发现与手动录入一样，都无法在没有认证信息的情况下访问受保护的接口。
