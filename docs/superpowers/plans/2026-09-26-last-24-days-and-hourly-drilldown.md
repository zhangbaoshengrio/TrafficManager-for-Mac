# "Last 24 days" 时间范围 + 按天下钻到小时 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把工具条的 "This week" 改成滚动的 "Last 24 days"（24 个自然日，非日历周），并让任何按天分桶的聚合图（`Last 24 days`、`This month`）支持"点一天 → 在下面钻出那一天的 24 小时图 → 点一个小时 → 表格按小时筛"。

**Architecture:** 复用现成的 `AggregateTrafficCard`/`TrafficChart` 组件——不写新图表代码，只改三处：(1) `AggregateChartViewModel` 的私有分桶规则，让长范围真正按天分桶；(2) `DashboardViewModel.TimeRange.week` 的区间算法，从日历周改成滚动 24 天窗口；(3) `MainWindowView` 新增一层嵌套状态和条件渲染，第二次实例化 `AggregateTrafficCard` 展示选中那一天的 24 小时明细。

**Tech Stack:** Swift 6.2, SwiftUI, Swift Charts, XCTest。

## Global Constraints

- Swift tools version: 5.9；部署目标 macOS 14。
- 本地化：所有面向用户的字符串都走 `L(_:)`（`Sources/Utilities/Localization.swift`），键值同时加到 `Sources/Resources/en.lproj/Localizable.strings` 和 `Sources/Resources/zh-Hans.lproj/Localizable.strings` 两个文件，不能只加一个。
- `DashboardViewModel.TimeRange` 的 Swift case 名字和 `rawValue`（`today`/`week`/`month`）不变——`week` 的 `rawValue` 是持久化标识，改名字会让已保存的用户偏好读不出来。
- 不修改 `TimelineBucket.size(for:)`（`Sources/Views/Detail/DetailWindow.swift`）——那是 `DetailWindow` 单进程详情图用的规则，这次的分桶修复只改 `AggregateChartViewModel` 自己的私有方法。
- 每个任务结束前跑一次 `cd ~/Documents/traffic-monitoring && swift test 2>&1 | grep -E "Executed [0-9]+ tests|error:|FAIL"`，确认回归通过（当前基线：214 个测试，1 个跳过——这个总数会随每个任务往上涨）。
- **已知的、跟本计划无关的偶发失败**：`AggregateChartViewModelTests.testLoadRespectsExplicitUntilEvenWhenInTheFuture` 在**接近午夜**（比如 23:40 之后）跑会失败——它断言"今天网格里有还没到的钟点"，而当天最后一小时已经过了午夜前那一刻时，网格里确实不再有未来的桶。这是这条已有测试自身的时间依赖缺陷，不是本计划任何一步引入的，本计划不修它；如果某一步的回归结果里看到**只有这一条**失败，先看当前时间是不是接近午夜，是的话忽略它、或者换个不接近午夜的时间点重跑确认，不要误以为是自己那一步改坏的。
- 提交信息按项目现有格式，末尾带：
  ```
  Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01TJxrNteL6oPeEGnmpAa7Gq
  ```

---

### Task 1: 让聚合图的长范围真正按天分桶

**Files:**
- Modify: `Sources/ViewModels/AggregateChartViewModel.swift:56-59`（`bucketSeconds(for:)` 方法体和它上面的文档注释）
- Test: `Tests/AggregateChartViewModelTests.swift`（新增一个测试方法，追加在文件末尾 `}` 之前）

**Interfaces:**
- Consumes: 无（这是最底层的一处修复，不依赖本计划的其它任务）。
- Produces: `AggregateChartViewModel.bucketSeconds(for:)` 的新行为——`range <= 86_400` 仍是 `3_600`；`range > 86_400` 现在是 `86_400`（原来是 `TimelineBucket.size(for: range)`，对 >3 天的范围会错误地退回 `3_600`）。后续任务（Task 4）依赖这个新行为让 `Last 24 days`/`This month` 渲成天柱而不是一堆小时柱。

- [ ] **Step 1: 写失败的测试**

在 `Tests/AggregateChartViewModelTests.swift` 里，紧跟着现有的
`testLoadUsesHourlyBucketsForRangesUpToOneDay` 方法（第 88 行 `}` 之后），
在类的结尾 `}`（第 111 行）之前插入：

```swift

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
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ~/Documents/traffic-monitoring && swift test --filter testLoadUsesDailyBucketsForRangesLongerThanOneDay 2>&1 | tail -20`
Expected: FAIL，`XCTAssertEqual failed: ("3600") is not equal to ("86400")`（当前代码对 25 天范围算出的间距是 3600 秒）。

- [ ] **Step 3: 修复实现**

`Sources/ViewModels/AggregateChartViewModel.swift` 当前第 56-59 行：

