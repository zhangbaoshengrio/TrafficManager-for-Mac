# Bytetally Phase 2: Alert Event Persistence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire `TrafficPipeline` so that every time an `AlertRule` actually fires, it also writes an `AlertEvent` row via `DataStore.shared.insertAlertEvent` (added in Phase 1) — so the future chart-marker UI has real history to read, not just an empty table.

**Architecture:** Make the existing `ingest → checkAlerts → postAlert` call chain in `TrafficPipeline` (an actor) fully `async` internally, so `postAlert` can `await` a `DataStore` write the same way `flush()` already does. No new files, no UI changes.

**Tech Stack:** Swift 6.2, SwiftPM, GRDB.swift 6.29, XCTest.

## Global Constraints

- Swift tools version: 5.9; deployment target macOS 14.
- `TrafficPipeline.ingest(_:)` is already called as `await TrafficPipeline.shared.ingest(frame)` from its only call site (`CollectorService.swift:231`) — actor-boundary calls always require `await` regardless of whether the callee is `async`-marked, so adding `async` to `ingest`'s signature does not change that call site.
- A DB write failure must never crash or block the alert/notification path — follow the existing `try?`-style defensive pattern already used for notification posting in this method.
- Run tests with `cd ~/Documents/traffic-monitoring && swift test --filter <ClassName>/<testMethodName>`.

---

### Task 1: Persist an `AlertEvent` whenever a rule fires

**Files:**
- Modify: `Sources/Core/TrafficPipeline.swift:221` (`ingest`), `:306` (call site), `:421-444` (`checkAlerts`), `:446-465` (`postAlert`)
- Test: `Tests/TrafficPipelineTests.swift`

**Interfaces:**
- Consumes: `DataStore.insertAlertEvent(_:) throws` and `AlertEvent` (both from Phase 1, `Sources/Core/DataStore.swift` and `Sources/Models/AlertEvent.swift`).
- Produces: `TrafficPipeline.ingest(_ frame: TrafficFrame) async -> DashboardSnapshot?` (same behavior, now `async`). Every rule firing now also produces a persisted `AlertEvent` row readable via `DataStore.shared.queryAlertEvents(since:until:)`.

- [ ] **Step 1: Write the failing test**

Add this new test class at the end of `Tests/TrafficPipelineTests.swift`, following the exact `BucketPeakTests` setup pattern (temp `DataStore`, real `TrafficPipeline.shared`):

```swift
// ============================================================
// MARK: - 告警触发落库
// ============================================================

/// 规则触发时，除了发通知，还要落一条 `AlertEvent`，供流量图画 ▲ 标记用。
final class AlertEventPersistenceTests: XCTestCase {
    private let pipeline = TrafficPipeline.shared

    override func setUp() async throws {
        await pipeline.reset()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AlertEventPersistenceTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await DataStore.shared.setup(at: dir.appendingPathComponent("alerts.db"))
    }

    override func tearDown() async throws {
        await pipeline.reset()
    }

    private func frame(_ deltas: [PIDDelta], at: Date = Date(), interval: TimeInterval = 2) -> TrafficFrame {
        TrafficFrame(deltas: deltas, timestamp: at, interval: interval, isBaseline: false)
    }

    func testTriggeringRuleWritesAlertEvent() async throws {
        let key = "alertproc-\(UUID().uuidString)"
        let rule = AlertRule(processKey: key, displayName: key, thresholdBytes: 1000)
        await pipeline.setAlertRules([rule])

        let before = Date().timeIntervalSince1970 - 5
        _ = await pipeline.ingest(frame(
            [PIDDelta(pid: 999_600, execName: key, bytesIn: 2000, bytesOut: 0)]
        ))

        let events = try await DataStore.shared.queryAlertEvents(since: before)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].ruleId, rule.id.uuidString)
        XCTAssertEqual(events[0].triggerValue, 2000, accuracy: 0.001)
        XCTAssertTrue(events[0].displayName.contains(key),
                      "落库的展示文案应该包含触发它的进程名，方便图上 hover 时看懂")
    }

    /// 没达到阈值的普通流量不该写任何告警记录
    func testNonTriggeringDeltaWritesNoAlertEvent() async throws {
        let key = "quietproc-\(UUID().uuidString)"
        let rule = AlertRule(processKey: key, displayName: key, thresholdBytes: 1_000_000)
        await pipeline.setAlertRules([rule])

        let before = Date().timeIntervalSince1970 - 5
        _ = await pipeline.ingest(frame(
            [PIDDelta(pid: 999_601, execName: key, bytesIn: 100, bytesOut: 0)]
        ))

        let events = try await DataStore.shared.queryAlertEvents(since: before)
        XCTAssertTrue(events.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/Documents/traffic-monitoring && swift test --filter AlertEventPersistenceTests/testTriggeringRuleWritesAlertEvent`
