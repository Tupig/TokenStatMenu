# CI/CD

**简体中文** | [English](#cicd-english)

[文档中心](Home.md) · [编译指南](编译指南.md) · [测试指南](测试指南.md)

## CI 检查

[ci.yml](../../.github/workflows/ci.yml) 在 main push、PR 和 `v*` 标签上运行：文档链接、公开内容、发行契约、CoreChecks、状态/UI 测试、Xcode Release 构建和依赖锁未变检查。部分依赖 macOS 渲染的像素测试不在 CI 比较，本机仍运行完整套件。

普通 job 只有读权限。动作固定到完整提交，SwiftPM 使用 `--force-resolved-versions`。CI 不读用户 Hub/Codex 数据，不请求权限，不证明真实小组件或企业链路可用。

## 1.1.7 发布约定

只支持 Apple Silicon（M 系列）。App 和扩展均为 arm64，Bundle 版本/build 同步。文件名使用仓库名，不重复版本和架构：

| 资产 | 用途 |
| --- | --- |
| `TokenStatMenu.zip` | 原生 `TokenStatMenu.app`，含小组件扩展 |
| `TokenStatMenu-source.zip` | 白名单源码、工程、资源、测试和文档 |
| `TokenStatMenu.dmg` | 同一 App 与 Applications 别名 |
| `release-manifest.json` | 标签、提交、版本/build、文件大小和 SHA-256 |
| `SHA256SUMS` | App ZIP、源码 ZIP、DMG 与 manifest 的摘要 |

版本在 Release 标签及 App 元数据中，不在资产名中。旧 Release 保留原文件名与校验规则，不回写历史资产。

## 本地发布

先完成回归、提交并推送 main，等待对应 CI 通过，再固定 `v1.1.7` 标签。发布构建不得带工作区改动：

```bash
TAG=v1.1.7
COMMIT=$(git rev-parse HEAD)
TOKENSTAT_WIDGET_GROUP=<已配置的组名> ./script/build_and_run.sh --arm64
python3 -B script/release_assets.py preflight --tag "$TAG" --commit "$COMMIT"
python3 -B script/package_source.py
python3 -B script/release_assets.py package --tag "$TAG" --commit "$COMMIT" --app dist/TokenStatMenu.app --source dist/TokenStatMenu-source.zip --directory dist/release
python3 -B script/release_assets.py verify --tag "$TAG" --commit "$COMMIT" --directory dist/release
python3 -B script/release_assets.py publish --tag "$TAG" --commit "$COMMIT" --directory dist/release
```

`preflight` 核对标签、HEAD、origin/main 和干净源码；`package/verify` 检查精确文件树、两个可执行文件的 arm64、版本、组名和签名。DMG 用只读挂载检查，随后卸载。`publish` 上传后回读远端字节，匹配才公开；冲突不覆盖，不用 `--clobber`。

完成后确认 Releases 列表中非草稿可见，五项资产能下载且摘要一致。只有本地文件或草稿不算发布完成。

## 可选云端发布

默认关闭。设置 `TOKENSTAT_CLOUD_RELEASE=enabled` 并配置 `TOKENSTAT_WIDGET_GROUP` 后，标签 push 才运行构建和 publish。不要同时本地、云端出同版包。只有 publish job 有 `contents: write`，回读验证后才公开。

公开构建采用 ad hoc 签名，未做 Developer ID/公证；App Group 字符串和签名检查不能代替 Apple 授权。小组件分发仍受 [#88](https://github.com/Tupig/TokenStatMenu/issues/88) 限制。

## Homebrew 跟进

[Tap](https://github.com/Tupig/homebrew-tokenstatmenu) 从正式 Release 获取源码 ZIP，先核验身份和摘要，再构建、`brew style/audit/test`，最后更新 Formula。1.1.7 起要求 arm64，并检查主 App 和内嵌扩展的版本、签名和文件树。旧版模板保留兼容，避免读不了现有配方。

Tap 的自动检查、测试与写入分开。配方更新后用户仍需 `brew update` 和 `brew upgrade`；要实测已有安装升级，不能只看自动 check 的“无变化”。

## 文档和 Wiki

README 与 `docs/wiki/` 随源码发布。GitHub Wiki 是独立仓库，首次未初始化时需要先创建 Home；同步时处理 Wiki 页面与仓库源码链接的区别。未确认远端可读前，不在报告中写“Wiki 已同步”。

---

# CI/CD (English)

[简体中文](#cicd) | **English**

[Documentation](Home.md#documentation-hub-english) · [Build](编译指南.md#build-guide-english) · [Testing](测试指南.md#testing-guide-english)

## CI Checks

[ci.yml](../../.github/workflows/ci.yml) runs on main pushes, PRs and `v*` tags. It checks docs, public content, release contracts, CoreChecks, state/UI tests, Xcode Release assembly and an unchanged dependency lock. Some renderer-dependent image comparisons are local-only.

Normal jobs are read-only. Actions use full commit pins; SwiftPM uses `--force-resolved-versions`. CI does not access user Hub/Codex data or establish real Widget/service acceptance.

## Version 1.1.7 Contract

Apple Silicon (M-series) only. App and widget are arm64 with matching version/build. Asset names follow the repository name:

| Asset | Purpose |
| --- | --- |
| `TokenStatMenu.zip` | Native App with embedded widget |
| `TokenStatMenu-source.zip` | Allowlisted code, project, resources, tests and docs |
| `TokenStatMenu.dmg` | The same App plus Applications alias |
| `release-manifest.json` | Tag, commit, version/build, sizes and digests |
| `SHA256SUMS` | Digests of the three archives/image and manifest |

The tag and bundle metadata carry the version, not the asset filename. Older Releases retain their original names and checks.

## Local Publication

Test, commit and push main, wait for its CI, then fix the `v1.1.7` tag. Build from clean committed source:

```bash
TAG=v1.1.7
COMMIT=$(git rev-parse HEAD)
TOKENSTAT_WIDGET_GROUP=<configured-group> ./script/build_and_run.sh --arm64
python3 -B script/release_assets.py preflight --tag "$TAG" --commit "$COMMIT"
python3 -B script/package_source.py
python3 -B script/release_assets.py package --tag "$TAG" --commit "$COMMIT" --app dist/TokenStatMenu.app --source dist/TokenStatMenu-source.zip --directory dist/release
python3 -B script/release_assets.py verify --tag "$TAG" --commit "$COMMIT" --directory dist/release
python3 -B script/release_assets.py publish --tag "$TAG" --commit "$COMMIT" --directory dist/release
```

Preflight checks tag, HEAD, origin/main and clean source. Packaging checks the exact file tree, both arm64 executables, version, group and signatures. DMG checks use read-only mounts. Publish reads remote assets back before making the Release public; mismatches fail without clobbering.

Confirm a public, non-draft entry and five downloadable matching assets. A local package or draft alone is not a completed release.

## Optional Cloud Publication

Disabled by default. Enable `TOKENSTAT_CLOUD_RELEASE=enabled` with `TOKENSTAT_WIDGET_GROUP` to run tag-triggered build/publish. Do not build the same release locally and in the cloud. Only the publish job gets write permission.

Public builds are ad hoc signed, not Developer ID signed or notarized. Entitlement checks do not grant App Group authorization; [#88](https://github.com/Tupig/TokenStatMenu/issues/88) remains relevant.

## Homebrew Follow-up

The [Tap](https://github.com/Tupig/homebrew-tokenstatmenu) validates the official source archive, then builds and runs style/audit/test before publishing a formula change. Version 1.1.7 onward requires arm64 and validates the embedded extension too. Historical templates remain compatible with existing pins.

Check, smoke testing and writes are separate. Users still run `brew update` and `brew upgrade`. Test an actual installed-version upgrade; a successful no-change check is insufficient.

## Documentation and Wiki

README and `docs/wiki/` ship with source. GitHub Wiki is a separate repository and may need an initial Home page. Convert links appropriately when syncing. Do not report synchronization before confirming public readability.