```swift
    /// 聚合图是给你看大局的总览，不需要跟单进程详情图一样细——
    /// ≤1 天固定按整点分桶（一天 24 根柱子，对应"按小时看"），更长范围
    /// 复用 `TimelineBucket.size(for:)`（本来就已经是按小时/半小时分的）。
    private func bucketSeconds(for range: TimeInterval) -> TimeInterval {
        range <= 86_400 ? 3_600 : TimelineBucket.size(for: range)
    }
```

替换成：

```swift
    /// 聚合图是给你看大局的总览，不需要跟单进程详情图一样细——
    /// ≤1 天固定按整点分桶（一天 24 根柱子，对应"按小时看"），超过 1 天固定
    /// 按天分桶（"Last 24 days" 铺 24 根、"This month" 铺 28-31 根）。
    ///
    /// 不复用 `TimelineBucket.size(for:)`：那是 `DetailWindow` 单进程详情图
    /// "过去 N 小时"滑块用的规则，语义是"离得越远越粗，但从不到天级"（它的
    /// `>3 天` 那一档也是返回 `3_600`），跟这里"1 天以内按小时、超过 1 天按
    /// 天"的需求不是一回事——改 `TimelineBucket.size` 本身会连带影响
    /// `DetailWindow`，所以聚合图这条规则自己单独定，不共用。
    private func bucketSeconds(for range: TimeInterval) -> TimeInterval {
        range <= 86_400 ? 3_600 : 86_400
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd ~/Documents/traffic-monitoring && swift test --filter AggregateChartViewModelTests 2>&1 | tail -30`
Expected: 该文件里全部测试通过，包括新增的 `testLoadUsesDailyBucketsForRangesLongerThanOneDay`。

- [ ] **Step 5: 跑全量回归**

Run: `cd ~/Documents/traffic-monitoring && swift test 2>&1 | grep -E "Executed [0-9]+ tests|error:|FAIL"`
Expected: `Executed 215 tests, with 1 test skipped and 0 failures (0 unexpected)`（214 + 这条新测试）。

- [ ] **Step 6: 提交**

```bash
cd ~/Documents/traffic-monitoring
git add Sources/ViewModels/AggregateChartViewModel.swift Tests/AggregateChartViewModelTests.swift
git commit -m "$(cat <<'EOF'
fix(chart): bucket long aggregate-chart ranges by day, not by hour

AggregateChartViewModel.bucketSeconds(for:) fell back to
TimelineBucket.size(for:) for ranges over a day, whose >3-day tier
returns 3_600 (1 hour) - meant for DetailWindow's per-process "past N
hours" slider, not the aggregate dashboard chart. So a 7-day or
30-day aggregate range was rendering ~168/~720 hourly bars instead of
daily ones. Give the aggregate chart its own rule: <=1 day stays
hourly, >1 day is now a flat daily bucket.

testLoadUsesDailyBucketsForRangesLongerThanOneDay: RED against the
old TimelineBucket.size delegation (spacing came out 3600, not
86400); GREEN after. Full suite: 215 tests, 1 skipped, 0 failures.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01TJxrNteL6oPeEGnmpAa7Gq
EOF
)"
```

---

### Task 2: `TimeRange.week` 改成滚动 24 天窗口

**Files:**
- Modify: `Sources/ViewModels/DashboardViewModel.swift:96-108`（`interval(at:calendar:)` 方法体和它上面的文档注释）
- Modify: `Sources/Resources/en.lproj/Localizable.strings:19`
- Modify: `Sources/Resources/zh-Hans.lproj/Localizable.strings:19`
- Modify: `Tests/TrafficPipelineTests.swift:366-368`（`testRangeEndsAtNextCalendarBoundary` 里的一段断言）
- Test: `Tests/TrafficPipelineTests.swift`（在 `TimeRangeBoundaryTests` 类里新增两个测试方法）

**Interfaces:**
- Consumes: 无，独立于 Task 1。
- Produces: `DashboardViewModel.TimeRange.week.start`/`.end`（以及 `startDate(at:calendar:)`/`endDate(at:calendar:)`）现在返回"过去 23 个完整自然日 + 今天到明天零点"，而不是日历周边界；`displayName` 现在是 "Last 24 days"/"最近24天"。后续任务不直接依赖这个改动的具体数值，只依赖它仍然是一个"用当下 `now` 重新算"的滚动窗口这一点（Task 4 的手动验证会用到）。

- [ ] **Step 1: 写失败的测试**

`Tests/TrafficPipelineTests.swift` 里，`TimeRangeBoundaryTests` 类当前第
354-396 行（`testRangeEndsAtNextCalendarBoundary` 方法 + 类结束的 `}`）：

