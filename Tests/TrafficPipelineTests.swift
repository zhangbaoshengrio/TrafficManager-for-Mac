import XCTest
@testable import TrafficMonitor

// ============================================================
// MARK: - TrafficPipeline 聚合与快照测试
// ============================================================

/// 聚合逻辑现在在 `TrafficPipeline` actor 内（PID → ProcessIdentifier → 累加），
/// 这里用构造出来的帧走一遍真实链路。
///
/// 用不存在的 PID：解析器会自然 fallback 到 execName 作为聚合键，
/// 测试因此不依赖机器上跑着什么应用。
final class TrafficPipelineTests: XCTestCase {
    private let pipeline = TrafficPipeline.shared

    override func setUp() async throws {
        await pipeline.reset()
    }

    override func tearDown() async throws {
        await pipeline.reset()
    }

    private func frame(_ deltas: [PIDDelta], baseline: Bool = false,
                       interval: TimeInterval = 2, at: Date = Date()) -> TrafficFrame {
        TrafficFrame(deltas: deltas, timestamp: at, interval: interval, isBaseline: baseline)
    }

    func testBaselineFrameDoesNotCountTraffic() async {
        _ = await pipeline.ingest(frame(
            [PIDDelta(pid: 999_001, execName: "basetest", bytesIn: 10_000, bytesOut: 5_000)],
            baseline: true
        ))
        let snap = await pipeline.makeSnapshot()
        let row = snap.rows.first { $0.key == "basetest" }
        XCTAssertNotNil(row, "首帧应把进程登记进来")
        XCTAssertEqual(row?.totalBytes, 0, "首帧的累计值不应计入流量")
    }

    func testDeltaFrameAccumulates() async {
        _ = await pipeline.ingest(frame([], baseline: true))
        _ = await pipeline.ingest(frame([
            PIDDelta(pid: 999_002, execName: "acc", bytesIn: 1_000, bytesOut: 500),
        ]))
        _ = await pipeline.ingest(frame([
            PIDDelta(pid: 999_002, execName: "acc", bytesIn: 2_000, bytesOut: 100),
        ], at: Date().addingTimeInterval(2)))

        let snap = await pipeline.makeSnapshot()
        let row = snap.rows.first { $0.key == "acc" }
        XCTAssertEqual(row?.totalIn, 3_000)
        XCTAssertEqual(row?.totalOut, 600)
    }

    func testMultiplePIDsWithSameKeyAggregate() async {
        _ = await pipeline.ingest(frame([], baseline: true))
        _ = await pipeline.ingest(frame([
            PIDDelta(pid: 999_010, execName: "same", bytesIn: 1_000, bytesOut: 500),
            PIDDelta(pid: 999_011, execName: "same", bytesIn: 500, bytesOut: 200),
        ]))
        let snap = await pipeline.makeSnapshot()
        let rows = snap.rows.filter { $0.key == "same" }
        XCTAssertEqual(rows.count, 1, "同一标识的多个 PID 应聚合成一行")
        XCTAssertEqual(rows[0].totalIn, 1_500)
        XCTAssertEqual(rows[0].totalOut, 700)
    }

    func testRateUsesFrameInterval() async {
        _ = await pipeline.ingest(frame([], baseline: true))
        _ = await pipeline.ingest(frame(
            [PIDDelta(pid: 999_020, execName: "rate", bytesIn: 2_000, bytesOut: 1_000)],
            interval: 2
        ))
        let snap = await pipeline.makeSnapshot()
        let row = snap.rows.first { $0.key == "rate" }
        XCTAssertEqual(row?.rxRate ?? 0, 1_000, accuracy: 1)
        XCTAssertEqual(row?.txRate ?? 0, 500, accuracy: 1)
    }

    /// 进程本帧没有流量时速率必须归零，否则表格会一直挂着上一次的速率
    func testIdleProcessRateResetsToZero() async {
        _ = await pipeline.ingest(frame([], baseline: true))
        _ = await pipeline.ingest(frame(
            [PIDDelta(pid: 999_030, execName: "idle", bytesIn: 2_000, bytesOut: 0)]
        ))
        _ = await pipeline.ingest(frame(
            [PIDDelta(pid: 999_031, execName: "other", bytesIn: 100, bytesOut: 0)],
            at: Date().addingTimeInterval(2)
        ))
        let snap = await pipeline.makeSnapshot()
        let row = snap.rows.first { $0.key == "idle" }
        XCTAssertEqual(row?.rxRate, 0)
        XCTAssertEqual(row?.totalIn, 2_000, "速率归零不应影响累计量")
    }