Expected: FAIL — `queryAlertEvents` will return an empty array (0 events, not 1), because nothing writes to `alertEvent` yet. (This is a runtime assertion failure, not a compile error — every type/method used already exists from Phase 1.)

- [ ] **Step 3: Make the `ingest → checkAlerts → postAlert` chain `async`**

In `Sources/Core/TrafficPipeline.swift`, change the `ingest` signature (around line 221):

```swift
    func ingest(_ frame: TrafficFrame) async -> DashboardSnapshot? {
```

Change its call to `checkAlerts` (around line 306):

```swift
        await checkAlerts(aggregated, interval: interval)
```

Change the `checkAlerts` signature (around line 421):

```swift
    private func checkAlerts(
        _ aggregated: [String: (bytesIn: Int64, bytesOut: Int64, identity: ProcessIdentifier)],
        interval: TimeInterval
    ) async {
```

And its call to `postAlert` (around line 441):

```swift
                await postAlert(rule: rule, delta: delta)
```

- [ ] **Step 4: Make `postAlert` write the `AlertEvent`**

In `Sources/Core/TrafficPipeline.swift`, replace the `postAlert` method (around line 446):

```swift
    private func postAlert(rule: AlertRule, delta: ProcessDelta) async {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let body: String
        let triggerValue: Double
        if let tb = rule.thresholdBytes {
            body = L("alerts.notification.bytes", delta.identifier.displayName,
                     ByteFormatter.string(bytes: delta.totalBytes), ByteFormatter.string(bytes: tb))
            triggerValue = Double(delta.totalBytes)
        } else if let tr = rule.thresholdRate {
            body = L("alerts.notification.rate", delta.identifier.displayName,
                     ByteFormatter.rateString(bytesPerSecond: delta.totalRate),
                     ByteFormatter.rateString(bytesPerSecond: tr))
            triggerValue = delta.totalRate
        } else { return }

        let content = UNMutableNotificationContent()
        content.title = L("alerts.notification.title")
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )

        // 跟通知一样是"发出去就不管"：写历史记录失败不该影响告警本身的投递。
        try? await DataStore.shared.insertAlertEvent(AlertEvent(
            id: nil, timestamp: Date().timeIntervalSince1970,
            ruleId: rule.id.uuidString, displayName: body, triggerValue: triggerValue
        ))
    }
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd ~/Documents/traffic-monitoring && swift test --filter AlertEventPersistenceTests/testTriggeringRuleWritesAlertEvent`
Expected: PASS

Run: `cd ~/Documents/traffic-monitoring && swift test --filter AlertEventPersistenceTests/testNonTriggeringDeltaWritesNoAlertEvent`
Expected: PASS

- [ ] **Step 6: Run the full test suite to check for regressions**

Run: `cd ~/Documents/traffic-monitoring && swift test 2>&1 | grep -E "Executed [0-9]+ tests|error:|FAIL"`
Expected: All tests pass (204 from before + 2 new = 206), 0 failures. The `ingest` signature change from sync to `async` is source-compatible with the only production call site (already awaited) and with every existing test call site (also already awaited, per Swift's actor-boundary rule) — but verify no test file calls `pipeline.ingest(...)` without `await` (would now be a compile error instead of a behavior change).

- [ ] **Step 7: Commit**

```bash
cd ~/Documents/traffic-monitoring
git add Sources/Core/TrafficPipeline.swift Tests/TrafficPipelineTests.swift
git commit -m "feat(alerts): persist AlertEvent rows when a rule fires

Makes the ingest -> checkAlerts -> postAlert chain fully async inside
TrafficPipeline so postAlert can await DataStore.insertAlertEvent the
same way flush() already awaits insertEvents. Gives the future
chart-marker UI real trigger history instead of an empty table.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

## What's next (not in this plan)

SSID capture during collection (`NEHotspotNetwork.fetchCurrent`, per-bucket sampling into the `ssid` column added in Phase 1) needs its own investigation pass first — confirming the API actually returns a value under this app's entitlements, and designing the sampling cadence (once per frame is likely too chatty for an XPC-backed call; needs caching similar to `ProcessIdentityResolver`). After that, the `MainWindowView` redesign itself (aggregate chart, curve/heatmap toggle, network filter, export dropdown, expanded time-range presets, Peak column) is the final phase, built on everything Phase 1 and 2 provide.