```swift
    /// 窗口终点就是**下一个日历边界**：跨过它，窗口里装的就是上一天/上一周/上一月的
    /// 数据了 —— 必须重查，否则「今日」会一直停在上一天。
    @MainActor
    func testRangeEndsAtNextCalendarBoundary() {
        let calendar = Calendar.current
        let now = Date()
        let today = DashboardViewModel.TimeRange.today
        let week = DashboardViewModel.TimeRange.week
        let month = DashboardViewModel.TimeRange.month

        // 「今日」终点 = 明天零点
        let dayEnd = today.endDate(at: now, calendar: calendar)
        XCTAssertEqual(calendar.startOfDay(for: dayEnd), dayEnd)

        // 「本周」终点 = 下一周第一天零点（用日历的周区间做对照）
        let weekEnd = week.endDate(at: now, calendar: calendar)
        XCTAssertEqual(calendar.dateInterval(of: .weekOfYear, for: weekEnd)?.start, weekEnd)

        // 「本月」终点 = 下个月一号零点
        let monthEnd = month.endDate(at: now, calendar: calendar)
        XCTAssertEqual(calendar.dateInterval(of: .month, for: monthEnd)?.start, monthEnd)

        for range in DashboardViewModel.TimeRange.allCases {
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
}
```

把"本周终点"那一段（`// 「本周」终点 = ...` 到 `XCTAssertEqual(calendar.dateInterval(of: .weekOfYear, ...`）替换成：

```swift
        // 「Last 24 days」终点 = 明天零点，跟「今日」是同一套边界——
        // 这个 case 现在是滚动窗口，不再是日历周边界。
        let weekEnd = week.endDate(at: now, calendar: calendar)
        XCTAssertEqual(calendar.dateInterval(of: .day, for: now)?.end, weekEnd)
```

然后在 `testDayWindowSpansCalendarDayNot24Hours` 方法结束的 `}` 之后、类结束的
`}` 之前，新增两个方法：

```swift

    /// 「Last 24 days」按名字来说该是 24 个自然日：过去 23 个完整自然日 + 今天。
    @MainActor
    func testWeekSpansExactly24CalendarDays() {
        let calendar = Calendar.current
        let now = Date()
        let week = DashboardViewModel.TimeRange.week
        let start = week.startDate(at: now, calendar: calendar)
        let end = week.endDate(at: now, calendar: calendar)
        let days = calendar.dateComponents([.day], from: start, to: end).day
        XCTAssertEqual(days, 24, "Last 24 days 应该正好跨 24 个自然日")
    }

    /// 夏令时那天不是 24 小时：「Last 24 days」的起点得用日历天数往前推，
    /// 不能拿固定秒数减，否则夏令时切换附近那几天会算出偏差。
    /// 2026-03-08 是美东夏令时开始日。
    @MainActor
    func testWeekStartUsesCalendarDaysNotFixedSecondsAcrossDST() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let noon = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12))!

        let week = DashboardViewModel.TimeRange.week
        let start = week.startDate(at: noon, calendar: calendar)
        let end = week.endDate(at: noon, calendar: calendar)

        XCTAssertEqual(calendar.dateComponents([.day], from: start, to: end).day, 24)
        // 2026-03-08 往前推 23 个自然日 = 2026-02-13 零点，不受夏令时那天
        // 只有 23 小时影响（拿固定秒数减会算偏）。
        let expectedStart = calendar.date(from: DateComponents(year: 2026, month: 2, day: 13, hour: 0))
        XCTAssertEqual(start, expectedStart)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ~/Documents/traffic-monitoring && swift test --filter TimeRangeBoundaryTests 2>&1 | tail -40`
Expected: `testRangeEndsAtNextCalendarBoundary` FAIL（`week.end` 现在还是日历周边界，不等于明天零点，除非今天恰好是周日/一周最后一天——大多数情况下会失败）；`testWeekSpansExactly24CalendarDays` FAIL（现在跨 7 天不是 24 天）；`testWeekStartUsesCalendarDaysNotFixedSecondsAcrossDST` FAIL。

- [ ] **Step 3: 修复实现**

`Sources/ViewModels/DashboardViewModel.swift` 当前第 96-108 行：

```swift
    /// 当前所处周期的日历区间。
    ///
    /// 起点和终点都交给日历算：终点不是「起点 + 86400」——
    /// 夏令时切换那天只有 23 小时（或 25 小时），加固定秒数会落到隔天 01:00。
    private func interval(at now: Date, calendar: Calendar) -> DateInterval? {
        let component: Calendar.Component = switch self {
        case .today: .day
        case .week:  .weekOfYear
        case .month: .month
        }
        return calendar.dateInterval(of: component, for: now)
    }
}
```

替换成：