    func testSnapshotSortedByTotalDescending() async {
        _ = await pipeline.ingest(frame([], baseline: true))
        _ = await pipeline.ingest(frame([
            PIDDelta(pid: 999_040, execName: "small", bytesIn: 10, bytesOut: 0),
            PIDDelta(pid: 999_041, execName: "big", bytesIn: 10_000, bytesOut: 0),
            PIDDelta(pid: 999_042, execName: "mid", bytesIn: 500, bytesOut: 0),
        ]))
        let snap = await pipeline.makeSnapshot()
        let keys = snap.rows.prefix(3).map(\.key)
        XCTAssertEqual(keys, ["big", "mid", "small"])
        XCTAssertEqual(snap.totalBytes, 10_510)
    }

    /// 窗口不可见时不生成快照 —— 这是把主线程从每帧唤醒中解放出来的关键
    func testHiddenUIProducesNoSnapshot() async {
        await pipeline.setUIVisible(false)
        let pushed = await pipeline.ingest(frame(
            [PIDDelta(pid: 999_050, execName: "hidden", bytesIn: 1_000, bytesOut: 0)]
        ))
        XCTAssertNil(pushed, "不可见时不应生成快照")

        await pipeline.setUIVisible(true)
        let resumed = await pipeline.ingest(frame(
            [PIDDelta(pid: 999_050, execName: "hidden", bytesIn: 1_000, bytesOut: 0)],
            at: Date().addingTimeInterval(2)
        ))
        XCTAssertNotNil(resumed, "重新可见时应立刻补一帧")
        XCTAssertEqual(resumed?.rows.first { $0.key == "hidden" }?.totalIn, 2_000,
                       "不可见期间的流量仍要照常累计")
    }

    /// 两帧间隔小于 uiRefreshInterval 时不重复推送
    func testSnapshotThrottled() async {
        await pipeline.setUIVisible(true)
        let now = Date()
        _ = await pipeline.ingest(frame([], baseline: true, at: now))
        let tooSoon = await pipeline.ingest(frame(
            [PIDDelta(pid: 999_060, execName: "throttle", bytesIn: 1, bytesOut: 0)],
            at: now.addingTimeInterval(Constants.uiRefreshInterval / 2)
        ))
        XCTAssertNil(tooSoon)

        let due = await pipeline.ingest(frame(
            [PIDDelta(pid: 999_060, execName: "throttle", bytesIn: 1, bytesOut: 0)],
            at: now.addingTimeInterval(Constants.uiRefreshInterval + 0.1)
        ))
        XCTAssertNotNil(due)
    }
}

// ============================================================
// MARK: - 统计窗口切换
// ============================================================

/// 切换「今日 / 本周 / 本月」时，管线的历史部分必须是**替换**而不是累加，
/// 且不能动到尚未落库的实时部分。
final class TimeRangeReloadTests: XCTestCase {
    private let pipeline = TrafficPipeline.shared

    override func setUp() async throws { await pipeline.reset() }
    override func tearDown() async throws { await pipeline.reset() }

    private func summary(_ key: String, in bytesIn: Int64, out bytesOut: Int64) -> ProcessSummary {
        ProcessSummary(processKey: key, bundleId: nil, displayName: key,
                       totalIn: bytesIn, totalOut: bytesOut, sampleCount: 1,
                       firstSeen: 0, lastSeen: 0)
    }

    private func row(_ key: String) async -> ProcessRow? {
        await pipeline.makeSnapshot().rows.first { $0.key == key }
    }

    private func feed(_ deltas: [PIDDelta]) async {
        _ = await pipeline.ingest(TrafficFrame(deltas: [], timestamp: Date(),
                                               interval: 0, isBaseline: true))
        _ = await pipeline.ingest(TrafficFrame(deltas: deltas, timestamp: Date(),
                                               interval: 2, isBaseline: false))
    }

    /// 指定时间戳的一帧：跨界测试要精确控制数据落在哪个桶
    private func frame(_ deltas: [PIDDelta], at date: Date) -> TrafficFrame {
        TrafficFrame(deltas: deltas, timestamp: date, interval: 2, isBaseline: false)
    }

    func testReloadReplacesRatherThanAccumulates() async {
        await pipeline.reloadHistorical([summary("a", in: 1_000, out: 100)])
        let first = await row("a")
        XCTAssertEqual(first?.totalIn, 1_000)

        // 换一个更大的窗口 → 应替换为新值，而不是变成 1000+5000
        await pipeline.reloadHistorical([summary("a", in: 5_000, out: 500)])
        let second = await row("a")
        XCTAssertEqual(second?.totalIn, 5_000)
        XCTAssertEqual(second?.totalOut, 500)
    }

