# CI/CD

**简体中文** | [English](#cicd-english)

[文档中心](Home.md) · [编译指南](编译指南.md) · [测试指南](测试指南.md)

## CI 检查

[ci.yml](../../.github/workflows/ci.yml) 在 main push、PR 和 `v*` 标签上运行：文档链接、公开内容、发行契约、CoreChecks、状态/UI 测试、Xcode Release 构建和依赖锁未变检查。部分依赖 macOS 渲染的像素测试不在 CI 比较，本机仍运行完整套件。

普通 job 只有读权限。动作固定到完整提交，SwiftPM 使用 `--force-resolved-versions`。CI 不读用户 Hub/Codex 数据，不请求权限，不证明真实小组件或企业链路可用。

### 构建加速与边界

- main/PR 同一 ref 的新运行取消过时运行；标签运行不因此取消。
- 第一次 Swift 测试完成构建，后续测试用 `--skip-build` 复用同一工作区产物；前置三项筛选及完整套件仍全部执行，锁文件检查保留。
- 两个开发 Debug 原生检查串行共享专用 DerivedData；正式 Release 使用独立目录，不用 Debug 代替 Release，不复用外部缓存的发布二进制。
- 首轮不引入跨运行缓存或多 job 拆分。记录各步骤和总耗时，与成功运行基线比较，不把排队减少或一次快跑当作稳定收益。跟踪 [#93](https://github.com/Tupig/TokenStatMenu/issues/93)。

### Widget 按需 OCR 测试边界

`WidgetEntryViewTests` 保留浅/深色共 20 次实际 `WidgetEntryView` 的合成 `NSHostingView` 离屏位图渲染。每次仍执行关闭语言纠正的整图 OCR；全部数值、券数量和旧值泄露断言只使用该次整图 top-1，不使用补救候选替代。

中文标签先使用整图真实 top-10 候选，只有所需标签尚缺时，才依次对实际中文行区域执行原尺寸和半尺寸、开启系统语言纠正的 OCR；标签齐全即停止后续识别。状态对应的所需标签（包括适用状态下的“未知”）仅控制停止条件，不传给 Vision，不注入预期词、不替换错字、不捏造结果；补救错误立即传播，缺失证据仍使断言失败。专门测试验证无需补救、补齐后停止、耗尽仍缺失及错误传播。

“重置券”仅允许原有的“券/劵”图像歧义，并同时核对产品的精确 `Text("重置券")`。这些候选不能证明每个中文字形正确，也不能替代原生辅助功能或真实系统 Widget、共享容器、权限与双渠道安装验收；测试不采集用户桌面或真实数据。性能应以包含该改动的已提交 CI 日志比较，不能把此前 CI 或本机耗时当作云端收益。

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
python3 -B script/release_assets.py preflight --tag "$TAG" --commit "$COMMIT"
TOKENSTAT_TEAM_ID=<团队> TOKENSTAT_WIDGET_GROUP=<已授权组名> \
TOKENSTAT_SIGN_IDENTITY=<Developer-ID-Application证书SHA1> \
TOKENSTAT_APP_PROFILE=<主App的profile绝对路径> \
TOKENSTAT_WIDGET_PROFILE=<扩展的profile绝对路径> \
  ./script/build_and_run.sh --developer-id
python3 -B script/package_source.py
python3 -B script/release_assets.py package --tag "$TAG" --commit "$COMMIT" --app dist/developer-id/TokenStatMenu.app --source dist/TokenStatMenu-source.zip --directory dist/release
python3 -B script/release_assets.py verify --tag "$TAG" --commit "$COMMIT" --directory dist/release
python3 -B script/release_assets.py publish --tag "$TAG" --commit "$COMMIT" --directory dist/release
```

`preflight` 核对标签、HEAD、origin/main 和干净源码；`package/verify` 检查精确文件树、两个可执行文件的 arm64、版本、组名和签名。DMG 用只读挂载检查，随后卸载。`publish` 上传后回读远端字节，匹配才公开；冲突不覆盖，不用 `--clobber`。

完成后确认 Releases 列表中非草稿可见，五项资产能下载且摘要一致。只有本地文件或草稿不算发布完成。

正式发布后，从同一批准标签的干净源码执行独立匿名下载验收；目标目录必须不存在，不使用 `publish` 代替下载验收：

```bash
python3 -B script/verify_public_release.py --tag "$TAG" --commit "$COMMIT" \
  --directory <全新的本机验收目录>
```

该操作不使用 GitHub 登录或代理凭据，只读核验公开 tag、正式 Release 与五件套；原生 DMG 校验及 ZIP/DMG App 内容一致通过后才提升 `assets/`。它不安装或启动 App，不能替代两渠道系统验收；[#60](https://github.com/Tupig/TokenStatMenu/issues/60) 仍需最终真实下载成功后关闭。

## 仅本机签名与发布

签名及签名产物构建只能在本机执行。云 CI 仅执行无签名产品构建和测试，不再提供可选的云签名、打包或发布分支；不要上传证书、私钥、profile 或签名凭据。GitHub 只分发本机完成的发行资产。旧云发布开关不再授权任何发行操作。

需要真实签名的合成发行夹具也仅在本机执行；CI 明确跳过该组，继续执行 mock 授权、匿名下载、镜像与构建入口合同检查。云端通过不能替代该组本机结果。

`--developer-id` 必须显式提供身份及两个匹配的分发 profile；缺失、过期或授权不符即失败，不自动查找凭据、不回退 ad hoc、不安装启动、不公证或自动发布。历史公开包仍是 ad hoc，新增入口不代表真实 Developer ID、公证或双渠道 Widget 验收已经通过，见 [#88](https://github.com/Tupig/TokenStatMenu/issues/88)。

## Homebrew 跟进

[Tap](https://github.com/Tupig/homebrew-tokenstatmenu) 保留旧 Formula，不自动卸载或替换用户安装。正式二进制渠道应消费同一本机签名 DMG，验证固定摘要、身份和授权，不在云端重建重签。未有合格正式资产前不生成虚假的版本或 Cask SHA；CI 的静态 style/audit 不等于安装或系统 Widget 验收。

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

### Acceleration and Boundaries

- New main/PR runs cancel obsolete runs for the same ref; tag runs are not cancelled by this policy.
- The first Swift test builds the suite. Later tests use `--skip-build` in the same workspace; all three preliminary selections and the full suite still execute, with lock verification retained.
- The two development Debug native checks share one dedicated DerivedData directory sequentially. The production Release uses an independent directory; Debug does not replace Release, and cached external release binaries are not reused.
- This first phase adds neither cross-run caches nor multiple jobs. Compare step and total durations against successful baselines; reduced queueing or one fast run is not stable performance evidence. Track [#93](https://github.com/Tupig/TokenStatMenu/issues/93).

### On-demand Widget OCR Test Boundaries

`WidgetEntryViewTests` retains 20 actual synthetic offscreen `NSHostingView` bitmap renders of `WidgetEntryView` across light and dark appearances. Every render still runs whole-image OCR with language correction disabled. All numeric values, voucher counts and stale-value leakage assertions use only that whole-image top-1, never rescue candidates.

Chinese labels first use genuine whole-image top-10 candidates. Only while required labels remain missing does the test run language-corrected OCR on actual Chinese line regions at original and half sizes, stopping once all labels are present. State-specific required labels (including “未知” where applicable) are stop conditions only: they are not passed to Vision, injected as expected words, used to replace typos or fabricated as results. Rescue errors propagate immediately; missing evidence still fails assertions. A dedicated test covers no rescue needed, stopping after completion, exhaustion with missing evidence and error propagation.

The voucher label retains only the existing “券/劵” image ambiguity allowance, coupled with the product's exact `Text("重置券")`. Candidates do not establish correctness of every glyph or replace native accessibility, real system Widget, shared-container, permission or dual-channel installation acceptance. Tests capture neither the user's desktop nor real data. Compare performance using committed CI logs that include this change; earlier CI runs and local timings are not evidence of cloud speedup.

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
python3 -B script/release_assets.py preflight --tag "$TAG" --commit "$COMMIT"
TOKENSTAT_TEAM_ID=<team> TOKENSTAT_WIDGET_GROUP=<authorized-group> \
TOKENSTAT_SIGN_IDENTITY=<Developer-ID-Application-certificate-SHA1> \
TOKENSTAT_APP_PROFILE=<absolute-app-profile-path> \
TOKENSTAT_WIDGET_PROFILE=<absolute-extension-profile-path> \
  ./script/build_and_run.sh --developer-id
python3 -B script/package_source.py
python3 -B script/release_assets.py package --tag "$TAG" --commit "$COMMIT" --app dist/developer-id/TokenStatMenu.app --source dist/TokenStatMenu-source.zip --directory dist/release
python3 -B script/release_assets.py verify --tag "$TAG" --commit "$COMMIT" --directory dist/release
python3 -B script/release_assets.py publish --tag "$TAG" --commit "$COMMIT" --directory dist/release
```

Preflight checks tag, HEAD, origin/main and clean source. Packaging checks the exact file tree, both arm64 executables, version, group and signatures. DMG checks use read-only mounts. Publish reads remote assets back before making the Release public; mismatches fail without clobbering.

Confirm a public, non-draft entry and five downloadable matching assets. A local package or draft alone is not a completed release.

After publication, run the independent anonymous download check from clean source at the approved tag. The destination must not exist; do not rerun `publish` as a substitute:

```bash
python3 -B script/verify_public_release.py --tag "$TAG" --commit "$COMMIT" \
  --directory <new-local-acceptance-directory>
```

It uses no GitHub login or proxy credentials, checks the public tag, stable Release and all five assets read-only, and promotes `assets/` only after native DMG validation and identical ZIP/DMG App payloads. It does not install or launch the App and cannot replace dual-channel system acceptance. [#60](https://github.com/Tupig/TokenStatMenu/issues/60) remains open until the final real download succeeds.

## Local-only Signing and Publication

Signing and signed-product builds run only on the local machine. Cloud CI runs unsigned product builds and tests, with no optional cloud signing, packaging or publication branch. Never upload certificates, private keys, profiles or signing credentials. GitHub distributes the completed local assets; the former cloud-release switch grants no release authority.

Synthetic release fixtures that perform real signing are local-only too. CI explicitly skips that group while retaining mocked authorization, anonymous download, image and build-entrypoint contracts. Cloud success cannot substitute for the local native-fixture results.

`--developer-id` requires an explicit identity and two matching distribution profiles. Missing, expired or mismatched authorization fails without credential discovery, ad hoc fallback, installation, launch, notarization or automatic publication. Historical public packages remain ad hoc signed. The new entry point does not establish successful Developer ID signing, notarization or dual-channel Widget acceptance; see [#88](https://github.com/Tupig/TokenStatMenu/issues/88).

## Homebrew Follow-up

The [Tap](https://github.com/Tupig/homebrew-tokenstatmenu) preserves the old Formula without automatically removing or replacing installations. The distribution channel must consume the same locally signed DMG, checking its pinned digest, identity and authorization without cloud rebuilding or re-signing. No fabricated version or Cask SHA is generated before qualified public assets exist. Static CI style/audit checks do not establish installation or system Widget acceptance.

Check, smoke testing and writes are separate. Users still run `brew update` and `brew upgrade`. Test an actual installed-version upgrade; a successful no-change check is insufficient.

## Documentation and Wiki

README and `docs/wiki/` ship with source. GitHub Wiki is a separate repository and may need an initial Home page. Convert links appropriately when syncing. Do not report synchronization before confirming public readability.