```swift
    /// 当前所处周期的日历区间。
    ///
    /// 起点和终点都交给日历算：终点不是「起点 + 86400」——
    /// 夏令时切换那天只有 23 小时（或 25 小时），加固定秒数会落到隔天 01:00。
    ///
    /// `.week`（展示名是 "Last 24 days"）不是日历周，是滚动窗口：过去 23 个
    /// 完整自然日 + 今天到此刻——跟 `.today` 一样每次调用都用 `now` 重新算，
    /// 随时间推移每天自动往前滚一天。case 名字和 rawValue 保持 `week` 不改
    /// （持久化标识，跟界面文字无关），只是这里的区间算法和下面的
    /// `displayName` 变了。
    private func interval(at now: Date, calendar: Calendar) -> DateInterval? {
        switch self {
        case .today:
            return calendar.dateInterval(of: .day, for: now)
        case .week:
            guard let todayInterval = calendar.dateInterval(of: .day, for: now),
                  let start = calendar.date(byAdding: .day, value: -23, to: todayInterval.start)
            else { return nil }
            return DateInterval(start: start, end: todayInterval.end)
        case .month:
            return calendar.dateInterval(of: .month, for: now)
        }
    }
}
```

`Sources/Resources/en.lproj/Localizable.strings` 第 19 行，从：

```
"range.week"               = "This week";
```

改成：

```
"range.week"               = "Last 24 days";
```

`Sources/Resources/zh-Hans.lproj/Localizable.strings` 第 19 行，从：

```
"range.week"               = "本周";
```

改成：

```
"range.week"               = "最近24天";
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd ~/Documents/traffic-monitoring && swift test --filter TimeRangeBoundaryTests 2>&1 | tail -40`
Expected: 该类里全部测试通过。

- [ ] **Step 5: 跑全量回归**

Run: `cd ~/Documents/traffic-monitoring && swift test 2>&1 | grep -E "Executed [0-9]+ tests|error:|FAIL"`
Expected: `Executed 217 tests, with 1 test skipped and 0 failures (0 unexpected)`（215 + 这两条新测试）。

- [ ] **Step 6: 提交**

```bash
cd ~/Documents/traffic-monitoring
git add Sources/ViewModels/DashboardViewModel.swift \
        Sources/Resources/en.lproj/Localizable.strings \
        Sources/Resources/zh-Hans.lproj/Localizable.strings \
        Tests/TrafficPipelineTests.swift
git commit -m "$(cat <<'EOF'
feat(range): change "This week" to a rolling "Last 24 days" window

TimeRange.week used calendar.dateInterval(of: .weekOfYear, for:) -
always exactly the current Monday-Sunday calendar week. Per user
request, it's now a rolling window (23 full calendar days back +
today), recomputed from "now" the same way .today already is, so it
shifts forward one day at a time. Swift case name and persisted
rawValue ("week") are unchanged - only the interval math and the
displayName strings ("This week"/"本周" -> "Last 24 days"/"最近24天").

testRangeEndsAtNextCalendarBoundary's week-specific assertion updated
to match .today's end-of-tomorrow semantics instead of the old
calendar-week boundary. Added testWeekSpansExactly24CalendarDays and
a DST-crossing test (calendar.date(byAdding:) arithmetic, not fixed
seconds - mirrors the existing testDayWindowSpansCalendarDayNot24Hours
pattern). Full suite: 217 tests, 1 skipped, 0 failures.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01TJxrNteL6oPeEGnmpAa7Gq
EOF
)"
```

---

### Task 3: `MainWindowView` 的两个纯函数（筛选优先级 + 标签格式化）

**Files:**
- Modify: `Sources/Views/MainWindow/MainWindowView.swift`（在 `MainWindowView` 结构体里新增两个 `static func`，紧跟在 `@State` 属性声明之后、`var body` 之前）
- Test: `Tests/MainWindowViewTests.swift`（新文件）

**Interfaces:**
- Consumes: 无，独立于 Task 1、Task 2。
- Produces:
  - `MainWindowView.effectiveFilterRange(day: ClosedRange<TimeInterval>?, hour: ClosedRange<TimeInterval>?) -> ClosedRange<TimeInterval>?`——`hour ?? day`。
  - `MainWindowView.rangeLabel(for range: ClosedRange<TimeInterval>) -> String`——跨度 `>= 86_400`（天级）返回单个日期（如 "Sep 24"）；否则返回 "HH:mm–HH:mm"（小时级，跟现状一致）。
  - Task 4 直接调用这两个函数。

- [ ] **Step 1: 写失败的测试**

新建 `Tests/MainWindowViewTests.swift`：

