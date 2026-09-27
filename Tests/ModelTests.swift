import XCTest
@testable import TrafficMonitor

// ============================================================
// MARK: - ProcessIdentifier 测试
// ============================================================

final class ProcessIdentifierTests: XCTestCase {
    func testDescriptionWithBundleId() {
        let id = ProcessIdentifier(bundleId: "com.google.Chrome", execName: "Google Chrome")
        XCTAssertEqual(id.description, "com.google.Chrome")
    }

    func testDescriptionWithoutBundleId() {
        let id = ProcessIdentifier(bundleId: nil, execName: "mds")
        XCTAssertEqual(id.description, "mds")
    }

    func testDisplayNameFallsBackToExecName() {
        let id = ProcessIdentifier(bundleId: nil, execName: "myapp")
        XCTAssertEqual(id.displayName, "myapp")
    }

    func testDisplayNameFromBundleIdLastComponent() {
        // When no running app matches, falls back to last component of bundleId
        let id = ProcessIdentifier(bundleId: "com.example.FakeApp", execName: "FakeApp")
        XCTAssertEqual(id.displayName, "FakeApp")
    }

    func testSortKey() {
        let id = ProcessIdentifier(bundleId: nil, execName: "Chrome")
        XCTAssertEqual(id.sortKey, "chrome")
    }

    func testEquality() {
        let a = ProcessIdentifier(bundleId: "com.a", execName: "A")
        let b = ProcessIdentifier(bundleId: "com.a", execName: "A")
        XCTAssertEqual(a, b)
    }

    func testInequality() {
        let a = ProcessIdentifier(bundleId: "com.a", execName: "A")
        let b = ProcessIdentifier(bundleId: "com.b", execName: "B")
        XCTAssertNotEqual(a, b)
    }
}

// ============================================================
// MARK: - ProcessDelta 测试
// ============================================================

final class ProcessDeltaTests: XCTestCase {
    func testTotalBytes() {
        let ident = ProcessIdentifier(bundleId: nil, execName: "test")
        let delta = ProcessDelta(identifier: ident, bytesIn: 100, bytesOut: 50, interval: 5)
        XCTAssertEqual(delta.totalBytes, 150)
    }

    func testRxRate() {
        let ident = ProcessIdentifier(bundleId: nil, execName: "test")
        let delta = ProcessDelta(identifier: ident, bytesIn: 500, bytesOut: 0, interval: 5)
        XCTAssertEqual(delta.rxRate, 100.0)
    }

    func testTxRate() {
        let ident = ProcessIdentifier(bundleId: nil, execName: "test")
        let delta = ProcessDelta(identifier: ident, bytesIn: 0, bytesOut: 500, interval: 5)
        XCTAssertEqual(delta.txRate, 100.0)
    }

    func testTotalRate() {
        let ident = ProcessIdentifier(bundleId: nil, execName: "test")
        let delta = ProcessDelta(identifier: ident, bytesIn: 500, bytesOut: 500, interval: 5)
        XCTAssertEqual(delta.totalRate, 200.0)
    }

    func testRateWithTinyInterval() {
        let ident = ProcessIdentifier(bundleId: nil, execName: "test")
        let delta = ProcessDelta(identifier: ident, bytesIn: 100, bytesOut: 50, interval: 0.05)
        // 间隔被 Constants.minRateInterval (0.1s) 兜底，防止速率算成天文数字
        XCTAssertEqual(delta.rxRate, 1000.0)
        XCTAssertEqual(delta.txRate, 500.0)
    }
}

// ============================================================
// MARK: - TrafficEvent 测试
// ============================================================

final class TrafficEventTests: XCTestCase {
    func testRxRate() {
        let event = TrafficEvent(
            id: nil, timestamp: Date().timeIntervalSince1970,
            interval: 5, processKey: "test", bundleId: nil,
            displayName: "test", bytesIn: 500, bytesOut: 0
        )
        XCTAssertEqual(event.rxRate, 100.0)
    }

    func testTxRate() {
        let event = TrafficEvent(
            id: nil, timestamp: Date().timeIntervalSince1970,
            interval: 5, processKey: "test", bundleId: nil,
            displayName: "test", bytesIn: 0, bytesOut: 200
        )
        XCTAssertEqual(event.txRate, 40.0)
    }

