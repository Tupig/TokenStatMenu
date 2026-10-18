# TokenStatMenu 数据准确性与验收环境优化实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在不伪造实时 token/s 或扩大敏感数据读取范围的前提下，完成菜单数据口径优化、低风险热路径修正，并建立 AX/CLT 验收诊断。

**Architecture:** 第一阶段保持 `AppModel` 作为来源与新鲜度唯一判断点，Dashboard 复用模型时钟，StatusBarController 缓存一次诊断参数；第二阶段把 XCUITest runner 状态和 CLT/完整 Xcode 差异记录为独立环境证据。两个阶段共享现有合成测试和公开内容白名单，但各自提交、验证和 Issue 回读。

**Tech Stack:** Swift 6.4、SwiftUI、AppKit、XCTest、SwiftPM、Xcode、Python 3、GitHub Actions。

**Spec:** `docs/superpowers/specs/2026-10-18-accuracy-and-validation-optimization-design.md`

## Global Constraints

- 没有权威服务端时间序列时，实时 token/s 只能是未知或明确标记的本机活动估算。
- 5 小时/7 天/月度/本地记录/会话数必须保留来源、新鲜度和覆盖范围语义。
- 不读取 Keychain、认证数据库、会话正文，不修改 Hub/Codex 配置，不自动授予 TCC。
- 不降低 0.5 秒菜单刷新、15 秒活动新鲜度、5 秒本地扫描或现有扫描边界。
- 不修改已发布的 `v1.1.5` 标签、Release、资产或 Homebrew Formula。
- 每阶段完成本机检查、独立隐私审查、PR CI 和 main CI 后才能报告完成。

---

### Task 1: Freeze source/export and issue contracts

**Files:**
- Modify: `script/package_source.py`
- Create: `docs/superpowers/specs/2026-10-18-accuracy-and-validation-optimization-design.md`
- Create: `docs/superpowers/plans/2026-10-18-accuracy-and-validation-optimization.md`
- Test: `script/check_public_content.py`, `script/check_docs.py`

**Interfaces:**
- Produces the approved design and plan identities used by Tasks 2–8.
- Extends the publication allowlist only with the two reviewed design/plan files.

- [ ] **Step 1: Add the two reviewed documents to the publication allowlist**

```python
PUBLIC_FILES = [
    "docs/superpowers/specs/2026-10-18-accuracy-and-validation-optimization-design.md",
    "docs/superpowers/plans/2026-10-18-accuracy-and-validation-optimization.md",
]
```

- [ ] **Step 2: Run documentation and privacy checks**

Run:

```bash
python3 -B script/check_docs.py --self-test
python3 -B script/check_public_content.py
```

Expected: all publication links pass and the new documents contain no credential, enterprise endpoint, personal path, session body, or signed URL.

- [ ] **Step 3: Generate the source document twice**

Run:

```bash
python3 -B script/package_source.py
sha256sum docs/FULL_SOURCE.md
python3 -B script/package_source.py
sha256sum docs/FULL_SOURCE.md
```

Expected: both hashes are identical and the generated document contains the exact design and plan bytes.

- [ ] **Step 4: Commit the reviewed design only**

```bash
git add script/package_source.py docs/superpowers docs/FULL_SOURCE.md
git diff --cached --check
git commit -m "docs: define accuracy and validation optimization"
```

---

### Task 2: Make the Dashboard use the model clock consistently

**Files:**
- Modify: `Sources/TokenStatMenu/DashboardView.swift:70-75`
- Test: `Tests/TokenStatUITests/TokenHubQuotaStateTests.swift`

**Interfaces:**
- Consumes: `AppModel.tokenHubNow` and `AppModel.freshTokenHubQuota(at:)`.
- Produces: deterministic `tokenHubCard` freshness rendering for production and injected-clock tests.

- [ ] **Step 1: Write the failing clock-consistency test**