    func testLiveBytesSurviveReload() async {
        await feed([PIDDelta(pid: 999_100, execName: "live", bytesIn: 700, bytesOut: 300)])
        let live = await row("live")
        XCTAssertEqual(live?.totalIn, 700)

        await pipeline.reloadHistorical([summary("live", in: 2_000, out: 0)])
        let merged = await row("live")
        // 历史 2000 + 尚未落库的实时 700
        XCTAssertEqual(merged?.totalIn, 2_700)
        XCTAssertEqual(merged?.totalOut, 300)
    }

    /// 窗口缩小后落在窗口外的进程，其历史必须清零，否则总数会带上窗口外的流量
    func testProcessOutsideNewWindowIsDropped() async {
        await pipeline.reloadHistorical([
            summary("kept", in: 100, out: 0),
            summary("dropped", in: 900, out: 0),
        ])
        let wide = await pipeline.makeSnapshot()
        XCTAssertEqual(wide.totalBytes, 1_000)

        await pipeline.reloadHistorical([summary("kept", in: 100, out: 0)])
        let narrow = await pipeline.makeSnapshot()
        XCTAssertEqual(narrow.totalBytes, 100)
        XCTAssertNil(narrow.rows.first { $0.key == "dropped" }, "窗口外且无实时数据的进程应移出列表")
    }

    /// 窗口内的实时数据在重载后照旧保留（不能被顺手清掉）
    func testReloadKeepsLiveBytesInsideWindow() async {
        let now = Date()
        _ = await pipeline.ingest(frame([
            PIDDelta(pid: 999_110, execName: "inflight", bytesIn: 700, bytesOut: 300),
        ], at: now))

        await pipeline.reloadHistorical([summary("inflight", in: 2_000, out: 0)],
                                        since: now.addingTimeInterval(-60).timeIntervalSince1970)

        let merged = await row("inflight")
        XCTAssertEqual(merged?.totalIn, 2_700)
        XCTAssertEqual(merged?.totalOut, 300)
    }

    /// **跨零点回归**：窗口前移后，窗口外的**未落库**数据不能再算进当前窗口。
    ///
    /// 真机场景：00:00 重载「今日」时，23:59 那个桶还没落库 —— 桶要等封口，
    /// flush 每 15 秒才跑一次。旧实现把 live 原样留着，于是「今日」里混进
    /// 昨天最后一分钟的流量，而且会一直留着，直到下次重载才被数据库结果冲掉。
    func testReloadDropsLiveBytesOutsideWindow() async {
        let now = Date()
        let windowStart = now.addingTimeInterval(-60)
        let previousBucket = now.addingTimeInterval(-120)

        _ = await pipeline.ingest(frame([
            PIDDelta(pid: 999_120, execName: "tail", bytesIn: 900, bytesOut: 100),
        ], at: previousBucket))
        _ = await pipeline.ingest(frame([
            PIDDelta(pid: 999_121, execName: "fresh", bytesIn: 300, bytesOut: 0),
        ], at: now))
        let before = await pipeline.makeSnapshot()
        XCTAssertEqual(before.totalBytes, 1_300, "重载前两笔都在窗口里（窗口未裁剪）")

        await pipeline.reloadHistorical([], since: windowStart.timeIntervalSince1970)

        let after = await pipeline.makeSnapshot()
        let tail = await row("tail")
        let fresh = await row("fresh")
        XCTAssertNil(tail, "窗口外且无实时数据的进程应移出列表")
        XCTAssertEqual(fresh?.totalIn, 300)
        XCTAssertEqual(after.totalBytes, 300, "窗口外那一分钟不能留在实时部分")
    }

    /// 窗口外的桶落库时也不能转成「窗口内已落库」的历史 ——
    /// 否则跨零点后「今日」还是会把昨天那部分算进来，只是从 live 挪进了 historical。
    func testFlushDoesNotMoveOutOfWindowBytesIntoHistorical() async {
        let now = Date()
        _ = await pipeline.ingest(frame([
            PIDDelta(pid: 999_130, execName: "oldbucket", bytesIn: 500, bytesOut: 0),
        ], at: now.addingTimeInterval(-120)))
        _ = await pipeline.ingest(frame([
            PIDDelta(pid: 999_131, execName: "newbucket", bytesIn: 200, bytesOut: 0),
        ], at: now))

        await pipeline.reloadHistorical([], since: now.addingTimeInterval(-60).timeIntervalSince1970)
        await pipeline.flush(force: true)          // 两个桶都写出去（含窗口外那个）

        let snap = await pipeline.makeSnapshot()
        let kept = await row("newbucket")
        let dropped = await row("oldbucket")
        XCTAssertEqual(kept?.totalIn, 200, "窗口内的照常落账")
        XCTAssertNil(dropped)
        XCTAssertEqual(snap.totalBytes, 200, "窗口外落库的字节不该进入当前窗口")
    }