    func testTotalBytes() {
        let event = TrafficEvent(
            id: nil, timestamp: Date().timeIntervalSince1970,
            interval: 5, processKey: "test", bundleId: nil,
            displayName: "test", bytesIn: 300, bytesOut: 200
        )
        XCTAssertEqual(event.totalBytes, 500)
    }

    func testTotalRate() {
        let event = TrafficEvent(
            id: nil, timestamp: Date().timeIntervalSince1970,
            interval: 2, processKey: "test", bundleId: nil,
            displayName: "test", bytesIn: 1000, bytesOut: 500
        )
        XCTAssertEqual(event.totalRate, 750.0)
    }
}

// ============================================================
// MARK: - ProcessRow 排序验证
// ============================================================

/// 表格行从 `NSObject` 子类换成了 `Equatable` 值类型，排序改用 `KeyPathComparator`。
final class ProcessRowSortTests: XCTestCase {
    private func row(_ name: String, in bytesIn: Int64 = 0, out bytesOut: Int64 = 0,
                     rx: Double = 0, tx: Double = 0) -> ProcessRow {
        ProcessRow(key: name, bundleId: nil, displayName: name, icon: "app.dashed",
                   iconPath: nil,
                   totalIn: bytesIn, totalOut: bytesOut, rxRate: rx, txRate: tx, spark: [])
    }

    func testSortByTotalBytesDescending() {
        let items = [row("A", in: 100, out: 50), row("B", in: 500, out: 200), row("C", in: 50, out: 20)]
        let sorted = items.sorted(using: KeyPathComparator(\ProcessRow.totalBytes, order: .reverse))
        XCTAssertEqual(sorted.map(\.displayName), ["B", "A", "C"])
    }

    func testSortByTotalBytesAscending() {
        let items = [row("A", in: 100, out: 50), row("B", in: 500, out: 200), row("C", in: 50, out: 20)]
        let sorted = items.sorted(using: KeyPathComparator(\ProcessRow.totalBytes, order: .forward))
        XCTAssertEqual(sorted.map(\.displayName), ["C", "A", "B"])
    }

    func testSortByDisplayName() {
        let items = [row("Safari"), row("Chrome"), row("Edge")]
        let sorted = items.sorted(using: KeyPathComparator(\ProcessRow.displayName, order: .forward))
        XCTAssertEqual(sorted.map(\.displayName), ["Chrome", "Edge", "Safari"])
    }

    func testSortByRxRate() {
        let items = [row("A", rx: 100), row("B", rx: 10.5), row("C", rx: 9999)]
        let sorted = items.sorted(using: KeyPathComparator(\ProcessRow.rxRate, order: .reverse))
        XCTAssertEqual(sorted.map(\.displayName), ["C", "A", "B"])
    }

    func testSortByTotalIn() {
        let items = [row("A", in: 1000), row("B", in: 100), row("C", in: 5000)]
        let sorted = items.sorted(using: KeyPathComparator(\ProcessRow.totalIn, order: .reverse))
        XCTAssertEqual(sorted.map(\.displayName), ["C", "A", "B"])
    }

    /// 值语义 + Equatable 是 SwiftUI Table 做行级差分的前提
    func testEquatableSemantics() {
        XCTAssertEqual(row("A", in: 1, out: 2, rx: 3, tx: 4), row("A", in: 1, out: 2, rx: 3, tx: 4))
        XCTAssertNotEqual(row("A", in: 1), row("A", in: 2))
    }
}

// ============================================================
// MARK: - ProcessGroup 测试
// ============================================================

final class ProcessGroupTests: XCTestCase {
    func testContains() {
        let group = ProcessGroup(name: "Browsers", processKeys: ["Chrome", "Edge", "Safari"])
        XCTAssertTrue(group.contains(processKey: "Chrome"))
        XCTAssertTrue(group.contains(processKey: "Safari"))
    }

    func testDoesNotContain() {
        let group = ProcessGroup(name: "Browsers", processKeys: ["Chrome", "Edge"])
        XCTAssertFalse(group.contains(processKey: "Finder"))
        XCTAssertFalse(group.contains(processKey: "chrome")) // case-sensitive
    }

    func testEmptyGroupContainsNothing() {
        let group = ProcessGroup(name: "empty", processKeys: [])
        XCTAssertFalse(group.contains(processKey: "anything"))
    }
}

// ============================================================
// MARK: - AlertRule 测试
// ============================================================

