# Bytetally Phase 1: Data Layer Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the four data-layer building blocks the Bytetally-style main window redesign needs — SSID tagging, an aggregate (all-process) timeline query, an hour×weekday heatmap query, and a persisted alert-event log — with zero UI changes, so every piece is independently testable before any view code touches it.

**Architecture:** All work lands in `DataStore` (GRDB/SQLite) plus one new `AlertEvent` model mirroring the existing `TrafficEvent` model. No new files beyond the model; no changes to collection (`NStatCollector`), UI, or Settings in this phase.

**Tech Stack:** Swift 6.2, SwiftPM, GRDB.swift 6.29, XCTest.

## Global Constraints

- Swift tools version: 5.9 (per `Package.swift`); deployment target macOS 14.
- Every new `DataStore` method follows the existing actor-isolated, `dbWriter`-guarded pattern (`guard let writer = dbWriter else { return ... }`).
- No new third-party dependencies — GRDB is already the only one.
- Migrations use `ALTER TABLE ... ADD COLUMN` guarded by a `columns.contains(...)` check, matching the existing `peakIn`/`peakOut` migration in `DataStore.setup`.
- All new Swift code and comments follow the existing codebase's Chinese-comment convention for the "why", matching the style already in `DataStore.swift`/`TrafficEvent.swift`.
- Run tests with `cd ~/Documents/traffic-monitoring && swift test --filter <ClassName>/<testMethodName>` for single tests, or `swift test --filter <ClassName>` for a whole class.

---

### Task 1: SSID column + migration

**Files:**
- Modify: `Sources/Models/TrafficEvent.swift`
- Modify: `Sources/Core/DataStore.swift:40-69` (setup/migration), `:80-113` (insertEvents)
- Test: `Tests/DataStoreTests.swift`

**Interfaces:**
- Produces: `TrafficEvent.ssid: String?` (new field, default `nil`, positioned after `peakOut`). `DataStore.insertEvents(_:)` now persists `ssid` for every row (existing call sites unaffected — default parameter).

- [ ] **Step 1: Write the failing migration test**

Add `import GRDB` to the test file's imports (needed for `DatabaseQueue` below), and append this new class at the end of `Tests/DataStoreTests.swift`:

```swift
// ============================================================
// MARK: - SSID 列迁移
// ============================================================

/// 验证 `ssid` 列能给老库（迁移前建的、只有 9 列的 trafficEvent）补上，
/// 且老数据在迁移后还能正常查询。
final class SSIDMigrationTests: XCTestCase {
    var tempDir: URL!

    override func setUp() async throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SSIDMigration_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let dir = tempDir { try? FileManager.default.removeItem(at: dir) }
    }

    func testSSIDColumnIsAddedToPreExistingDatabase() async throws {
        // 手工建一份「老版本」的库：跟当前 setup() 建表逻辑一致，但没有 ssid 列。
        let dbURL = tempDir.appendingPathComponent("legacy.db")
        let legacyQueue = try DatabaseQueue(path: dbURL.path)
        try legacyQueue.write { db in
            try db.create(table: "trafficEvent") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp", .double).notNull().indexed()
                t.column("interval", .double).notNull()
                t.column("processKey", .text).notNull().indexed()
                t.column("bundleId", .text)
                t.column("displayName", .text).notNull()
                t.column("bytesIn", .integer).notNull()
                t.column("bytesOut", .integer).notNull()
                t.column("peakIn", .double).notNull().defaults(to: 0)
                t.column("peakOut", .double).notNull().defaults(to: 0)
            }
            try db.execute(sql: """
                INSERT INTO trafficEvent
                (timestamp, interval, processKey, bundleId, displayName, bytesIn, bytesOut, peakIn, peakOut)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [1_700_000_000.0, 60.0, "legacy", nil, "legacy", 100, 50, 0, 0])
        }
        legacyQueue.releaseMemory()

        let migratedStore = DataStore()
        try await migratedStore.setup(at: dbURL)

        // 老数据还在
        let beforeInsert = try await migratedStore.querySummary(since: 0)
        XCTAssertEqual(beforeInsert.map(\.processKey), ["legacy"])

        // 新的 INSERT 语句带 ssid 列；要是 ALTER TABLE 没真的加上这一列，
        // 这里会直接抛 "no such column: ssid"。不抛错就是迁移成功的证明。
        try await migratedStore.insertEvents([
            TrafficEvent(id: nil, timestamp: 1_700_000_100, interval: 60,
                         processKey: "new", bundleId: nil, displayName: "new",
                         bytesIn: 10, bytesOut: 0, ssid: "HomeWiFi")
        ])

        let afterInsert = try await migratedStore.querySummary(since: 0)
        XCTAssertEqual(afterInsert.count, 2)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/Documents/traffic-monitoring && swift test --filter SSIDMigrationTests/testSSIDColumnIsAddedToPreExistingDatabase`