    /// 帧越过窗口终点 → 标记「窗口过期」，等 CollectorService 取走并重查。
    /// 这是跨零点自动切换「今日」的触发条件。
    func testFramePastWindowEndRequestsRefresh() async {
        let now = Date()
        await pipeline.reloadHistorical(
            [],
            since: now.addingTimeInterval(-60).timeIntervalSince1970,
            until: now.addingTimeInterval(60).timeIntervalSince1970
        )

        _ = await pipeline.ingest(frame([], at: now.addingTimeInterval(30)))
        let early = await pipeline.takeWindowRefreshRequest()
        XCTAssertFalse(early, "窗口还没到头，不该请求重查")

        _ = await pipeline.ingest(frame([], at: now.addingTimeInterval(61)))
        let expired = await pipeline.takeWindowRefreshRequest()
        XCTAssertTrue(expired, "越过终点必须请求重查")
        let consumed = await pipeline.takeWindowRefreshRequest()
        XCTAssertFalse(consumed, "取走即清零，不能每帧都重查")
    }

    /// 有实时数据的进程即使不在新窗口的历史里，也要留在列表上（历史归零、实时保留）
    func testActiveProcessStaysWithZeroedHistory() async {
        await feed([PIDDelta(pid: 999_101, execName: "active", bytesIn: 50, bytesOut: 0)])
        await pipeline.reloadHistorical([summary("active", in: 5_000, out: 0)])
        let withHistory = await row("active")
        XCTAssertEqual(withHistory?.totalIn, 5_050)

        await pipeline.reloadHistorical([])   // 新窗口里没有它的历史
        let liveOnly = await row("active")
        XCTAssertEqual(liveOnly?.totalIn, 50, "只剩尚未落库的实时部分")
    }
}

// ============================================================
// MARK: - 时间窗口边界
// ============================================================

