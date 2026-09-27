import XCTest
@testable import TrafficMonitor

// ============================================================
// MARK: - AlertStore 测试
// ============================================================

final class AlertStoreTests: XCTestCase {
    let testKey = "com.trafficmonitor.alertRules"

    override func setUp() {
        UserDefaults.standard.removeObject(forKey: testKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: testKey)
    }

    func testSaveAndLoad() {
        let rules = [
            AlertRule(processKey: "Chrome", displayName: "Chrome告警", thresholdBytes: 1000, thresholdRate: nil),
            AlertRule(processKey: nil, displayName: "全局速率", thresholdBytes: nil, thresholdRate: 5000),
        ]
        AlertStore.shared.save(rules)
        let loaded = AlertStore.shared.load()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].processKey, "Chrome")
        XCTAssertEqual(loaded[1].thresholdRate, 5000)
    }

    func testLoadEmpty() {
        UserDefaults.standard.removeObject(forKey: testKey)
        XCTAssertTrue(AlertStore.shared.load().isEmpty)
    }

    func testSaveOverwrites() {
        AlertStore.shared.save([AlertRule(processKey: "a", displayName: "A", thresholdBytes: 100, thresholdRate: nil)])
        AlertStore.shared.save([AlertRule(processKey: "b", displayName: "B", thresholdBytes: 200, thresholdRate: nil)])
        XCTAssertEqual(AlertStore.shared.load().count, 1)
    }
}

// ============================================================
// MARK: - GroupStore 测试
// ============================================================

final class GroupStoreTests: XCTestCase {
    let testKey = "com.trafficmonitor.processGroups"

    override func setUp() {
        UserDefaults.standard.removeObject(forKey: testKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: testKey)
    }

    func testSaveAndLoad() {
        let groups = [
            ProcessGroup(name: "Browsers", processKeys: ["Chrome", "Edge"]),
            ProcessGroup(name: "Dev", processKeys: ["VS Code", "Terminal"]),
        ]
        GroupStore.shared.save(groups)
        let loaded = GroupStore.shared.load()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].name, "Browsers")
        XCTAssertEqual(loaded[0].processKeys.count, 2)
    }

    func testLoadEmpty() {
        XCTAssertTrue(GroupStore.shared.load().isEmpty)
    }
}

// ============================================================
// ============================================================

// ============================================================
// MARK: - LogStore 测试
// ============================================================

final class LogStoreTests: XCTestCase {
    func testLogEntriesAppended() async {
        // Clear existing entries by logging enough to push old ones out
        await LogStore.shared.log("test1", level: .info, tag: "test")
        await LogStore.shared.log("test2", level: .error, tag: "test")

        let entries = await LogStore.shared.recentEntries(count: 10)
        XCTAssertTrue(entries.contains { $0.message == "test1" })
        XCTAssertTrue(entries.contains { $0.message == "test2" })
    }

    func testRecentErrorsFiltersWarnAndError() async {
        await LogStore.shared.log("debug msg", level: .debug, tag: "test")
        await LogStore.shared.log("info msg",  level: .info,  tag: "test")
        await LogStore.shared.log("warn msg",  level: .warn,  tag: "test")
        await LogStore.shared.log("error msg", level: .error, tag: "test")

        let errors = await LogStore.shared.recentErrors()
        XCTAssertTrue(errors.contains { $0.message == "warn msg" })
        XCTAssertTrue(errors.contains { $0.message == "error msg" })
        XCTAssertFalse(errors.contains { $0.message == "info msg" })
        XCTAssertFalse(errors.contains { $0.message == "debug msg" })
    }
}