```swift
func testTokenHubCardUsesModelClockForFreshness() {
    let observed = Date(timeIntervalSince1970: 1_800_000_000)
    let identity = TokenHubIdentity(pid: 925, bundleID: TokenHubTarget.bundleID,
                                    executablePath: "/Applications/Synthetic Direct Hub.app/Contents/MacOS/Hub")
    let five = TokenHubWindowQuota(kind: .fiveHour, usedAmount: 3, limitAmount: 10,
                                   sourceSymbol: "$", usedPercent: 30, resetDisplay: "synthetic reset")
    let snapshot = TokenHubQuotaSnapshot(identity: identity, fiveHour: five, sevenDay: nil,
                                         monthly: nil, observedAt: observed)
    let direct = TokenHubQuotaResult(status: .connected, snapshot: snapshot, failure: nil)
    let harness = HubDirectHarness()
    let startup = AppModelStartupDependencies(
        loadPreferences: { nil }, savePreferences: { _ in },
        shouldStartBackgroundServices: { true })
    let model = AppModel(preview: false, startup: startup, directQuota: harness.dependencies)
    defer { model.shutdown() }
    model.tokenHubNow = { observed.addingTimeInterval(5) }
    model.refreshTokenHubQuota()
    harness.complete(1)
    XCTAssertNotNil(model.freshTokenHubQuota(at: model.tokenHubNow()))
}
```

Use the existing `HubDirectHarness` and its injected direct quota dependency; assert the Dashboard card receives the same `freshTokenHubQuota` result when the injected clock is advanced across the freshness boundary. The test must wait for the harness request before calling `complete` and must use the existing test startup dependency factory rather than real Hub I/O.

- [ ] **Step 2: Run the focused test and confirm the pre-change failure**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --force-resolved-versions --filter TokenHubQuotaStateTests.testTokenHubCardUsesModelClockForFreshness
```

Expected: the test exposes the direct `Date()` call in `DashboardView.tokenHubCard`.

- [ ] **Step 3: Replace the direct wall-clock call**

```swift
TokenHubQuotaCard(
    snapshot: model.freshTokenHubQuota(at: model.tokenHubNow()),
    status: model.tokenHubQuotaStatusText,
    enabled: model.tokenHubQuotaReadingEnabled,
    refreshSeconds: model.preferences.refreshSeconds,
    directSource: model.tokenHubQuotaIsDirect
)
```

- [ ] **Step 4: Run the focused state and rendering checks**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --force-resolved-versions --filter TokenHubQuotaStateTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --force-resolved-versions --filter DashboardHistoryTests
```

Expected: all focused tests pass without changing quota freshness semantics.

---

### Task 3: Cache the optional diagnostics output URL

**Files:**
- Modify: `Sources/TokenStatMenu/StatusBarController.swift:18-26, 85-146`
- Test: `Tests/TokenStatUITests/TokenHubQuotaStateTests.swift` or existing integration diagnostics assertions

**Interfaces:**
- Consumes: `CommandLine.arguments` once during controller initialization.
- Produces: `private let diagnosticsURL: URL?` used by `writeDiagnosticsIfRequested()`.

- [ ] **Step 1: Add an injectable URL test seam**

```swift
init(model: AppModel,
     factories: StatusBarContentFactories = .production,
     diagnosticsURL: URL? = StatusBarController.commandLineDiagnosticsURL())
```

The default parser accepts only `--diagnostics-output` followed by one path. Tests inject a temporary URL and never read real user paths.

- [ ] **Step 2: Add the failing cache behavior test**

Create a controller with an injected temporary diagnostics URL, call `refreshTitle()` twice within one second, and assert that the report is written at most once while the report contains only the existing approved fields. Create another controller with `diagnosticsURL: nil` and assert no output file is created. Use `AppModel(preview: true)` and delete the temporary URL in `defer`.

- [ ] **Step 3: Implement the one-time parser and replace argument scanning**

```swift
private static func commandLineDiagnosticsURL() -> URL? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: "--diagnostics-output"),
          arguments.indices.contains(index + 1) else { return nil }
    return URL(fileURLWithPath: arguments[index + 1])
}
```

Store the result in `diagnosticsURL`; keep the one-second `lastDiagnostic` throttle, report schema, atomic write, and utility queue unchanged.