final class AlertRuleTests: XCTestCase {
    /// Create a ProcessDelta with known bytesIn + bytesOut (rate = total / interval)
    func makeDelta(processKey: String, bytesIn: Int64, bytesOut: Int64, interval: TimeInterval = 5) -> ProcessDelta {
        ProcessDelta(
            identifier: ProcessIdentifier(bundleId: nil, execName: processKey),
            bytesIn: bytesIn, bytesOut: bytesOut,
            interval: interval
        )
    }

    func testGlobalRuleTriggersAnyProcess() {
        let rule = AlertRule(processKey: nil, displayName: "全局", thresholdBytes: 1000, thresholdRate: nil)
        let delta = makeDelta(processKey: "Chrome", bytesIn: 1000, bytesOut: 1000)
        XCTAssertTrue(rule.isTriggered(by: delta))
    }

    func testGlobalRuleBelowThreshold() {
        let rule = AlertRule(processKey: nil, displayName: "全局", thresholdBytes: 10000, thresholdRate: nil)
        let delta = makeDelta(processKey: "Chrome", bytesIn: 1000, bytesOut: 1000)
        XCTAssertFalse(rule.isTriggered(by: delta))
    }

    func testProcessKeyFilterCorrect() {
        let rule = AlertRule(processKey: "Chrome", displayName: "Chrome告警", thresholdBytes: 1000, thresholdRate: nil)
        let chromeDelta = makeDelta(processKey: "Chrome", bytesIn: 1000, bytesOut: 1000)
        let edgeDelta = makeDelta(processKey: "Edge", bytesIn: 1000, bytesOut: 2000)
        XCTAssertTrue(rule.isTriggered(by: chromeDelta))
        XCTAssertFalse(rule.isTriggered(by: edgeDelta))
    }

    func testByteThresholdOnly() {
        let rule = AlertRule(processKey: nil, displayName: "字节", thresholdBytes: 1000, thresholdRate: nil)
        XCTAssertTrue(rule.isTriggered(by: makeDelta(processKey: "a", bytesIn: 1000, bytesOut: 1000)))
        XCTAssertFalse(rule.isTriggered(by: makeDelta(processKey: "a", bytesIn: 250, bytesOut: 249)))
    }

    func testRateThresholdOnly() {
        let rule = AlertRule(processKey: nil, displayName: "速率", thresholdBytes: nil, thresholdRate: 1000)
        // interval=5, totalRate = totalBytes/5. To get rate > 1000 need total > 5000
        let slowDelta = makeDelta(processKey: "a", bytesIn: 500, bytesOut: 500) // 1000 / 5 = 200 B/s
        let fastDelta = makeDelta(processKey: "a", bytesIn: 5000, bytesOut: 5000) // 10000/5 = 2000 B/s
        XCTAssertFalse(rule.isTriggered(by: slowDelta))
        XCTAssertTrue(rule.isTriggered(by: fastDelta))
    }

    func testBothThresholdsMustSatisfy() {
        // Both thresholds set: both byte AND rate must be met
        let rule = AlertRule(processKey: nil, displayName: "双阈值", thresholdBytes: 1000, thresholdRate: 1000)
        // totalBytes=2000 > 1000 ✓, totalRate=2000/5=400 < 1000 ✗ → NOT triggered
        XCTAssertFalse(rule.isTriggered(by: makeDelta(processKey: "a", bytesIn: 1000, bytesOut: 1000)))
        // totalBytes=200 > 1000 ✗ → NOT triggered regardless of rate
        XCTAssertFalse(rule.isTriggered(by: makeDelta(processKey: "b", bytesIn: 100, bytesOut: 100)))
        // totalBytes=10000 > 1000 ✓, totalRate=10000/5=2000 > 1000 ✓ → triggered
        XCTAssertTrue(rule.isTriggered(by: makeDelta(processKey: "c", bytesIn: 5000, bytesOut: 5000)))
    }

    func testDisabledRuleTriggersCheck() {
        let rule = AlertRule(processKey: nil, displayName: "禁用", thresholdBytes: 1, thresholdRate: nil, enabled: false)
        // isTriggered only checks thresholds, not enabled flag
        let delta = makeDelta(processKey: "a", bytesIn: 500, bytesOut: 500)
        XCTAssertTrue(rule.isTriggered(by: delta))
    }

