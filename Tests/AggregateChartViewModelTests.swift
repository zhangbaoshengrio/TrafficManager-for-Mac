import XCTest
@testable import TrafficMonitor

/// `AggregateChartViewModel` 是 `DetailViewModel` 的聚合版：同一套轮询写法，
/// 只是查询换成不按 processKey 过滤的 `queryAggregateTimeline`。
///
/// 每个测试用自己独立的 `DataStore()` 实例（不是 `.shared`）——`.shared` 一旦
/// 被某个测试 `setup()` 过，`isSetup` 守卫会让同一进程里后续的 `setup()` 静默
/// 失效，同一个测试类里的多个方法就会互相踩库，连 `resetForTesting()` 也压
/// 不住（实测：单独跑最后一个方法稳定通过，整个类一起跑就稳定失败）。
/// `AggregateChartViewModel` 的 `store` 参数正是为了让这里能注入独立实例。
final class AggregateChartViewModelTests: XCTestCase {
    private func makeStore(_ name: String) async throws -> DataStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AggregateChartViewModelTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = DataStore()
        try await store.setup(at: dir.appendingPathComponent(name))
        return store
    }

    @MainActor
    func testLoadSumsAcrossProcessesFromRealDataStore() async throws {
        let store = try await makeStore("aggregate.db")

        let now = Date().timeIntervalSince1970
        try await store.insertEvents([
            TrafficEvent(id: nil, timestamp: now, interval: 5,
                         processKey: "Chrome", bundleId: nil, displayName: "Chrome",
                         bytesIn: 1000, bytesOut: 0),
            TrafficEvent(id: nil, timestamp: now, interval: 5,
                         processKey: "Edge", bundleId: nil, displayName: "Edge",
                         bytesIn: 500, bytesOut: 0),
        ])

        let vm = AggregateChartViewModel(store: store)
        await vm.load(since: now - 3600, until: now)

        let total = vm.timeline.reduce(0) { $0 + $1.bytesIn }
        XCTAssertEqual(total, 1500, "聚合图的 ViewModel 应该把两个进程的流量加在一起")
    }

    /// 空数据库依然回填整窗网格（每个桶都补 0），不是空数组——
    /// 这是 `queryAggregateTimeline` 本来就有的语义（跟 `queryTimeline` 一致，
    /// 参见 `DataStoreTests.testQueryTimelineForUnknownProcessIsZeroNotEmpty`），
    /// ViewModel 只是原样透传，不该在这里悄悄改语义。
    @MainActor
    func testLoadOnEmptyDatabaseYieldsZeroFilledGrid() async throws {
        let store = try await makeStore("empty.db")

        let now = Date().timeIntervalSince1970
        let vm = AggregateChartViewModel(store: store)
        await vm.load(since: now - 3600, until: now)

        XCTAssertFalse(vm.timeline.isEmpty, "空库也应该回填整窗网格，不是空数组")
        XCTAssertTrue(vm.timeline.allSatisfy { $0.totalBytes == 0 && !$0.isCovered },
                      "没有任何数据时，网格里每个桶都该是「补的 0」且标记未采集")
    }

    /// Today（≤1 天）范围要按整点分桶，一天正好落成 24 根柱子，跟"按小时看"
    /// 的心智模型对齐；更长范围维持 `TimelineBucket` 原有的粗细规则不变。
    @MainActor
    func testLoadUsesHourlyBucketsForRangesUpToOneDay() async throws {
        let store = try await makeStore("hourly.db")

        // 两条事件都必须在"现在"之前——用 hourStart 的固定偏移量（比如 +1800）
        // 曾经踩过坑：如果测试恰好在整点后不到 30 分钟内跑，`hourStart+1800`
        // 会落到未来，被 `querySummary`/`queryAggregateTimeline` 默认的
        // `until = 现在` 直接过滤掉，导致这个测试的结果随"当前是几点几分"
        // 随机摆动（在一个小时的前半段必失败、后半段才会过）。改成相对
        // "现在"的小偏移量，两条事件必然都在过去，且必然落在同一个小时桶里。
        let now = Date().timeIntervalSince1970
        let hourStart = (now / 3600).rounded(.down) * 3600
        try await store.insertEvents([
            TrafficEvent(id: nil, timestamp: now - 20, interval: 5,
                         processKey: "a", bundleId: nil, displayName: "a",
                         bytesIn: 1000, bytesOut: 0),
            TrafficEvent(id: nil, timestamp: now - 10, interval: 5,
                         processKey: "a", bundleId: nil, displayName: "a",
                         bytesIn: 500, bytesOut: 0),
        ])

        let vm = AggregateChartViewModel(store: store)
        await vm.load(since: now - 86_400, until: now)

        let bucket = try XCTUnwrap(vm.timeline.first { $0.timestamp == hourStart })
        XCTAssertEqual(bucket.bytesIn, 1500, "同一小时内两条事件应该合并进同一根柱子")
    }

    /// Today 要铺出完整 24 根柱子，不管现在是几点——`until` 得是调用方明确
    /// 传入的值，而不是默认悄悄退回"现在"，否则一天没过完时柱子会越用越多，
    /// 越靠近午夜柱子越少。`load(since:until:)` 是闭区间（跟 `queryAggregateTimeline`
    /// 一致），所以这里传「今天最后一秒」而不是「明天零点」——传"明天零点"
    /// 本身会多铺出属于明天的第 25 根柱子，这个排他终点转换是调用方
    /// （`AggregateTrafficCard`）的职责，不是这个方法自己的语义。
    @MainActor
    func testLoadRespectsExplicitUntilEvenWhenInTheFuture() async throws {
        let store = try await makeStore("fullday.db")

        let now = Date().timeIntervalSince1970
        let todayStart = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        let todayEnd = todayStart + 86_400   // 明天零点，几乎总是在"现在"之后

        let vm = AggregateChartViewModel(store: store)
        await vm.load(since: todayStart, until: todayEnd - 1)

        XCTAssertEqual(vm.timeline.count, 24, "一天应该正好铺出 24 根柱子")
        XCTAssertTrue(vm.timeline.contains { $0.timestamp > now },
                     "还没到的钟点也该出现在网格里（值是 0），而不是被 until 默认成\"现在\"截断")
    }

    /// 超过 1 天的范围要按天分桶，不能落回 `TimelineBucket` 的"1 小时"档——
    /// 那一档是给 `DetailWindow` 单进程详情图用的规则，聚合图这里"1 天以内
    /// 按小时看、超过 1 天按天看"是独立的一套，不共用。
    @MainActor
    func testLoadUsesDailyBucketsForRangesLongerThanOneDay() async throws {
        let store = try await makeStore("daily.db")

        let now = Date().timeIntervalSince1970
        try await store.insertEvents([
            TrafficEvent(id: nil, timestamp: now - 20, interval: 5,
                         processKey: "a", bundleId: nil, displayName: "a",
                         bytesIn: 1000, bytesOut: 0),
        ])

        let vm = AggregateChartViewModel(store: store)
        await vm.load(since: now - 25 * 86_400, until: now)

        XCTAssertGreaterThanOrEqual(vm.timeline.count, 2, "至少要有两个点才能量出间距")
        let spacing = vm.timeline[1].timestamp - vm.timeline[0].timestamp
        XCTAssertEqual(spacing, 86_400, "超过 1 天的范围应该按天分桶，不是按小时")
    }

    /// 关键回归：按天分桶必须按**本地日历天**对齐，不能靠 SQL 的 UTC epoch
    /// 整除——那样在东八区之类的地方，"一天"的桶会对齐到本地上午 8 点，
    /// 数量也会因为跟区间端点错位而多算/少算一根。这里固定用 Asia/Shanghai
    /// 时区构造一个 4 天的窗口，断言桶数量和第一根桶的时间戳都对齐本地日历，
    /// 不管跑测试的机器自己在哪个时区。
    @MainActor
    func testLoadUsesLocalCalendarDayBoundariesNotUTC() async throws {
        let store = try await makeStore("localday.db")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!

        let now = Date()
        let todayStart = calendar.startOfDay(for: now)
        let since = calendar.date(byAdding: .day, value: -3, to: todayStart)!.timeIntervalSince1970
        let until = todayStart.timeIntervalSince1970 + 86_400 - 1

        try await store.insertEvents([
            TrafficEvent(id: nil, timestamp: now.timeIntervalSince1970 - 20, interval: 5,
                         processKey: "a", bundleId: nil, displayName: "a",
                         bytesIn: 1000, bytesOut: 0),
        ])

        let vm = AggregateChartViewModel(store: store, calendar: calendar)
        await vm.load(since: since, until: until)

        XCTAssertEqual(vm.timeline.count, 4, "3 天前零点到今天结束应该正好是 4 根本地日历天的柱子")
        XCTAssertEqual(vm.timeline.first?.timestamp, since,
                      "第一根柱子应该正好对齐本地日历天的零点（不是 UTC 零点）")
        for point in vm.timeline {
            let components = calendar.dateComponents([.hour, .minute, .second],
                                                      from: Date(timeIntervalSince1970: point.timestamp))
            XCTAssertEqual(components.hour, 0)
            XCTAssertEqual(components.minute, 0)
            XCTAssertEqual(components.second, 0)
        }
    }
}