```swift
import XCTest
@testable import TrafficMonitor

/// `MainWindowView` 里跟"天/小时嵌套下钻"相关的两个纯函数——都不依赖视图
/// 状态或渲染，直接构造输入断言输出。
final class MainWindowViewPureLogicTests: XCTestCase {
    // MARK: - effectiveFilterRange

    func testEffectiveFilterRangePrefersHourOverDay() {
        let day: ClosedRange<TimeInterval> = 0 ... 86_400
        let hour: ClosedRange<TimeInterval> = 3_600 ... 7_200
        XCTAssertEqual(MainWindowView.effectiveFilterRange(day: day, hour: hour), hour)
    }

    func testEffectiveFilterRangeFallsBackToDayWhenNoHour() {
        let day: ClosedRange<TimeInterval> = 0 ... 86_400
        XCTAssertEqual(MainWindowView.effectiveFilterRange(day: day, hour: nil), day)
    }

    func testEffectiveFilterRangeIsNilWhenNeitherSelected() {
        XCTAssertNil(MainWindowView.effectiveFilterRange(day: nil, hour: nil))
    }

    // MARK: - rangeLabel

    func testRangeLabelShowsSingleDateForDayLevelRange() {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: Date()).timeIntervalSince1970
        let range: ClosedRange<TimeInterval> = dayStart ... (dayStart + 86_400)
        let label = MainWindowView.rangeLabel(for: range)
        XCTAssertFalse(label.contains(":"), "天级 range 不该出现 HH:mm 冒号格式：\(label)")
    }

    func testRangeLabelShowsHourRangeForHourLevelRange() {
        let hourStart = (Date().timeIntervalSince1970 / 3_600).rounded(.down) * 3_600
        let range: ClosedRange<TimeInterval> = hourStart ... (hourStart + 3_600)
        let label = MainWindowView.rangeLabel(for: range)
        XCTAssertTrue(label.contains("–"), "小时级 range 应该是 \"HH:mm–HH:mm\" 带范围符的格式：\(label)")
        XCTAssertTrue(label.contains(":"), "小时级 range 应该包含 HH:mm 冒号格式：\(label)")
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ~/Documents/traffic-monitoring && swift test --filter MainWindowViewPureLogicTests 2>&1 | tail -30`
Expected: FAIL，编译错误——`MainWindowView` 还没有 `effectiveFilterRange`/`rangeLabel` 这两个方法（"value of type 'MainWindowView.Type' has no member ..."）。

- [ ] **Step 3: 写最小实现**

在 `Sources/Views/MainWindow/MainWindowView.swift` 里，找到当前的属性声明块
（第 17-20 行）：

```swift
    @State private var selectedProcessKey: String?
    @State private var detailTarget: ProcessRow?
    @State private var exportDocument: CSVDocument?
    @State private var selectedHistoricalRange: ClosedRange<TimeInterval>?
```

在它下面（`var body` 之前）插入这两个静态方法：

```swift
    @State private var selectedProcessKey: String?
    @State private var detailTarget: ProcessRow?
    @State private var exportDocument: CSVDocument?
    @State private var selectedHistoricalRange: ClosedRange<TimeInterval>?

    /// 表格该按哪个范围筛：选了小时就按小时筛，只选了天就按天筛，都没选
    /// 就不筛。抽成静态纯函数方便直接测，不用渲染整个视图。
    static func effectiveFilterRange(day: ClosedRange<TimeInterval>?,
                                     hour: ClosedRange<TimeInterval>?) -> ClosedRange<TimeInterval>? {
        hour ?? day
    }

    /// "Showing ..." 提示条里的标签：天级选择（跨度 `>= 86_400`，一天零点到
    /// 次日零点）显示单个日期；小时级选择（Today 现有行为，跨度 < 一天）
    /// 显示 "HH:mm–HH:mm"。抽成静态纯函数方便直接测。
    static func rangeLabel(for range: ClosedRange<TimeInterval>) -> String {
        let start = Date(timeIntervalSince1970: range.lowerBound)
        if range.upperBound - range.lowerBound >= 86_400 {
            return start.formatted(.dateTime.month(.abbreviated).day())
        }
        let end = Date(timeIntervalSince1970: range.upperBound)
        let formatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            return f
        }()
        return "\(formatter.string(from: start))–\(formatter.string(from: end))"
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd ~/Documents/traffic-monitoring && swift test --filter MainWindowViewPureLogicTests 2>&1 | tail -30`
Expected: 5 个测试全部通过。

- [ ] **Step 5: 跑全量回归**

Run: `cd ~/Documents/traffic-monitoring && swift test 2>&1 | grep -E "Executed [0-9]+ tests|error:|FAIL"`
Expected: `Executed 222 tests, with 1 test skipped and 0 failures (0 unexpected)`（217 + 这 5 条新测试）。

- [ ] **Step 6: 提交**