Expected: FAIL to compile — `TrafficEvent` has no member `ssid` (the initializer call in the test won't compile yet).

- [ ] **Step 3: Add `ssid` to the `TrafficEvent` model**

In `Sources/Models/TrafficEvent.swift`, add the field right after `peakOut` (before the `rxRate` computed property):

```swift
    /// 同上，发送方向
    var peakOut: Double = 0

    /// 采集这条事件时所在的 Wi-Fi 网络名（SSID）。
    /// `nil` 表示未知网络、有线连接，或迁移前的老数据。
    var ssid: String? = nil

```

And add it to the `Columns` enum at the bottom of the file:

```swift
extension TrafficEvent: TableRecord, FetchableRecord, MutablePersistableRecord {
    enum Columns {
        static let id = Column(CodingKeys.id)
        static let timestamp = Column(CodingKeys.timestamp)
        static let interval = Column(CodingKeys.interval)
        static let processKey = Column(CodingKeys.processKey)
        static let bundleId = Column(CodingKeys.bundleId)
        static let displayName = Column(CodingKeys.displayName)
        static let bytesIn = Column(CodingKeys.bytesIn)
        static let bytesOut = Column(CodingKeys.bytesOut)
        static let peakIn = Column(CodingKeys.peakIn)
        static let peakOut = Column(CodingKeys.peakOut)
        static let ssid = Column(CodingKeys.ssid)
    }
}
```

- [ ] **Step 4: Add the migration to `DataStore.setup(at:)`**

In `Sources/Core/DataStore.swift`, modify the table-creation block (around line 41) to declare `ssid` for brand-new databases, and extend the migration check (around line 60) to add it for existing ones:

```swift
        try writer.write { db in
            try db.create(table: "trafficEvent", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp", .double).notNull().indexed()
                t.column("interval", .double).notNull()
                t.column("processKey", .text).notNull().indexed()
                t.column("bundleId", .text)
                t.column("displayName", .text).notNull()
                t.column("bytesIn", .integer).notNull()
                t.column("bytesOut", .integer).notNull()
                t.column("peakIn", .double).notNull().defaults(to: 0)
                t.column("peakOut", .double).notNull().defaults(to: 0)
                t.column("ssid", .text)
            }

            // 复合索引：按时间 + 进程查
            try db.create(index: "idx_traffic_ts_process",
                          on: "trafficEvent",
                          columns: ["timestamp", "processKey"],
                          ifNotExists: true)

            // 迁移：老库补上峰值列。默认 0 = 未知，查询时退回该行自己的
            // `bytes / interval` —— 拿展示桶长度去除会让老数据整体高估。
            let columns = try db.columns(in: "trafficEvent").map(\.name)
            if !columns.contains("peakIn") {
                try db.alter(table: "trafficEvent") { t in
                    t.add(column: "peakIn", .double).notNull().defaults(to: 0)
                    t.add(column: "peakOut", .double).notNull().defaults(to: 0)
                }
            }
            // 迁移：老库补上 ssid 列（可空，老数据统一视为「未知网络」）。
            if !columns.contains("ssid") {
                try db.alter(table: "trafficEvent") { t in
                    t.add(column: "ssid", .text)
                }
            }
        }
```

- [ ] **Step 5: Update `insertEvents` to persist `ssid`**

In `Sources/Core/DataStore.swift`, modify `insertEvents` (around line 80):

```swift
    func insertEvents(_ events: [TrafficEvent]) throws {
        guard let writer = dbWriter, !events.isEmpty else { return }

        try writer.write { db in
            for chunk in stride(from: 0, to: events.count, by: Constants.insertChunkSize) {
                let slice = events[chunk ..< min(chunk + Constants.insertChunkSize, events.count)]
                let placeholders = Array(
                    repeating: "(?,?,?,?,?,?,?,?,?,?)", count: slice.count
                ).joined(separator: ",")
                var args: [DatabaseValueConvertible?] = []
                args.reserveCapacity(slice.count * 10)
                for e in slice {
                    args.append(e.timestamp)
                    args.append(e.interval)
                    args.append(e.processKey)
                    args.append(e.bundleId)
                    args.append(e.displayName)
                    args.append(e.bytesIn)
                    args.append(e.bytesOut)
                    args.append(e.peakIn)
                    args.append(e.peakOut)
                    args.append(e.ssid)
                }
                try db.execute(
                    sql: """
                        INSERT INTO trafficEvent
                        (timestamp, interval, processKey, bundleId, displayName,
                         bytesIn, bytesOut, peakIn, peakOut, ssid)
                        VALUES \(placeholders)
                        """,
                    arguments: StatementArguments(args)
                )
            }
        }
    }
```

- [ ] **Step 6: Run test to verify it passes**

Run: `cd ~/Documents/traffic-monitoring && swift test --filter SSIDMigrationTests/testSSIDColumnIsAddedToPreExistingDatabase`
Expected: PASS

- [ ] **Step 7: Run the full existing suite to check for regressions**

Run: `cd ~/Documents/traffic-monitoring && swift test --filter DataStoreTests`
Expected: PASS (all existing tests still green — the 9→10 column change is additive and every existing `TrafficEvent(...)` call site omits `ssid`, relying on its default)

- [ ] **Step 8: Commit**

```bash
cd ~/Documents/traffic-monitoring
git add Sources/Models/TrafficEvent.swift Sources/Core/DataStore.swift Tests/DataStoreTests.swift
git commit -m "feat(data): add ssid column with migration for existing databases"
```

---

### Task 2: Aggregate (all-process) timeline query

**Files:**
- Modify: `Sources/Core/DataStore.swift:223-290` (add new method near `queryTimeline`)
- Test: `Tests/DataStoreTests.swift`

**Interfaces:**
- Consumes: `TimelinePoint` (existing struct, `Sources/Core/DataStore.swift:370-384`).
- Produces: `DataStore.queryAggregateTimeline(since:until:bucketSeconds:) throws -> [TimelinePoint]` — same shape and gap-filling semantics as `queryTimeline`, summed across every process instead of filtered to one.

- [ ] **Step 1: Write the failing test**

Add this method to the `DataStoreTests` class in `Tests/DataStoreTests.swift`, under a new `// MARK: - Aggregate Timeline` section (after the existing Timeline tests):

```swift
    // MARK: - Aggregate Timeline

    /// 聚合时间线要把「同一个桶里」所有进程的流量加在一起，
    /// 而不是像 `queryTimeline` 那样只看一个 processKey。
    func testQueryAggregateTimelineSumsAcrossProcesses() async throws {
        let now = Date().timeIntervalSince1970
        try await store.insertEvents([
            TrafficEvent(id: nil, timestamp: now, interval: 5,
                         processKey: "Chrome", bundleId: nil, displayName: "Chrome",
                         bytesIn: 1000, bytesOut: 200),
            TrafficEvent(id: nil, timestamp: now, interval: 5,
                         processKey: "Edge", bundleId: nil, displayName: "Edge",
                         bytesIn: 500, bytesOut: 100),
        ])

        let points = try await store.queryAggregateTimeline(
            since: now - 60, bucketSeconds: 60
        )

        let bucket = try XCTUnwrap(points.first { $0.bytesIn > 0 })
        XCTAssertEqual(bucket.bytesIn, 1500, "两个进程同一个桶的流量应合并")
        XCTAssertEqual(bucket.bytesOut, 300)
    }

    /// 没采集的桶依然补 0 + 标 isCovered = false，语义跟 `queryTimeline` 一致。
    func testQueryAggregateTimelineMarksUncoveredBuckets() async throws {
        let base = 1_700_000_040.0
        try await store.insertEvents([
            TrafficEvent(id: nil, timestamp: base, interval: 60,
                         processKey: "a", bundleId: nil, displayName: "a",
                         bytesIn: 100, bytesOut: 0),
            TrafficEvent(id: nil, timestamp: base + 120, interval: 60,
                         processKey: "b", bundleId: nil, displayName: "b",
                         bytesIn: 200, bytesOut: 0),
        ])

        let points = try await store.queryAggregateTimeline(
            since: base, until: base + 120, bucketSeconds: 60
        )

        XCTAssertEqual(points.map(\.timestamp), [base, base + 60, base + 120])
        XCTAssertTrue(points[0].isCovered)
        XCTAssertFalse(points[1].isCovered, "中间那分钟谁都没有数据")
        XCTAssertTrue(points[2].isCovered)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/Documents/traffic-monitoring && swift test --filter DataStoreTests/testQueryAggregateTimelineSumsAcrossProcesses`
Expected: FAIL to compile — `queryAggregateTimeline` doesn't exist yet.

- [ ] **Step 3: Implement `queryAggregateTimeline`**

Add this method to `DataStore` in `Sources/Core/DataStore.swift`, directly after `queryTimeline` (after line 290):

```swift
    /// 全部进程合计的时间线（按时间桶聚合），用于主窗口的汇总趋势图。
    ///
    /// 分桶、补洞（`isCovered`）逻辑跟 `queryTimeline` 完全一致，唯一区别是
    /// 不按 `processKey` 过滤/分组 —— 这里的"有没有采集""流量多少"都是
    /// 所有进程的总和。两处查询的补洞逻辑刻意没有抽公共函数：这段 SQL 和
    /// 网格填充逻辑目前只有这两个调用点，提前抽象只会让两边都多绕一层。
    func queryAggregateTimeline(
        since: TimeInterval,
        until: TimeInterval = Date().timeIntervalSince1970,
        bucketSeconds: TimeInterval = 300
    ) throws -> [TimelinePoint] {
        guard let writer = dbWriter else { return [] }

        return try writer.read { db in
            let covered = try TimeInterval.fetchSet(
                db,
                sql: """
                    SELECT DISTINCT CAST(timestamp / ? AS INTEGER) * ? AS bucket
                    FROM trafficEvent
                    WHERE timestamp >= ? AND timestamp <= ?
                    """,
                arguments: [bucketSeconds, bucketSeconds, since, until]
            )

            let rows = try Row.fetchAll(db, sql: """
                SELECT CAST(timestamp / ? AS INTEGER) * ? AS bucket,
                       SUM(bytesIn)  AS totalIn,
                       SUM(bytesOut) AS totalOut,
                       MAX(MAX(peakIn,  bytesIn  / MAX(interval, 0.1))) AS peakIn,
                       MAX(MAX(peakOut, bytesOut / MAX(interval, 0.1))) AS peakOut
                FROM trafficEvent
                WHERE timestamp >= ? AND timestamp <= ?
                GROUP BY bucket
                ORDER BY bucket
            """, arguments: [bucketSeconds, bucketSeconds, since, until])

            var byBucket: [TimeInterval: TimelinePoint] = [:]
            for row in rows {
                let point = TimelinePoint(
                    timestamp: row["bucket"],
                    bytesIn: row["totalIn"],
                    bytesOut: row["totalOut"],
                    peakIn: row["peakIn"],
                    peakOut: row["peakOut"]
                )
                byBucket[point.timestamp] = point
            }

            let first = (since / bucketSeconds).rounded(.down) * bucketSeconds
            let last = (until / bucketSeconds).rounded(.down) * bucketSeconds
            guard first <= last else { return [] }

            var points: [TimelinePoint] = []
            points.reserveCapacity(Int((last - first) / bucketSeconds) + 1)
            var bucket = first
            while bucket <= last {
                points.append(byBucket[bucket]
                    ?? TimelinePoint(timestamp: bucket, bytesIn: 0, bytesOut: 0,
                                     isCovered: covered.contains(bucket)))
                bucket += bucketSeconds
            }
            return points
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/Documents/traffic-monitoring && swift test --filter DataStoreTests/testQueryAggregateTimelineSumsAcrossProcesses`
Expected: PASS

Run: `cd ~/Documents/traffic-monitoring && swift test --filter DataStoreTests/testQueryAggregateTimelineMarksUncoveredBuckets`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd ~/Documents/traffic-monitoring
git add Sources/Core/DataStore.swift Tests/DataStoreTests.swift
git commit -m "feat(data): add queryAggregateTimeline for the main-window summary chart"
```

---

### Task 3: Heatmap query (local weekday × hour)

**Files:**
- Modify: `Sources/Core/DataStore.swift` (add new method + `HeatmapCell` struct)
- Test: `Tests/DataStoreTests.swift`

**Interfaces:**
- Produces: `struct HeatmapCell` (`weekday: Int` 0=Sunday…6=Saturday, `hour: Int` 0-23, `bytesIn: Int64`, `bytesOut: Int64`, `totalBytes: Int64`). `DataStore.queryHeatmap(since:until:calendar:) throws -> [HeatmapCell]`.

**Why bucketing happens in Swift, not SQL:** SQLite's `strftime('%w'/'%H', ts, 'unixepoch')` returns UTC weekday/hour. A heatmap is supposed to show *the user's own* daily rhythm, so weekday/hour must be computed with the user's local `Calendar`, not UTC — otherwise the heatmap would be silently wrong (shifted) for anyone outside UTC. This method aggregates coarsely by absolute hour in SQL (cheap), then buckets those hourly rows into local weekday/hour in Swift.

- [ ] **Step 1: Write the failing test**

Add this to `DataStoreTests` under a new `// MARK: - Heatmap` section:

```swift
    // MARK: - Heatmap

    /// 热力图按本地日历的「星期几 + 小时」聚合，不是 UTC —— 用固定时区的
    /// Calendar 注入进去，测试才不受跑测试的机器所在时区影响。
    func testQueryHeatmapAggregatesByLocalWeekdayAndHour() async throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!

        // 2024-01-01 是周一
        var comps = DateComponents()
        comps.year = 2024; comps.month = 1; comps.day = 1; comps.hour = 14
        let mondayAfternoon = utc.date(from: comps)!.timeIntervalSince1970

        comps.day = 2 // 周二，同一个小时
        let tuesdaySameHour = utc.date(from: comps)!.timeIntervalSince1970

        try await store.insertEvents([
            TrafficEvent(id: nil, timestamp: mondayAfternoon, interval: 60,
                         processKey: "a", bundleId: nil, displayName: "a",
                         bytesIn: 1000, bytesOut: 0),
            TrafficEvent(id: nil, timestamp: mondayAfternoon + 600, interval: 60,
                         processKey: "a", bundleId: nil, displayName: "a",
                         bytesIn: 500, bytesOut: 0), // 同一个小时桶
            TrafficEvent(id: nil, timestamp: tuesdaySameHour, interval: 60,
                         processKey: "a", bundleId: nil, displayName: "a",
                         bytesIn: 200, bytesOut: 0),
        ])

        let cells = try await store.queryHeatmap(
            since: mondayAfternoon - 3600, until: tuesdaySameHour + 3600, calendar: utc
        )

        let monday = try XCTUnwrap(cells.first { $0.weekday == 1 && $0.hour == 14 })
        XCTAssertEqual(monday.bytesIn, 1500, "同一小时桶的两条事件应合并")

        let tuesday = try XCTUnwrap(cells.first { $0.weekday == 2 && $0.hour == 14 })
        XCTAssertEqual(tuesday.bytesIn, 200)
    }

    func testQueryHeatmapEmptyRangeReturnsEmpty() async throws {
        let cells = try await store.queryHeatmap(since: 0, until: 0)
        XCTAssertTrue(cells.isEmpty)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/Documents/traffic-monitoring && swift test --filter DataStoreTests/testQueryHeatmapAggregatesByLocalWeekdayAndHour`
Expected: FAIL to compile — `queryHeatmap` and `HeatmapCell` don't exist yet.

- [ ] **Step 3: Implement `HeatmapCell` and `queryHeatmap`**

Add `HeatmapCell` to the `// MARK: - Query Result Types` section at the bottom of `Sources/Core/DataStore.swift`, next to `TimelinePoint`:

```swift
/// 热力图里的一个格子：某个「本地星期几 + 本地小时」组合的流量合计。
struct HeatmapCell: Identifiable, Equatable {
    var id: String { "\(weekday)-\(hour)" }
    /// 0 = 周日 … 6 = 周六（跟 SQLite `strftime('%w', ...)` 的编号对齐，
    /// 方便跟其它地方的星期几表示互相比较）
    let weekday: Int
    let hour: Int
    let bytesIn: Int64
    let bytesOut: Int64

    var totalBytes: Int64 { bytesIn + bytesOut }
}
```

Add `queryHeatmap` as a method on `DataStore`, directly after `queryAggregateTimeline`:

```swift
    /// 按「本地星期几 × 本地小时」聚合流量，用于热力图视图。
    ///
    /// 不能直接用 SQLite 的 `strftime('%w'/'%H', ts, 'unixepoch')`——那返回的是
    /// UTC 的星期几/小时，用户关心的是自己本地时区的作息规律，不是 UTC。
    /// 所以这里先在 SQL 里按整点粗聚合（便宜、行数少），本地时区的换算放在 Swift 里做。
    func queryHeatmap(
        since: TimeInterval,
        until: TimeInterval = Date().timeIntervalSince1970,
        calendar: Calendar = .current
    ) throws -> [HeatmapCell] {
        guard let writer = dbWriter else { return [] }

        let hourlyRows = try writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT CAST(timestamp / 3600 AS INTEGER) * 3600 AS hourBucket,
                       SUM(bytesIn)  AS totalIn,
                       SUM(bytesOut) AS totalOut
                FROM trafficEvent
                WHERE timestamp >= ? AND timestamp <= ?
                GROUP BY hourBucket
            """, arguments: [since, until])
        }

        var byCell: [String: HeatmapCell] = [:]
        for row in hourlyRows {
            let bucketStart: TimeInterval = row["hourBucket"]
            let date = Date(timeIntervalSince1970: bucketStart)
            // Calendar.weekday 是 1...7（周日=1）；减一换成跟 SQLite %w 一致的 0...6
            let weekday = calendar.component(.weekday, from: date) - 1
            let hour = calendar.component(.hour, from: date)
            let key = "\(weekday)-\(hour)"
            let bytesIn: Int64 = row["totalIn"]
            let bytesOut: Int64 = row["totalOut"]
            if let existing = byCell[key] {
                byCell[key] = HeatmapCell(weekday: weekday, hour: hour,
                                           bytesIn: existing.bytesIn + bytesIn,
                                           bytesOut: existing.bytesOut + bytesOut)
            } else {
                byCell[key] = HeatmapCell(weekday: weekday, hour: hour,
                                           bytesIn: bytesIn, bytesOut: bytesOut)
            }
        }
        return Array(byCell.values)
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/Documents/traffic-monitoring && swift test --filter DataStoreTests/testQueryHeatmapAggregatesByLocalWeekdayAndHour`
Expected: PASS

Run: `cd ~/Documents/traffic-monitoring && swift test --filter DataStoreTests/testQueryHeatmapEmptyRangeReturnsEmpty`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd ~/Documents/traffic-monitoring
git add Sources/Core/DataStore.swift Tests/DataStoreTests.swift
git commit -m "feat(data): add queryHeatmap aggregating by local weekday/hour"
```

---

### Task 4: Persisted alert-event log

**Files:**
- Create: `Sources/Models/AlertEvent.swift`
- Modify: `Sources/Core/DataStore.swift` (add table creation in `setup`, `insertAlertEvent`, `queryAlertEvents`)
- Test: `Tests/DataStoreTests.swift`

**Interfaces:**
- Produces: `struct AlertEvent` (`id: Int64?`, `timestamp: TimeInterval`, `ruleId: String`, `displayName: String`, `triggerValue: Double`). `DataStore.insertAlertEvent(_:) throws`, `DataStore.queryAlertEvents(since:until:) throws -> [AlertEvent]` (ordered by timestamp ascending).
- This is what the future chart-marker UI task and the future "fire alert" wiring task (in the collector) will call — `AlertRule.id` (a `UUID`) should be passed as `ruleId: rule.id.uuidString`.

- [ ] **Step 1: Write the failing test**

Add this to `DataStoreTests` under a new `// MARK: - Alert Events` section:

```swift
    // MARK: - Alert Events

    func testInsertAndQueryAlertEvents() async throws {
        let now = Date().timeIntervalSince1970
        let ruleId = UUID().uuidString
        try await store.insertAlertEvent(AlertEvent(
            id: nil, timestamp: now, ruleId: ruleId,
            displayName: "Chrome 超过 1GB", triggerValue: 1_100_000_000
        ))

        let events = try await store.queryAlertEvents(since: now - 60, until: now + 60)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].ruleId, ruleId)
        XCTAssertEqual(events[0].displayName, "Chrome 超过 1GB")
        XCTAssertEqual(events[0].triggerValue, 1_100_000_000, accuracy: 0.001)
    }

    func testQueryAlertEventsRespectsTimeRange() async throws {
        let now = Date().timeIntervalSince1970
        try await store.insertAlertEvent(AlertEvent(
            id: nil, timestamp: now - 7200, ruleId: "old",
            displayName: "old", triggerValue: 1))
        try await store.insertAlertEvent(AlertEvent(
            id: nil, timestamp: now, ruleId: "recent",
            displayName: "recent", triggerValue: 1))

        let events = try await store.queryAlertEvents(since: now - 60, until: now + 60)
        XCTAssertEqual(events.map(\.ruleId), ["recent"])
    }

    func testQueryAlertEventsOrderedByTimestamp() async throws {
        let now = Date().timeIntervalSince1970
        try await store.insertAlertEvent(AlertEvent(
            id: nil, timestamp: now, ruleId: "second",
            displayName: "second", triggerValue: 1))
        try await store.insertAlertEvent(AlertEvent(
            id: nil, timestamp: now - 30, ruleId: "first",
            displayName: "first", triggerValue: 1))

        let events = try await store.queryAlertEvents(since: now - 60, until: now + 60)
        XCTAssertEqual(events.map(\.ruleId), ["first", "second"])
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/Documents/traffic-monitoring && swift test --filter DataStoreTests/testInsertAndQueryAlertEvents`
Expected: FAIL to compile — `AlertEvent`, `insertAlertEvent`, `queryAlertEvents` don't exist yet.

- [ ] **Step 3: Create the `AlertEvent` model**

Create `Sources/Models/AlertEvent.swift`:

```swift
import Foundation
import GRDB

/// 一次告警规则触发的记录。
///
/// 跟 `AlertRule`（存在 UserDefaults 里的配置）不是一回事：这张表存的是
/// "历史上真的响过几次、什么时候、因为什么值"，用来在流量图上画 ▲ 标记。
struct AlertEvent: Identifiable, Codable {
    /// 自增主键
    var id: Int64?

    /// 触发时刻（Unix 秒）
    let timestamp: TimeInterval

    /// 对应哪条 `AlertRule`（`rule.id.uuidString`）
    let ruleId: String

    /// 触发时展示用的文案（比如"Chrome 超过 1GB"），冗余存一份避免规则被
    /// 删除/改名后历史记录变得无法理解
    let displayName: String

    /// 触发时的具体数值（字节数或速率，取决于规则类型）
    let triggerValue: Double
}

extension AlertEvent: TableRecord, FetchableRecord, MutablePersistableRecord {
    enum Columns {
        static let id = Column(CodingKeys.id)
        static let timestamp = Column(CodingKeys.timestamp)
        static let ruleId = Column(CodingKeys.ruleId)
        static let displayName = Column(CodingKeys.displayName)
        static let triggerValue = Column(CodingKeys.triggerValue)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
```

- [ ] **Step 4: Add the `alertEvent` table to `DataStore.setup`**

In `Sources/Core/DataStore.swift`, inside the same `try writer.write { db in ... }` block used in Task 1 (right after the `trafficEvent` table/index/migration block, still before the closing `}` of that `write`), add:

```swift
            try db.create(table: "alertEvent", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp", .double).notNull().indexed()
                t.column("ruleId", .text).notNull()
                t.column("displayName", .text).notNull()
                t.column("triggerValue", .double).notNull()
            }
```

- [ ] **Step 5: Implement `insertAlertEvent` and `queryAlertEvents`**

Add these methods to `DataStore`, after `insertEvents` (after the method modified in Task 1):

```swift
    /// 记一条告警触发事件。告警触发很稀疏（不是每帧都发生），不需要像
    /// `insertEvents` 那样分块批量写。
    func insertAlertEvent(_ event: AlertEvent) throws {
        guard let writer = dbWriter else { return }
        var event = event
        try writer.write { db in
            try event.insert(db)
        }
    }

    /// 查询指定时间范围内触发过的告警，按时间升序 —— 用于在流量图上画 ▲ 标记。
    func queryAlertEvents(
        since: TimeInterval,
        until: TimeInterval = Date().timeIntervalSince1970
    ) throws -> [AlertEvent] {
        guard let writer = dbWriter else { return [] }
        return try writer.read { db in
            try AlertEvent
                .filter(AlertEvent.Columns.timestamp >= since
                        && AlertEvent.Columns.timestamp <= until)
                .order(AlertEvent.Columns.timestamp)
                .fetchAll(db)
        }
    }
```

- [ ] **Step 6: Run test to verify it passes**

Run: `cd ~/Documents/traffic-monitoring && swift test --filter DataStoreTests/testInsertAndQueryAlertEvents`
Expected: PASS

Run: `cd ~/Documents/traffic-monitoring && swift test --filter DataStoreTests/testQueryAlertEventsRespectsTimeRange`
Expected: PASS

Run: `cd ~/Documents/traffic-monitoring && swift test --filter DataStoreTests/testQueryAlertEventsOrderedByTimestamp`
Expected: PASS

- [ ] **Step 7: Run the full test suite to check for regressions**

Run: `cd ~/Documents/traffic-monitoring && swift test`
Expected: PASS (all 196+ existing tests plus the new ones added in this plan)

- [ ] **Step 8: Commit**

```bash
cd ~/Documents/traffic-monitoring
git add Sources/Models/AlertEvent.swift Sources/Core/DataStore.swift Tests/DataStoreTests.swift
git commit -m "feat(data): persist alert trigger events for chart markers"
```

---

## What's next (not in this plan)

Once this lands, Phase 2 wires the collector to actually call `insertAlertEvent` when an `AlertRule` fires, captures `ssid` via `NEHotspotNetwork.fetchCurrent` during collection, and builds the new `MainWindowView` layout (aggregate chart, curve/heatmap toggle, network filter, export dropdown, expanded time-range presets, Peak column) on top of the four query methods this plan adds. Each of those is a separate plan per the phased approach agreed on.
