# 安全政策 / Security Policy

## 中文

### 范围与安全边界

本政策覆盖本仓库中的 macOS 主应用、Widget、共享快照、构建和发布脚本。排查时请注明受影响的版本和构建号；当前源码与发布版本可能不同。

应用会读取本机 Seasun Token Hub 的连接信息和登录态，并请求该 Hub 配置的服务；Widget 通过 App Group 读取共享快照。服务响应、本机文件及其路径均需按不可信输入处理。安全审查应关注凭据泄露、未经授权的数据访问或修改、不安全的网络请求，以及共享快照的越权读取、替换和解析。

凭据不应写入偏好、共享快照或日志；共享快照不应包含会话正文或原始服务响应。App Group 是否可用取决于实际签名和系统授权；文件所有权检查不能单独证明文件由哪个进程创建。开发签名包的跨设备运行与 Widget 授权不等于已验证的正式分发。

### 报告漏洞

请使用 [GitHub 私密漏洞报告](https://github.com/Tupig/TokenStatMenu/security/advisories/new)，不要在公开 Issue 中披露未修复的安全问题。请提供版本、系统环境、影响范围、最小复现步骤，以及可用的合成或脱敏证据。

不要提交令牌、密钥、数据库、企业地址、个人信息、真实服务响应、会话内容、原始日志或未遮挡的截图。常规非安全问题可按 README 的说明反馈。

## English

### Scope and security boundaries

This policy covers the macOS app, Widget, shared snapshots, and build and release scripts in this repository. Include the affected version and build: the current source and published releases may differ.

The app reads connection details and an existing session from the local Seasun Token Hub and queries the service configured by that Hub. The Widget reads a shared snapshot through an App Group. Treat service responses, local files, and their paths as untrusted inputs. Security review should consider credential disclosure, unauthorized data access or modification, unsafe network requests, and unauthorized snapshot reads, replacement, or parsing.

Credentials must not be written to preferences, shared snapshots, or logs; shared snapshots must not contain conversation text or raw service responses. App Group availability depends on actual signing and system authorization. File ownership checks alone do not establish which process created a file. Cross-device execution and Widget authorization for development-signed builds are not evidence of verified production distribution.

### Reporting a vulnerability

Use [GitHub private vulnerability reporting](https://github.com/Tupig/TokenStatMenu/security/advisories/new); do not disclose an unpatched security problem in a public issue. Include the version, system environment, impact, minimal reproduction steps, and synthetic or redacted evidence where possible.

Do not submit tokens, keys, databases, enterprise addresses, personal information, real service responses, conversation content, raw logs, or unredacted screenshots. Report ordinary non-security issues using the README instructions.