```bash
cd ~/Documents/traffic-monitoring
git add Sources/Views/MainWindow/MainWindowView.swift Tests/MainWindowViewTests.swift
git commit -m "$(cat <<'EOF'
feat(ui): add pure helpers for nested day/hour selection filtering

Two static functions on MainWindowView, ahead of wiring the actual
nested drill-down UI in the next task:
- effectiveFilterRange(day:hour:): which range the process table
  should filter by (hour wins over day, day over nothing).
- rangeLabel(for:): formats a "Showing ..." banner label - a single
  date for a day-level selection (a whole day's span reads oddly as
  "Sep 24-Sep 25"), the existing "HH:mm-HH:mm" for hour-level.

Kept as static, no-view-state functions so they're directly testable
without rendering. Full suite: 222 tests, 1 skipped, 0 failures.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01TJxrNteL6oPeEGnmpAa7Gq
EOF
)"
```

---

### Task 4: 接线——嵌套下钻的完整交互

**Files:**
- Modify: `Sources/Views/MainWindow/AggregateTrafficCard.swift`（新增一个回调参数）
- Modify: `Sources/Views/MainWindow/MainWindowView.swift`（新增状态、条件渲染、`selectionBanner` 签名调整）

**Interfaces:**
- Consumes: Task 1 的 `AggregateChartViewModel.bucketSeconds(for:)`（长范围按天分桶）、Task 2 的 `TimeRange.week`（滚动 24 天）、Task 3 的 `MainWindowView.effectiveFilterRange`/`rangeLabel`。
- Produces: 完整可用的功能。这是本计划的最后一个代码任务，没有后续任务依赖它的接口。

这一步没有新的自动化测试（`MainWindowView` 目前没有可渲染视图状态的测试
设施，具体理由见 spec 的"测试"一节）——用 Step 4 的手动验证代替。

- [ ] **Step 1: 给 `AggregateTrafficCard` 加一个"桶大小变化"回调**

`Sources/Views/MainWindow/AggregateTrafficCard.swift` 当前第 20-22 行：

```swift
    var selectedRange: ClosedRange<TimeInterval>?
    /// 选中某根柱子对应的时间范围时回调；取消选中传 nil。
    var onSelectRange: ((ClosedRange<TimeInterval>?) -> Void)?
```

改成：

```swift
    var selectedRange: ClosedRange<TimeInterval>?
    /// 选中某根柱子对应的时间范围时回调；取消选中传 nil。
    var onSelectRange: ((ClosedRange<TimeInterval>?) -> Void)?
    /// 实际用的桶大小变化时回调（推算自 `AggregateChartViewModel` 真实返回
    /// 的数据间距）——调用方用它判断"这是不是按天或更粗的粒度"，从而决定
    /// 要不要在下面渲染下钻的小时图。默认不设，不需要感知桶大小的调用方
    /// 不受影响。
    var onBucketSecondsChange: ((TimeInterval) -> Void)?
```

然后当前第 74-77 行：

```swift
        .onAppear { vm.startRefreshing(since: since, until: queryUntil) }
        .onDisappear { vm.stopRefreshing() }
        .onChange(of: since) { _, _ in vm.startRefreshing(since: since, until: queryUntil) }
        .onChange(of: until) { _, _ in vm.startRefreshing(since: since, until: queryUntil) }
```

改成：

```swift
        .onAppear { vm.startRefreshing(since: since, until: queryUntil) }
        .onDisappear { vm.stopRefreshing() }
        .onChange(of: since) { _, _ in vm.startRefreshing(since: since, until: queryUntil) }
        .onChange(of: until) { _, _ in vm.startRefreshing(since: since, until: queryUntil) }
        .onChange(of: vm.timeline) { _, _ in onBucketSecondsChange?(bucketSeconds) }
```

- [ ] **Step 2: 编译确认没有破坏现有调用方**

Run: `cd ~/Documents/traffic-monitoring && swift build 2>&1 | tail -20`
Expected: `Build complete!`——`onBucketSecondsChange` 是可选参数（默认 `nil`），
`MainWindowView` 现有的两处 `AggregateTrafficCard(...)` 调用不用跟着改就能
继续编译通过。

- [ ] **Step 3: 改 `MainWindowView`——新状态 + 嵌套渲染 + `selectionBanner` 签名**

当前第 17-70 行（属性声明 + `body` + `selectionBanner`，Task 3 已经在属性
声明后插入了两个静态方法，这里继续在其后修改）：