final class TimeRangeBoundaryTests: XCTestCase {
    /// 标签写着「今日」，起点就该是今天零点，而不是往前推 24 小时
    @MainActor
    func testTodayStartsAtMidnight() {
        let start = DashboardViewModel.TimeRange.today.start
        let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: start)
        XCTAssertEqual(parts.hour, 0)
        XCTAssertEqual(parts.minute, 0)
        XCTAssertEqual(parts.second, 0)
        XCTAssertTrue(Calendar.current.isDateInToday(start))
    }

    @MainActor
    func testAllStartsAreInThePast() {
        for range in DashboardViewModel.TimeRange.allCases {
            XCTAssertLessThanOrEqual(range.start, Date(), "\(range.rawValue) 起点不应在未来")
        }
    }

    /// 窗口终点就是**下一个日历边界**：跨过它，窗口里装的就是上一段的数据了
    /// —— 必须重查，否则「今日」会一直停在上一天。`.custom` 排除在生成的
    /// 通用循环外：它的 `start`/`end` 各自独立退回 `now`，不是一对有意义的
    /// "起止边界"，靠 `resolvedInterval` 才是真正生效的语义。
    @MainActor
    func testRangeEndsAtNextCalendarBoundary() {
        let calendar = Calendar.current
        let now = Date()
        let today = DashboardViewModel.TimeRange.today
        let yesterday = DashboardViewModel.TimeRange.yesterday
        let last7 = DashboardViewModel.TimeRange.last7Days
        let last30 = DashboardViewModel.TimeRange.last30Days
        let thisMonth = DashboardViewModel.TimeRange.thisMonth
        let lastMonth = DashboardViewModel.TimeRange.lastMonth

        // 「今日」终点 = 明天零点
        let dayEnd = today.endDate(at: now, calendar: calendar)
        XCTAssertEqual(calendar.startOfDay(for: dayEnd), dayEnd)

        // 「昨天」终点 = 今天零点
        XCTAssertEqual(yesterday.endDate(at: now, calendar: calendar),
                       calendar.startOfDay(for: now))

        // 「Last 7/30 days」终点 = 明天零点，跟「今日」是同一套边界——
        // 滚动窗口，不是日历周期边界。
        XCTAssertEqual(last7.endDate(at: now, calendar: calendar),
                       calendar.dateInterval(of: .day, for: now)?.end)
        XCTAssertEqual(last30.endDate(at: now, calendar: calendar),
                       calendar.dateInterval(of: .day, for: now)?.end)

        // 「本月」终点 = 下个月一号零点
        let thisMonthEnd = thisMonth.endDate(at: now, calendar: calendar)
        XCTAssertEqual(calendar.dateInterval(of: .month, for: thisMonthEnd)?.start, thisMonthEnd)

        // 「上个月」终点 = 本月一号零点
        XCTAssertEqual(lastMonth.endDate(at: now, calendar: calendar),
                       calendar.dateInterval(of: .month, for: now)?.start)

        for range in DashboardViewModel.TimeRange.allCases where range != .custom {
            XCTAssertGreaterThan(range.endDate(at: now, calendar: calendar),
                                 range.startDate(at: now, calendar: calendar),
                                 "\(range.rawValue) 终点必须在起点之后")
        }
    }

    /// 夏令时那天不是 24 小时：终点得落在下一个日历边界上，不能拿 +86400 推。
    /// 2026-03-08 是美东夏令时开始日（当地只有 23 小时）。
    @MainActor
    func testDayWindowSpansCalendarDayNot24Hours() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let noon = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12))!

        let start = DashboardViewModel.TimeRange.today.startDate(at: noon, calendar: calendar)
        let end = DashboardViewModel.TimeRange.today.endDate(at: noon, calendar: calendar)

        XCTAssertEqual(start, calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 0)))
        XCTAssertEqual(end, calendar.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 0)),
                       "终点应是次日零点，而不是当天零点 + 24 小时")
        XCTAssertEqual(end.timeIntervalSince(start), 23 * 3_600, accuracy: 1)
    }

    /// 「Last 7 days」/「Last 30 days」按名字来说该正好跨 7/30 个自然日
    /// （过去 6/29 个完整自然日 + 今天）。
    @MainActor
    func testLast7And30DaysSpanExactCalendarDayCounts() {
        let calendar = Calendar.current
        let now = Date()
        let last7 = DashboardViewModel.TimeRange.last7Days
        let last30 = DashboardViewModel.TimeRange.last30Days

        let days7 = calendar.dateComponents([.day], from: last7.startDate(at: now, calendar: calendar),
                                            to: last7.endDate(at: now, calendar: calendar)).day
        XCTAssertEqual(days7, 7, "Last 7 days 应该正好跨 7 个自然日")

        let days30 = calendar.dateComponents([.day], from: last30.startDate(at: now, calendar: calendar),
                                             to: last30.endDate(at: now, calendar: calendar)).day
        XCTAssertEqual(days30, 30, "Last 30 days 应该正好跨 30 个自然日")
    }

    /// 夏令时那天不是 24 小时：「Last 7/30 days」的起点得用日历天数往前推，
    /// 不能拿固定秒数减，否则夏令时切换附近那几天会算出偏差。
    /// 2026-03-08 是美东夏令时开始日。
    @MainActor
    func testLast7And30DaysUseCalendarDaysNotFixedSecondsAcrossDST() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let noon = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12))!

        let last7 = DashboardViewModel.TimeRange.last7Days
        let last30 = DashboardViewModel.TimeRange.last30Days

        XCTAssertEqual(calendar.dateComponents([.day], from: last7.startDate(at: noon, calendar: calendar),
                                               to: last7.endDate(at: noon, calendar: calendar)).day, 7)
        // 2026-03-08 往前推 6 个自然日 = 2026-03-02 零点
        XCTAssertEqual(last7.startDate(at: noon, calendar: calendar),
                       calendar.date(from: DateComponents(year: 2026, month: 3, day: 2, hour: 0)))

        XCTAssertEqual(calendar.dateComponents([.day], from: last30.startDate(at: noon, calendar: calendar),
                                               to: last30.endDate(at: noon, calendar: calendar)).day, 30)
        // 2026-03-08 往前推 29 个自然日 = 2026-02-07 零点
        XCTAssertEqual(last30.startDate(at: noon, calendar: calendar),
                       calendar.date(from: DateComponents(year: 2026, month: 2, day: 7, hour: 0)))
    }

    /// 「上个月」跨年边界：现在是 1 月时，上个月该是去年 12 月，不是"月份 0"
    /// 或者别的算错的结果。
    @MainActor
    func testLastMonthCrossesYearBoundary() {
        let calendar = Calendar.current
        let january = calendar.date(from: DateComponents(year: 2027, month: 1, day: 15, hour: 10))!

        let lastMonth = DashboardViewModel.TimeRange.lastMonth
        let start = lastMonth.startDate(at: january, calendar: calendar)
        let components = calendar.dateComponents([.year, .month, .day], from: start)

        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 12)
        XCTAssertEqual(components.day, 1)
    }

    /// `resolvedInterval` 是 `.custom` 唯一真正生效的解析路径：非 custom 的
    /// case 应该原样等于 `start...end`。
    @MainActor
    func testResolvedIntervalPassesThroughNonCustomCases() {
        let now = Date()
        for range in DashboardViewModel.TimeRange.allCases where range != .custom {
            let resolved = range.resolvedInterval(customStart: now, customEnd: now)
            XCTAssertEqual(resolved.start, range.start)
            XCTAssertEqual(resolved.end, range.end)
        }
    }

    /// custom 场景下，就算调用方把起止日期传反了（`customStart` 比
    /// `customEnd` 晚），也要能排出正确顺序的区间。
    @MainActor
    func testResolvedIntervalSortsCustomBoundsRegardlessOfInputOrder() {
        let calendar = Calendar.current
        let earlier = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))!
        let later = calendar.date(from: DateComponents(year: 2026, month: 9, day: 15))!

        let forward = DashboardViewModel.TimeRange.custom.resolvedInterval(customStart: earlier, customEnd: later)
        XCTAssertEqual(forward.start, earlier)
        XCTAssertEqual(forward.end, later)

        let reversed = DashboardViewModel.TimeRange.custom.resolvedInterval(customStart: later, customEnd: earlier)
        XCTAssertEqual(reversed.start, earlier, "起止传反了也要排出正确顺序")
        XCTAssertEqual(reversed.end, later)
    }
}