- [ ] **Step 4: Run diagnostics and integration checks**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --force-resolved-versions --filter TokenHubQuotaStateTests
./script/test.sh
```

Expected: diagnostics remain boolean/count-only, no config or log path is leaked, and the isolated app still starts without global process termination.

---

### Task 4: Add menu accuracy regression coverage

**Files:**
- Modify: `Tests/TokenStatUITests/TokenHubQuotaStateTests.swift`
- Modify: `Tests/TokenStatUITests/DashboardHistoryTests.swift`
- Modify: `Sources/TokenStatMenu/AppModel.swift` only if a test exposes a real formatting defect

**Interfaces:**
- Consumes: existing `AppModel.title`, `menuTooltip`, `tokenHubMenuSuffix`, `freshLocalLiveTurn`, and `LocalCodexSnapshot`.
- Produces: deterministic regression coverage for source labels, unknown states, and complete/limited accounting.

- [ ] **Step 1: Add red cases for stale/future/missing data**

Cover these exact assertions:

```swift
XCTAssertTrue(model.title.contains("上轮均:—"))
XCTAssertTrue(model.menuTooltip.contains("实时估算：未知"))
XCTAssertTrue(model.menuTooltip.contains("5 小时未知"))
XCTAssertTrue(model.menuTooltip.contains("7 天未知"))
```

Also cover a limited snapshot where the title contains `小计` and `未核验`, and a complete snapshot where it contains `Σ` and `顶层对话`.

- [ ] **Step 2: Run the new cases before any formatter change**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --force-resolved-versions --filter TokenHubQuotaStateTests
```

Expected: existing behavior passes; any failure identifies a concrete source-label defect rather than inviting a broad rewrite.

- [ ] **Step 3: Make only the smallest formatter correction required by a failing assertion**

Keep `实时≈`, `上轮均`, `小计`, `Σ`, `Hub 5h/7d`, the 15-second freshness boundary, and source disclaimers unchanged unless the failing test demonstrates a contradiction.

- [ ] **Step 4: Render both appearances with synthetic data**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --force-resolved-versions --filter DashboardHistoryTests
```

Expected: no real user data, no new snapshot baseline without independent review, and symmetric source/unknown explanations in the panel.

---

### Task 5: Independent Phase 1 verification and publication review

**Files:**
- Modify: `docs/IMPLEMENTATION.md`
- Modify: `docs/VALIDATION.md`
- Modify: relevant Issue #19/#37 comments through GitHub after evidence is complete

**Interfaces:**
- Consumes: Tasks 2–4 test output and source diff.
- Produces: a phase receipt that distinguishes local estimates, enterprise quota, and unavailable authoritative TPS.

- [ ] **Step 1: Run the full local verification set**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run --force-resolved-versions TokenStatCoreChecks
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --force-resolved-versions
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./script/test.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project TokenStatMenu.xcodeproj -scheme TokenStatMenu -configuration Release -derivedDataPath /tmp/TokenStatMenu-Phase1 CODE_SIGNING_ALLOWED=NO build
python3 -B script/check_docs.py --self-test
python3 -B script/check_public_content.py --git-index
```

Expected: all commands exit 0; `Package.resolved` remains byte-identical; no private values enter the staged tree.

- [ ] **Step 2: Obtain independent PE/SecOps review**

Review the exact staged diff for source identity, freshness labels, diagnostics schema, PII, credentials, enterprise URLs, user paths, and session bodies. Record limitations; do not claim #37 complete.

- [ ] **Step 3: Create a PR for Phase 1**

Include Issue #19/#37 references, local test counts, `liveTokenSpeedPresent` evidence, and the explicit boundary that authoritative server telemetry is still unavailable.

- [ ] **Step 4: Wait for PR and main CI, then update Issue comments**

Close neither #19 nor #37 unless their specific acceptance criteria have real evidence. Merge only after PR CI and main CI both succeed.

---

### Task 6: Build a non-bypassing AX environment receipt for Issue #33

**Files:**
- Create: `script/run_settings_ax_check.sh`
- Modify: `docs/wiki/测试指南.md`
- Modify: `docs/UI_TESTING.md`
- Test: a shell/Python contract check for command and exit classification

