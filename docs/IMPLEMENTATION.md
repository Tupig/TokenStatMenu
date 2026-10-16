# 实现计划

目标：可构建、可验证的轻量原生菜单栏吞吐量监控器。规格见 DESIGN.md。

1. 核心计算：RateWindow、StreamParser、UsageDecoder、MetricsEngine。先验证窗口过期、UTF-8 拆包、usage 校正、不重复累计、月度字段解析测试，再实现。
2. 网络：HTTPDecoder 处理 Content-Length/chunked 与大小上限；ProxyServer 仅绑定 127.0.0.1，URLSession delegate 增量转发。用本地 mock 上游验证流式、非流式、错误、并发、客户端取消。
3. 应用：ConfigStore、Keychain、AppModel、StatusBarController、DashboardView、SettingsView。菜单栏 2Hz 更新；面板使用系统颜色；无启动弹窗。
4. 配额和日志：独立密钥/接口、字段映射、超时和过期状态；脱敏 JSONL、轮转和导出。
5. 交付：Swift Package、plist、脚本、中文文档、完整源码合集。核心检查程序、双架构构建、实际 AppKit 状态与代理联测后记录验证结果。

6. 本地自动发现：先测试 provider/profile 选择、私有路径保留、敏感 URL 拒绝、多行内容隔离及读取上限；再接入设置页。公开仓库从文件清单构建，不包含本地运行配置、日志或企业实例信息。