    func testNoThresholdsDoesntTrigger() {
        let rule = AlertRule(processKey: nil, displayName: "空", thresholdBytes: nil, thresholdRate: nil)
        XCTAssertFalse(rule.isTriggered(by: makeDelta(processKey: "a", bytesIn: 500, bytesOut: 500)))
    }
}

// ============================================================
// MARK: - 时间桶自适应
// ============================================================

/// 图表的时间桶随跨度变粗，避免 7 天视图挤上千个点
final class TimelineBucketTests: XCTestCase {
    func testBucketGrowsWithRange() {
        XCTAssertEqual(TimelineBucket.size(for: 3_600), 60)      // 1 小时 → 1 分钟
        XCTAssertEqual(TimelineBucket.size(for: 21_600), 300)    // 6 小时 → 5 分钟
        XCTAssertEqual(TimelineBucket.size(for: 86_400), 1_800)  // 24 小时 → 30 分钟
        XCTAssertEqual(TimelineBucket.size(for: 604_800), 3_600) // 7 天 → 1 小时
    }

    func testBucketIsMonotonic() {
        let ranges: [TimeInterval] = [600, 3_600, 7_200, 21_600, 86_400, 259_200, 604_800]
        let sizes = ranges.map(TimelineBucket.size(for:))
        XCTAssertEqual(sizes, sizes.sorted(), "跨度变大时桶不应变小")
    }

    /// 桶数控制在图表能画得下的范围内
    func testPointCountStaysReasonable() {
        for range in [3_600.0, 21_600.0, 86_400.0, 604_800.0] {
            let count = range / TimelineBucket.size(for: range)
            XCTAssertLessThanOrEqual(count, 300, "跨度 \(range)s 会产生 \(count) 个点")
        }
    }
}

// ============================================================
// MARK: - 进程图标缓存
// ============================================================

@MainActor
final class ProcessIconCacheTests: XCTestCase {
    override func setUp() async throws {
        ProcessIconCache.shared.removeAll()
    }

    func testResolvesRealApplicationIcon() throws {
        let path = "/System/Applications/Calculator.app"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))
        XCTAssertNotNil(ProcessIconCache.shared.icon(path: path, bundleId: nil))
    }

    /// 裸可执行文件也要有图标（守护进程走这条，和活动监视器一致）
    func testResolvesPlainExecutableIcon() {
        XCTAssertNotNil(ProcessIconCache.shared.icon(path: "/bin/sh", bundleId: nil))
    }

    func testUnknownPathAndBundleYieldNil() {
        XCTAssertNil(ProcessIconCache.shared.icon(
            path: "/nonexistent/\(UUID().uuidString)",
            bundleId: "com.invalid.\(UUID().uuidString)"
        ))
    }

    func testNilInputsYieldNil() {
        XCTAssertNil(ProcessIconCache.shared.icon(path: nil, bundleId: nil))
    }

    /// 未命中也要缓存，否则每次重绘都会重试一遍失败的路径
    func testMissesAreCachedToo() {
        let bogus = "/nonexistent/\(UUID().uuidString)"
        _ = ProcessIconCache.shared.icon(path: bogus, bundleId: nil)
        let elapsed = ContinuousClock().measure {
            for _ in 0..<1_000 { _ = ProcessIconCache.shared.icon(path: bogus, bundleId: nil) }
        }
        XCTAssertLessThan(elapsed, .milliseconds(50), "重复查询未命中路径应命中缓存")
    }
}

// ============================================================
// MARK: - 开机自启动可用性判定
// ============================================================

/// 只验证「能不能用」的判定逻辑，不真的注册登录项 —— 那会改动用户系统状态。
@MainActor
final class LaunchAtLoginTests: XCTestCase {
    /// 测试进程不是 .app bundle，因此必然判定为不支持
    func testUnsupportedWhenNotRunningAsAppBundle() {
        XCTAssertFalse(LaunchAtLogin.isSupported)
        XCTAssertFalse(LaunchAtLogin.isEnabled)
        XCTAssertFalse(LaunchAtLogin.requiresApproval)
    }

    /// 不支持时必须给出可读原因，而不是静默失败
    func testUnsupportedReportsReason() {
        let reason = LaunchAtLogin.setEnabled(true)
        XCTAssertNotNil(reason)
        XCTAssertFalse(reason!.isEmpty)
        XCTAssertNotNil(LaunchAtLogin.statusDescription)
    }
}