```swift
    @State private var selectedProcessKey: String?
    @State private var detailTarget: ProcessRow?
    @State private var exportDocument: CSVDocument?
    @State private var selectedHistoricalRange: ClosedRange<TimeInterval>?

    // ...（Task 3 加的 effectiveFilterRange / rangeLabel 静态方法，保持原样）...

    var body: some View {
        VStack(spacing: 0) {
            SummaryRow().padding(.horizontal).padding(.top, 12)
            Divider().padding(.top, 12)
            AggregateTrafficCard(
                since: dashboard.selectedTimeRange.start.timeIntervalSince1970,
                until: dashboard.selectedTimeRange.end.timeIntervalSince1970,
                selectedRange: selectedHistoricalRange,
                onSelectRange: { selectedHistoricalRange = $0 }
            )
            .padding(.horizontal).padding(.top, 12)
            Divider().padding(.top, 12)
            if let range = selectedHistoricalRange {
                selectionBanner(range)
            }
            ContentTable(selection: $selectedProcessKey, onOpenDetail: { detailTarget = $0 },
                        historicalRange: selectedHistoricalRange)
        }
        .toolbar { toolbarContent }
        .sheet(item: $detailTarget, onDismiss: { selectedProcessKey = nil }) { row in
            DetailWindow(row: row)
        }
        .fileExporter(
            isPresented: Binding(get: { exportDocument != nil },
                                 set: { if !$0 { exportDocument = nil } }),
            document: exportDocument,
            contentType: .commaSeparatedText,
            defaultFilename: "TrafficMonitor_export.csv"
        ) { _ in exportDocument = nil }
    }

    private func selectionBanner(_ range: ClosedRange<TimeInterval>) -> some View {
        let formatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            return f
        }()
        let start = Date(timeIntervalSince1970: range.lowerBound)
        let end = Date(timeIntervalSince1970: range.upperBound)
        let label = "\(formatter.string(from: start))–\(formatter.string(from: end))"

        return HStack {
            Text(L("aggregate.showingRange", label)).font(.caption).foregroundStyle(.secondary)
            Button(L("aggregate.clearSelection")) { selectedHistoricalRange = nil }
                .buttonStyle(.link).font(.caption)
            Spacer()
        }
        .padding(.horizontal).padding(.top, 8)
    }
```

整体替换成：

```swift
    @State private var selectedProcessKey: String?
    @State private var detailTarget: ProcessRow?
    @State private var exportDocument: CSVDocument?
    @State private var selectedHistoricalRange: ClosedRange<TimeInterval>?
    @State private var selectedHourRange: ClosedRange<TimeInterval>?
    /// 顶层聚合图实际用的桶大小，由 `AggregateTrafficCard.onBucketSecondsChange`
    /// 回报——`>= 86_400` 时才在下面渲染那一天的 24 小时下钻图。默认
    /// `3_600`（跟 `AggregateChartViewModel` 数据到达前的兜底值一致），数据
    /// 到达前不会误显示下钻区块。
    @State private var dayBucketSeconds: TimeInterval = 3_600

    // ...（Task 3 加的 effectiveFilterRange / rangeLabel 静态方法，保持原样）...

    var body: some View {
        VStack(spacing: 0) {
            SummaryRow().padding(.horizontal).padding(.top, 12)
            Divider().padding(.top, 12)
            AggregateTrafficCard(
                since: dashboard.selectedTimeRange.start.timeIntervalSince1970,
                until: dashboard.selectedTimeRange.end.timeIntervalSince1970,
                selectedRange: selectedHistoricalRange,
                onSelectRange: { selectedHistoricalRange = $0; selectedHourRange = nil },
                onBucketSecondsChange: { dayBucketSeconds = $0 }
            )
            .padding(.horizontal).padding(.top, 12)
            Divider().padding(.top, 12)
            if let dayRange = selectedHistoricalRange {
                selectionBanner(dayRange, onClear: {
                    selectedHistoricalRange = nil
                    selectedHourRange = nil
                })
                if dayBucketSeconds >= 86_400 {
                    AggregateTrafficCard(
                        since: dayRange.lowerBound, until: dayRange.upperBound,
                        selectedRange: selectedHourRange,
                        onSelectRange: { selectedHourRange = $0 }
                    )
                    .padding(.horizontal).padding(.top, 8)
                    Divider().padding(.top, 8)
                    if let hourRange = selectedHourRange {
                        selectionBanner(hourRange, onClear: { selectedHourRange = nil })
                    }
                }
            }
            ContentTable(selection: $selectedProcessKey, onOpenDetail: { detailTarget = $0 },
                        historicalRange: MainWindowView.effectiveFilterRange(
                            day: selectedHistoricalRange, hour: selectedHourRange))
        }
        .toolbar { toolbarContent }
        .sheet(item: $detailTarget, onDismiss: { selectedProcessKey = nil }) { row in
            DetailWindow(row: row)
        }
        .fileExporter(
            isPresented: Binding(get: { exportDocument != nil },
                                 set: { if !$0 { exportDocument = nil } }),
            document: exportDocument,
            contentType: .commaSeparatedText,
            defaultFilename: "TrafficMonitor_export.csv"
        ) { _ in exportDocument = nil }
    }

    private func selectionBanner(_ range: ClosedRange<TimeInterval>,
                                 onClear: @escaping () -> Void) -> some View {
        HStack {
            Text(L("aggregate.showingRange", MainWindowView.rangeLabel(for: range)))
                .font(.caption).foregroundStyle(.secondary)
            Button(L("aggregate.clearSelection")) { onClear() }
                .buttonStyle(.link).font(.caption)
            Spacer()
        }
        .padding(.horizontal).padding(.top, 8)
    }
```