// ============================================================
// MARK: - 跨零点自动重载（CollectorService 接线）
// ============================================================

/// 跨过日历边界后窗口要自动重查 —— 否则「今日」会一直停在上一天，
/// 用户看到的就是「从打开应用累积到现在」。
@MainActor
final class TimeRangeRolloverTests: XCTestCase {
    private let pipeline = TrafficPipeline.shared
    private var savedTimeRange: DashboardViewModel.TimeRange = .today

    override func setUp() async throws {
        await pipeline.reset()
        savedTimeRange = Preferences.timeRange
    }

    override func tearDown() async throws {
        Preferences.timeRange = savedTimeRange
        await pipeline.reset()
    }

    private func frame(_ deltas: [PIDDelta], at date: Date) -> TrafficFrame {
        TrafficFrame(deltas: deltas, timestamp: date, interval: 2, isBaseline: false)
    }

    /// 整条触发链路：帧越过窗口终点 → 取标记 → 按当前范围重查 → 窗口外的实时数据退出。
    func testFramePastWindowEndReloadsCurrentRange() async {
        Preferences.timeRange = .today

        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)!

        // 像「昨天就开着」那样装载昨天的窗口，并写入昨天的一笔（尚未落库）
        await pipeline.reloadHistorical([], since: startOfYesterday.timeIntervalSince1970,
                                        until: startOfToday.timeIntervalSince1970)
        _ = await pipeline.ingest(frame([
            PIDDelta(pid: 999_400, execName: "stale", bytesIn: 800, bytesOut: 100),
        ], at: startOfToday.addingTimeInterval(-60)))

        // 00:00:01 的那一帧越过「今天」的起点 —— 对昨天的窗口来说就是越过了终点
        _ = await pipeline.ingest(frame([
            PIDDelta(pid: 999_401, execName: "current", bytesIn: 200, bytesOut: 0),
        ], at: startOfToday.addingTimeInterval(1)))

        let expired = await pipeline.takeWindowRefreshRequest()   // 采集循环里的判定
        XCTAssertTrue(expired, "越过窗口终点应请求重查")
        await CollectorService.shared.reloadCurrentTimeRange()    // 循环随后做的事

        let snap = await pipeline.makeSnapshot()
        XCTAssertNil(snap.rows.first { $0.key == "stale" }, "昨天的实时数据应随窗口重载退出")
        XCTAssertEqual(snap.rows.first { $0.key == "current" }?.totalIn, 200)
    }
}

// ============================================================
// MARK: - Custom 范围的持久化
// ============================================================

final class PreferencesCustomRangeTests: XCTestCase {
    private var savedStart: Date = Date()
    private var savedEnd: Date = Date()

    override func setUp() {
        savedStart = Preferences.customRangeStart
        savedEnd = Preferences.customRangeEnd
    }

    override func tearDown() {
        Preferences.customRangeStart = savedStart
        Preferences.customRangeEnd = savedEnd
    }