**Interfaces:**
- Consumes: the existing private fixed fixture and the approved XCUITest project path supplied by the maintainer.
- Produces: a local receipt with `build_for_testing`, `test_without_building`, exit codes, and one of `passed` or `automation_environment_blocked`; never modifies TCC.

- [ ] **Step 1: Write the failing command contract**

The checker must require `DEVELOPER_DIR`, `xcodebuild build-for-testing`, then `xcodebuild test-without-building`; reject OCR/`screencapture`/`osascript` substitutes; preserve nonzero exit codes; classify the exact automation timeout without converting it to success.

- [ ] **Step 2: Run the contract against synthetic logs**

```bash
./script/run_settings_ax_check.sh --help
python3 script/check_public_content.py
```

Expected: help documents the fixture boundary and synthetic log fixtures classify timeout as blocked and an A01–A07 success log as passed.

- [ ] **Step 3: Implement the bounded runner**

Use a temporary output directory outside the repository, write only status/exit-code metadata to the receipt, and delete the temporary fixture process in a `trap`. Do not request permissions, reset TCC, or read the real Hub window.

- [ ] **Step 4: Run on the current machine**

Expected current result: if automation mode still times out, exit nonzero with `automation_environment_blocked`; keep Issue #33 open and attach only the sanitized status/exit code.

---

### Task 7: Add an explicit CLT/Xcode diagnostic command for Issue #52

**Files:**
- Create: `script/diagnose_swift_toolchain.py`
- Modify: `docs/wiki/编译指南.md`
- Modify: `docs/wiki/测试指南.md`
- Test: synthetic environment/output cases for CLT warning classification

**Interfaces:**
- Consumes: a scratch directory, selected `DEVELOPER_DIR`, and the existing SwiftPM commands.
- Produces: structured local output identifying toolchain, SDK, warning count, exit code, and recommended full-Xcode command; never edits SDK or global xcode-select.

- [ ] **Step 1: Write red synthetic parser tests**

```python
def test_missing_clt_search_paths_are_reported_as_upstream_warning():
    result = classify("ld: warning: directory not found for option: .../CommandLineTools/Developer/usr/lib")
    assert result.kind == "clt_search_path_warning"
    assert result.is_build_failure is False
```

- [ ] **Step 2: Implement the read-only diagnostic**

Run the minimum Hello and project command in two fresh scratch directories, capture stdout/stderr outside the repository, report `DEVELOPER_DIR` and tool versions, and leave `Package.resolved` unchanged. Do not create missing directories or suppress stderr.

- [ ] **Step 3: Run CLT and full-Xcode comparisons**

Expected: CLT may report the known warning while still building; full Xcode should be the verified clean path. If the upstream issue remains open, keep #52 open and update the issue with sanitized versions/counts only.

---

### Task 8: Phase 2 verification and closeout

**Files:**
- Modify: `docs/VALIDATION.md`
- Modify: `docs/wiki/测试指南.md`
- Modify: `docs/wiki/编译指南.md`
- Modify: `script/package_source.py`
- Regenerate: `docs/FULL_SOURCE.md`

**Interfaces:**
- Consumes: Tasks 6–7 receipts and independent reviews.
- Produces: a phase receipt that clearly separates AX product assertions, automation environment status, and upstream CLT status.

- [ ] **Step 1: Run all focused and full checks**

```bash
python3 -m py_compile script/diagnose_swift_toolchain.py
python3 -B script/check_docs.py --self-test
python3 -B script/check_public_content.py --git-index
python3 -B script/package_source.py
python3 -B script/package_source.py
```

Expected: docs pass, public files contain no private values, and repeated source generation is identical.

- [ ] **Step 2: Obtain independent PE/SecOps review**

Review the new scripts for shell injection, path escape, accidental TCC/credential access, raw log publication, and false-success exit handling.

- [ ] **Step 3: Create a separate Phase 2 PR**

Reference #33/#52, include the exact blocked/pass result, and keep open Issues open when the environment or upstream remains unresolved.

- [ ] **Step 4: Merge only after PR/main CI and closeout readback**

Confirm the remote workflow is still the single `ci.yml`, the v1.1.5 tag/Release is unchanged, and update each Issue with its bounded result.