- [ ] **Step 4: 编译 + 跑全量回归**

Run: `cd ~/Documents/traffic-monitoring && swift build 2>&1 | tail -20 && swift test 2>&1 | grep -E "Executed [0-9]+ tests|error:|FAIL"`
Expected: `Build complete!`；`Executed 222 tests, with 1 test skipped and 0 failures (0 unexpected)`——这一步没加新测试，数字跟 Task 3 结束时一样。

- [ ] **Step 5: 手动验证**

```bash
cd ~/Documents/traffic-monitoring
pkill -9 -f "/Applications/TrafficMonitor.app" 2>/dev/null
./Scripts/make-app.sh .
rm -rf /Applications/TrafficMonitor.app
cp -R TrafficMonitor.app /Applications/TrafficMonitor.app
xattr -dr com.apple.quarantine /Applications/TrafficMonitor.app 2>/dev/null
open /Applications/TrafficMonitor.app
```

**Note for whoever runs this步骤：** 一定要先 `rm -rf /Applications/TrafficMonitor.app` 再 `cp -R`——目标目录已存在时 `cp -R src dst` 会把 `src` 拷贝到 `dst` 里面变成嵌套目录，而不是覆盖，旧的二进制会在不知不觉中继续跑。

打开后（真机截图确认，跟这次会话里验证柱状堆叠、提示卡对齐用的是同一套
"真实渲染 + 截图/操作"方法）逐条确认：

- 工具条时间范围选择器的中间那个按钮显示 "Last 24 days"（不再是
  "This week"）。
- 点 "Last 24 days"：上面那张聚合图显示 24 根柱子（一天一根，堆叠柱状：
  下载蓝在下、上传红在上），不是一堆挤在一起的小时柱。
- 点其中一天：那根柱子高亮、其余变浅；下面出现 "Showing <日期> · Clear"
  提示条（不是 "00:00–00:00"）；提示条下面出现那一天的 24 小时柱状图。
- 点小时图里的某一根：那根高亮、其余变浅；再下面出现
  "Showing HH:00–HH:00 · Clear" 提示条；表格只显示这一小时的数据。
- 点小时提示条的 Clear：小时提示条和表格筛选消失，天级的高亮和小时图还在。
- 点天提示条的 Clear：天级高亮、小时图、两条提示条一起消失，表格回到不筛
  选状态。
- 切到 "This month"：同样的下钻交互也生效（点一天出现那一天的 24 小时图）。
- 切到 "Today"：点一个小时柱子，行为跟改动前一样（提示条 + 表格筛选），
  **不会**多出一层下钻图——`dayBucketSeconds` 在 Today 视图下是 `3_600`，
  未达到 `86_400` 门槛。

如果哪一条对不上，在这一步直接修，不要留到下一个任务。

- [ ] **Step 6: 提交**

```bash
cd ~/Documents/traffic-monitoring
git add Sources/Views/MainWindow/AggregateTrafficCard.swift Sources/Views/MainWindow/MainWindowView.swift
git commit -m "$(cat <<'EOF'
feat(ui): drill down from a selected day into its 24 hourly bars

Any daily-bucketed aggregate chart (Last 24 days, This month) now
shows a second AggregateTrafficCard - scoped to that day's hours -
below the day-level chart once a day is clicked. Reuses the existing
component and its click/hover/tooltip machinery entirely; gated on
AggregateTrafficCard now reporting its actual bucketSeconds upward
(onBucketSecondsChange) rather than a hardcoded TimeRange case, so it
generalizes to any future daily view.

New selectedHourRange state alongside the existing
selectedHistoricalRange: selecting a new day clears it, clearing the
day cascades to clear it too, and the process table filters by
whichever is more specific (effectiveFilterRange from the previous
task). selectionBanner now takes an onClear closure and formats its
label via rangeLabel (a single date for the day-level banner instead
of the old always-HH:mm format, which read as a meaningless
"00:00-00:00" for a whole day).

No new automated tests (MainWindowView has no view-rendering test
harness) - verified by building, installing, and manually clicking
through the full day-select / hour-select / clear-hour / clear-day
flow in the real app, on both Last 24 days and This month, plus
confirming Today's existing single-level behavior is unchanged. Full
suite: 222 tests, 1 skipped, 0 failures (unchanged from the previous
task - this one is pure UI wiring).

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01TJxrNteL6oPeEGnmpAa7Gq
EOF
)"
```