    /// 写进去的日期原样读得出来——跟其它 `Preferences` 属性同一种读写模式。
    func testCustomRangeRoundTrips() {
        let calendar = Calendar.current
        let start = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 9, day: 15))!

        Preferences.customRangeStart = start
        Preferences.customRangeEnd = end

        XCTAssertEqual(Preferences.customRangeStart, start)
        XCTAssertEqual(Preferences.customRangeEnd, end)
    }
}

// ============================================================
// MARK: - 落库桶的峰值
// ============================================================

/// 桶会把一分钟内的突发摊平（iperf3 一次短测 = 一个点、一个均值），
/// 所以每行额外记下桶内见过的最高瞬时速率。这里走完整链路：
/// 帧 → 分桶 → flush 落库 → 时间线查询。
final class BucketPeakTests: XCTestCase {
    private let pipeline = TrafficPipeline.shared

    override func setUp() async throws {
        await pipeline.reset()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BucketPeakTests")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await DataStore.shared.setup(at: dir.appendingPathComponent("peak.db"))
    }

    override func tearDown() async throws {
        await pipeline.reset()
    }

    private func frame(_ deltas: [PIDDelta], at: Date, interval: TimeInterval = 2) -> TrafficFrame {
        TrafficFrame(deltas: deltas, timestamp: at, interval: interval, isBaseline: false)
    }

    /// 100 MB 的 2 秒突发 + 一次小流量落在同一个 60 秒桶：
    /// 总量是两者之和，峰值必须是突发那一帧的速率，而不是「总量 ÷ 60」。
    func testBucketRecordsPeakRateNotBucketAverage() async throws {
        let key = "peak-\(UUID().uuidString)"
        // 桶内固定起点（本分钟第 5 秒），避免测试恰好跨分钟
        let minuteStart = (Date().timeIntervalSince1970 / 60).rounded(.down) * 60
        let base = minuteStart + 5
        let burst: Int64 = 1 * 1024 * 1024
        let trickle: Int64 = 1_024

        _ = await pipeline.ingest(frame(
            [PIDDelta(pid: 999_500, execName: key, bytesIn: burst, bytesOut: 0)],
            at: Date(timeIntervalSince1970: base), interval: 2))
        _ = await pipeline.ingest(frame(
            [PIDDelta(pid: 999_501, execName: key, bytesIn: trickle, bytesOut: 0)],
            at: Date(timeIntervalSince1970: base + 2), interval: 2))
        await pipeline.flush(force: true)

        // 收窄到一个桶（整窗网格的点数由 since/until 决定）
        let points = try await DataStore.shared.queryTimeline(
            processKey: key, since: minuteStart, until: minuteStart + 1, bucketSeconds: 60)
        let point = try XCTUnwrap(points.first)
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(point.bytesIn, burst + trickle, "总量仍是一分钟内的求和")
        XCTAssertEqual(point.peakIn, Double(burst) / 2, accuracy: 1,
                       "峰值应是突发那一帧的瞬时速率")
        XCTAssertLessThan(Double(burst) / 60, point.peakIn,
                          "桶均值明显低于峰值，两者不能混为一谈")
    }
}

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

// ============================================================
// MARK: - 排除进程
// ============================================================

final class ExcludedProcessTests: XCTestCase {
    private let pipeline = TrafficPipeline.shared

    override func setUp() async throws {
        await pipeline.reset()
        await pipeline.setExcludedProcesses([])
    }
    override func tearDown() async throws {
        await pipeline.setExcludedProcesses([])
        await pipeline.reset()
    }

    private func feed(_ deltas: [PIDDelta]) async {
        _ = await pipeline.ingest(TrafficFrame(deltas: [], timestamp: Date(),
                                               interval: 0, isBaseline: true))
        _ = await pipeline.ingest(TrafficFrame(deltas: deltas, timestamp: Date(),
                                               interval: 2, isBaseline: false))
    }

    func testExcludedProcessIsNotCounted() async {
        await pipeline.setExcludedProcesses(["noisy"])
        await feed([
            PIDDelta(pid: 999_200, execName: "noisy", bytesIn: 9_000, bytesOut: 0),
            PIDDelta(pid: 999_201, execName: "wanted", bytesIn: 100, bytesOut: 0),
        ])
        let snapshot = await pipeline.makeSnapshot()
        XCTAssertNil(snapshot.rows.first { $0.key == "noisy" })
        XCTAssertEqual(snapshot.rows.first { $0.key == "wanted" }?.totalIn, 100)
        XCTAssertEqual(snapshot.totalBytes, 100, "被排除的进程不应计入总数")
    }

    /// 改设置后应立即生效，不需要重启 —— 已累计的数据一并清出
    func testSettingExclusionPurgesExistingStats() async {
        await feed([PIDDelta(pid: 999_210, execName: "later", bytesIn: 5_000, bytesOut: 0)])
        let before = await pipeline.makeSnapshot()
        XCTAssertEqual(before.totalBytes, 5_000)

        await pipeline.setExcludedProcesses(["later"])
        let after = await pipeline.makeSnapshot()
        XCTAssertNil(after.rows.first { $0.key == "later" })
        XCTAssertEqual(after.totalBytes, 0)
    }

    func testMatchingIsCaseInsensitive() async {
        await pipeline.setExcludedProcesses(["mdnsresponder"])
        await feed([PIDDelta(pid: 999_220, execName: "mDNSResponder", bytesIn: 500, bytesOut: 0)])
        let snapshot = await pipeline.makeSnapshot()
        XCTAssertTrue(snapshot.rows.isEmpty)
    }

    func testNonMatchingNameIsUnaffected() async {
        await pipeline.setExcludedProcesses(["something-else"])
        await feed([PIDDelta(pid: 999_230, execName: "keepme", bytesIn: 42, bytesOut: 0)])
        let snapshot = await pipeline.makeSnapshot()
        XCTAssertEqual(snapshot.rows.first { $0.key == "keepme" }?.totalIn, 42)
    }
}

// ============================================================
// MARK: - 排除列表解析
// ============================================================

final class ExcludedListParsingTests: XCTestCase {
    func testSplitsOnCommasAndNewlines() {
        let parsed = Preferences.parseExcluded("a, b，c\nd")
        XCTAssertEqual(parsed, ["a", "b", "c", "d"], "半角逗号、全角逗号、换行都应作为分隔符")
    }

    func testTrimsAndLowercases() {
        XCTAssertEqual(Preferences.parseExcluded("  mDNSResponder  ,  WeChat "),
                       ["mdnsresponder", "wechat"])
    }

    func testDropsEmptyEntries() {
        XCTAssertEqual(Preferences.parseExcluded(",,  ,a,"), ["a"])
    }

    func testEmptyInputYieldsEmptySet() {
        XCTAssertTrue(Preferences.parseExcluded("   ").isEmpty)
    }
}

// ============================================================
// MARK: - 行内 Sparkline
// ============================================================

/// 默认关闭，开启后才维护历史缓冲。
final class SparklineTests: XCTestCase {
    private let pipeline = TrafficPipeline.shared

    override func setUp() async throws {
        await pipeline.reset()
        await pipeline.setSparklineEnabled(false)
    }
    override func tearDown() async throws {
        await pipeline.setSparklineEnabled(false)
        await pipeline.reset()
    }

    private func tick(_ bytesIn: Int64, at offset: TimeInterval) async {
        _ = await pipeline.ingest(TrafficFrame(
            deltas: [PIDDelta(pid: 999_300, execName: "sp", bytesIn: bytesIn, bytesOut: 0)],
            timestamp: Date().addingTimeInterval(offset), interval: 2, isBaseline: false))
    }

    private func spark() async -> [Double] {
        await pipeline.makeSnapshot().rows.first { $0.key == "sp" }?.spark ?? []
    }

    func testDisabledKeepsHistoryEmpty() async {
        for i in 0..<5 { await tick(1_000, at: Double(i) * 2) }
        let values = await spark()
        XCTAssertTrue(values.isEmpty, "关闭时不应维护历史缓冲")
    }

    func testEnabledAccumulatesRates() async {
        await pipeline.setSparklineEnabled(true)
        await tick(2_000, at: 0)     // 2000 / 2s = 1000 B/s
        await tick(4_000, at: 2)     // 4000 / 2s = 2000 B/s
        let values = await spark()
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values[0], 1_000, accuracy: 1)
        XCTAssertEqual(values[1], 2_000, accuracy: 1)
    }

    func testHistoryIsCapped() async {
        await pipeline.setSparklineEnabled(true)
        for i in 0..<(Constants.sparklineSampleCount + 25) {
            await tick(1_000, at: Double(i) * 2)
        }
        let values = await spark()
        XCTAssertEqual(values.count, Constants.sparklineSampleCount)
    }

    /// 关掉开关要把已有缓冲清干净，不能留着占内存
    func testDisablingClearsExistingHistory() async {
        await pipeline.setSparklineEnabled(true)
        for i in 0..<5 { await tick(1_000, at: Double(i) * 2) }
        let before = await spark()
        XCTAssertFalse(before.isEmpty)

        await pipeline.setSparklineEnabled(false)
        let after = await spark()
        XCTAssertTrue(after.isEmpty)
    }
}
