# 时间范围选择器扩展：7 个预设 + 自定义区间 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把工具条的时间范围选择器从 `Today / Last 24 days / This month` 三档换成 `Today / Yesterday / Last 7 days / Last 30 days / This month / Last month / Custom` 七档，新增一个用户可选起止日期的 Custom 预设，并支持在任意多天预设的图表里双击一天直接切到 Custom 定位到那一天。

**Architecture:** `TimeRange` 枚举保持无状态（新增 6 个 case，删掉旧的 `.week`/`.month`），`.custom` 的实际起止日期存在 `Preferences`/`DashboardViewModel` 上，通过一个共享的 `resolvedInterval(customStart:customEnd:)` 函数解析——`DashboardViewModel`（喂图表）和 `CollectorService`（后台按日历边界重查）都调这一个函数，不各自判断。工具条从分段控件换成 SwiftUI 原生下拉菜单样式，Custom 多一个日历图标弹出日期选择器。双击一天的柱子复用同一套 Custom 基础设施，不是新组件。

**Tech Stack:** Swift 6.2, SwiftUI, XCTest。

## Global Constraints

- Swift tools version 5.9；部署目标 macOS 14。
- 本地化：所有面向用户的字符串都走 `L(_:)`，键值同时加到 `Sources/Resources/en.lproj/Localizable.strings` 和 `Sources/Resources/zh-Hans.lproj/Localizable.strings` 两个文件。
- `DashboardViewModel.TimeRange` 完全替换现有 3 个 case（`today/week/month`）为 7 个（`today/yesterday/last7Days/last30Days/thisMonth/lastMonth/custom`）——不保留旧 case，也不需要写 rawValue 迁移代码：`Preferences.timeRange` 的 getter 在 rawValue 匹配不到任何 case 时本来就会退回 `.today`。
- 所有跨天/跨月的区间计算都必须用 `Calendar`（`calendar.date(byAdding:)`/`calendar.dateInterval(of:)`），不能用固定秒数（`86_400`/`* N`）硬算——项目里已经因为这类写法在夏令时/跨时区场景踩过两次坑（`.today`/`.week` 的既有测试，以及上一个 PR 修的 UTC vs 本地日分桶 bug）。
- 每个任务结束前跑一次 `cd ~/Documents/traffic-monitoring && swift test 2>&1 | grep -E "Executed [0-9]+ tests|error:|FAIL"`，确认回归通过（当前基线：223 个测试，1 个跳过）。
- **已知的、跟本计划无关的偶发失败**：`AggregateChartViewModelTests.testLoadRespectsExplicitUntilEvenWhenInTheFuture` 在接近午夜（比如 23:40 之后）跑会失败——这是这条已有测试自身的时间依赖缺陷，不是本计划任何一步引入的。如果某一步的回归结果里只有这一条失败，忽略它、换个时间点重跑确认即可。
- 提交信息末尾带：
  ```
  Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01TJxrNteL6oPeEGnmpAa7Gq
  ```

---

### Task 1: `TimeRange` 枚举——7 个 case + `resolvedInterval`

**Files:**
- Modify: `Sources/ViewModels/DashboardViewModel.swift:63-120`（整个 `TimeRange` 枚举）
- Modify: `Sources/Resources/en.lproj/Localizable.strings:18-20`
- Modify: `Sources/Resources/zh-Hans.lproj/Localizable.strings:18-20`
- Modify: `Tests/TrafficPipelineTests.swift:323-430`（整个 `TimeRangeBoundaryTests` 类）

**Interfaces:**
- Consumes: 无，这是最底层的一处修改，不依赖本计划其它任务。
- Produces: `DashboardViewModel.TimeRange` 的 7 个 case
  （`today/yesterday/last7Days/last30Days/thisMonth/lastMonth/custom`）；
  `TimeRange.resolvedInterval(customStart: Date, customEnd: Date) -> DateInterval`——
  Task 2（`CollectorService.applyTimeRange`）、Task 3
  （`MainWindowView` 喂图表的 since/until）都调这一个函数。

- [ ] **Step 1: 写失败的测试**

`Tests/TrafficPipelineTests.swift` 当前第 323-430 行是整个
`TimeRangeBoundaryTests` 类。把它整段替换成：

```swift
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
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ~/Documents/traffic-monitoring && swift test --filter TimeRangeBoundaryTests 2>&1 | tail -60`
Expected: 编译失败——`DashboardViewModel.TimeRange` 还没有 `yesterday`/
`last7Days`/`last30Days`/`thisMonth`/`lastMonth`/`custom`/`resolvedInterval`
这些成员（"has no member ..."）。

- [ ] **Step 3: 修复实现**

`Sources/ViewModels/DashboardViewModel.swift` 当前第 63-120 行是整个
`TimeRange` 枚举定义。把它整段替换成：

```swift
    enum TimeRange: String, CaseIterable, Identifiable {
        // rawValue 是持久化标识，必须与界面语言无关；展示名走 `displayName`
        case today, yesterday, last7Days, last30Days, thisMonth, lastMonth, custom

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .today:      L("range.today")
            case .yesterday:  L("range.yesterday")
            case .last7Days:  L("range.last7Days")
            case .last30Days: L("range.last30Days")
            case .thisMonth:  L("range.thisMonth")
            case .lastMonth:  L("range.lastMonth")
            case .custom:     L("range.custom")
            }
        }

        /// 窗口起点。用日历边界而不是「往前推 N 秒」——
        /// 标签写着「今日」，用户期望的是今天零点起算，不是过去 24 小时。
        /// `.custom` 没有自己的起止日期（见 `resolvedInterval`），这里退回
        /// `now`，永远不会被真正用到。
        var start: Date { startDate(at: Date(), calendar: .current) }

        /// 窗口终点（不含）：**下一个日历边界**。
        var end: Date { endDate(at: Date(), calendar: .current) }

        /// 与 `start` / `end` 同一套算法，但「现在」和日历由调用方给 ——
        /// 跨天、跨月、夏令时这些边界只有拿固定日期才测得准。
        func startDate(at now: Date, calendar: Calendar) -> Date {
            interval(at: now, calendar: calendar)?.start ?? now
        }

        func endDate(at now: Date, calendar: Calendar) -> Date {
            interval(at: now, calendar: calendar)?.end ?? now
        }

        /// 当前所处周期的日历区间。起点和终点都交给日历算：终点不是
        /// 「起点 + 86400」——夏令时切换那天只有 23 小时（或 25 小时），加
        /// 固定秒数会落到隔天 01:00。`.last7Days`/`.last30Days` 是滚动窗口：
        /// 过去 6/29 个完整自然日 + 今天到此刻——跟 `.today` 一样每次调用都
        /// 用 `now` 重新算，随时间推移每天自动往前滚一天。`.custom` 没有
        /// 自己的区间，返回 `nil`，真正生效的日期由 `resolvedInterval` 解析。
        private func interval(at now: Date, calendar: Calendar) -> DateInterval? {
            switch self {
            case .today:
                return calendar.dateInterval(of: .day, for: now)
            case .yesterday:
                guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else { return nil }
                return calendar.dateInterval(of: .day, for: yesterday)
            case .last7Days, .last30Days:
                let daysBack = self == .last7Days ? -6 : -29
                guard let today = calendar.dateInterval(of: .day, for: now),
                      let start = calendar.date(byAdding: .day, value: daysBack, to: today.start)
                else { return nil }
                return DateInterval(start: start, end: today.end)
            case .thisMonth:
                return calendar.dateInterval(of: .month, for: now)
            case .lastMonth:
                guard let thisMonthStart = calendar.dateInterval(of: .month, for: now)?.start,
                      let lastMonthDay = calendar.date(byAdding: .month, value: -1, to: thisMonthStart)
                else { return nil }
                return calendar.dateInterval(of: .month, for: lastMonthDay)
            case .custom:
                return nil
            }
        }

        /// 解析出真正生效的起止区间。`.custom` 没有自己的日期，由调用方把
        /// 选中的日期传进来；其余 6 个 case 走上面的 `start`/`end`。
        /// `DashboardViewModel`（喂图表）和 `CollectorService`（后台重查
        /// 历史汇总）两处真正要用区间的地方都调这一个函数，不在两边各写
        /// 一遍"是不是 custom"的判断——两边各写一遍正是上一个 PR 里 UTC/
        /// 本地日那个 bug 的教训：同一件事让两处分头算，迟早会算出不一样
        /// 的答案。
        func resolvedInterval(customStart: Date, customEnd: Date) -> DateInterval {
            guard self == .custom else { return DateInterval(start: start, end: end) }
            let lower = min(customStart, customEnd)
            let upper = max(customStart, customEnd)
            return DateInterval(start: lower, end: upper)
        }
    }
```

`Sources/Resources/en.lproj/Localizable.strings` 当前第 18-20 行：

```
"range.today"              = "Today";
"range.week"               = "Last 24 days";
"range.month"              = "This month";
```

替换成：

```
"range.today"              = "Today";
"range.yesterday"          = "Yesterday";
"range.last7Days"          = "Last 7 days";
"range.last30Days"         = "Last 30 days";
"range.thisMonth"          = "This month";
"range.lastMonth"          = "Last month";
"range.custom"             = "Custom";
```

`Sources/Resources/zh-Hans.lproj/Localizable.strings` 当前第 18-20 行：

```
"range.today"              = "今日";
"range.week"               = "最近24天";
"range.month"              = "本月";
```

替换成：

```
"range.today"              = "今日";
"range.yesterday"          = "昨天";
"range.last7Days"          = "最近7天";
"range.last30Days"         = "最近30天";
"range.thisMonth"          = "本月";
"range.lastMonth"          = "上个月";
"range.custom"             = "自定义";
```

- [ ] **Step 4: 跑测试确认通过**

`MainWindowView.swift` 的工具条 `Picker` 遍历 `TimeRange.allCases`（不认
具体 case 名字），`CollectorService.applyTimeRange` 读的是
`range.start`/`range.end`（也不认具体 case 名字）——这两处都不引用
`.week`/`.month` 这两个被删掉的 case 名，所以整个项目应该在这一个任务
结束时就能正常编译通过，不需要等 Task 2/3 才能跑通。

Run: `cd ~/Documents/traffic-monitoring && swift build 2>&1 | tail -20`
Expected: `Build complete!`

Run: `cd ~/Documents/traffic-monitoring && swift test --filter TimeRangeBoundaryTests 2>&1 | tail -60`
Expected: 该类里全部测试通过。

- [ ] **Step 5: 跑全量回归**

Run: `cd ~/Documents/traffic-monitoring && swift test 2>&1 | grep -E "Executed [0-9]+ tests|error:|FAIL"`
Expected: `Executed 225 tests, with 1 test skipped and 0 failures (0 unexpected)`
（223 基线 − 3 条被删的测试 `testRangesAreOrderedFromNarrowToWide`/
`testWeekSpansExactly24CalendarDays`/
`testWeekStartUsesCalendarDaysNotFixedSecondsAcrossDST` + 5 条新增测试
`testLast7And30DaysSpanExactCalendarDayCounts`/
`testLast7And30DaysUseCalendarDaysNotFixedSecondsAcrossDST`/
`testLastMonthCrossesYearBoundary`/
`testResolvedIntervalPassesThroughNonCustomCases`/
`testResolvedIntervalSortsCustomBoundsRegardlessOfInputOrder` = 225）。

- [ ] **Step 6: 提交**

```bash
cd ~/Documents/traffic-monitoring
git add Sources/ViewModels/DashboardViewModel.swift \
        Sources/Resources/en.lproj/Localizable.strings \
        Sources/Resources/zh-Hans.lproj/Localizable.strings \
        Tests/TrafficPipelineTests.swift
git commit -m "$(cat <<'EOF'
feat(range): expand TimeRange to 7 presets, add resolvedInterval

Complete replacement of the 3-case TimeRange (today/week/month) with
7: today, yesterday, last7Days, last30Days, thisMonth, lastMonth,
custom. The first 6 follow the existing rolling-window (DST-safe
Calendar arithmetic) or calendar-aligned patterns already established
for .today/.week/.month; .custom has no interval of its own (it
returns nil from the private interval(at:calendar:) switch, same as
any case ever falling through to the now fallback) since it depends
on user-picked dates that don't exist yet at this layer.

Added resolvedInterval(customStart:customEnd:) so the two real
call sites (DashboardViewModel for chart queries, CollectorService for
background historical reload) resolve .custom's actual bounds through
one shared function instead of each carrying their own "is it custom?"
branch - the same class of bug (two places computing the same thing
two different ways) the previous plan's final review caught.

TimeRangeBoundaryTests rewritten for the new cases; 3 obsolete
week-specific tests removed, 5 new ones added covering last7/30-day
spans (DST-safe), a lastMonth year-boundary crossing, and
resolvedInterval's pass-through/sorting behavior. Full suite: 225
tests, 1 skipped, 0 failures.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01TJxrNteL6oPeEGnmpAa7Gq
EOF
)"
```

---

### Task 2: Custom 起止日期的持久化 + `CollectorService` 接线

**Files:**
- Modify: `Sources/Core/Collector/CollectorService.swift:185-194`（`applyTimeRange`）
- Modify: `Sources/Core/Collector/CollectorService.swift:319-346`（`enum Preferences`，新增 key + 两个属性）
- Modify: `Sources/ViewModels/DashboardViewModel.swift:39-46`（`selectedTimeRange` 旁边新增两个属性）
- Test: `Tests/TrafficPipelineTests.swift`（新增一个 `PreferencesCustomRangeTests` 类）

**Interfaces:**
- Consumes: Task 1 的 `TimeRange.resolvedInterval(customStart:customEnd:)`。
- Produces: `Preferences.customRangeStart`/`customRangeEnd: Date`（持久化）；
  `DashboardViewModel.customRangeStart`/`customRangeEnd: Date`（跟
  `selectedTimeRange` 同一种"赋值即持久化 + 选中 custom 时重查"写法）。
  Task 3（工具条 Custom 弹窗、`MainWindowView` 喂图表的 since/until）、
  Task 4（双击一天）都读写这两个 `DashboardViewModel` 属性。

- [ ] **Step 1: 写失败的测试**

在 `Tests/TrafficPipelineTests.swift` 里，紧跟着 `TimeRangeRolloverTests`
类结束的 `}`（第 485 行）之后，插入一个新类：

```swift

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
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ~/Documents/traffic-monitoring && swift test --filter PreferencesCustomRangeTests 2>&1 | tail -30`
Expected: 编译失败——`Preferences` 还没有 `customRangeStart`/
`customRangeEnd` 这两个成员。

- [ ] **Step 3: 修复实现**

`Sources/Core/Collector/CollectorService.swift` 当前第 319-329 行（
`enum Preferences` 的 key 声明部分）：

```swift
enum Preferences {
    private static let intervalKey = "com.trafficmonitor.interval"
    private static let saveIntervalKey = "com.trafficmonitor.saveInterval"
    private static let menuBarKey = "com.trafficmonitor.menuBarEnabled"
    private static let timeRangeKey = "com.trafficmonitor.timeRange"
    private static let excludedKey = "com.trafficmonitor.excludedProcesses"
    private static let sparklineKey = "com.trafficmonitor.sparkline"
    private static let menuBarFontKey = "com.trafficmonitor.menuBarFontSize"
    private static let retentionEnabledKey = "com.trafficmonitor.retentionEnabled"
    private static let retentionDaysKey = "com.trafficmonitor.retentionDays"
```

追加两个 key（紧跟在 `timeRangeKey` 后面）：

```swift
enum Preferences {
    private static let intervalKey = "com.trafficmonitor.interval"
    private static let saveIntervalKey = "com.trafficmonitor.saveInterval"
    private static let menuBarKey = "com.trafficmonitor.menuBarEnabled"
    private static let timeRangeKey = "com.trafficmonitor.timeRange"
    private static let customRangeStartKey = "com.trafficmonitor.customRangeStart"
    private static let customRangeEndKey = "com.trafficmonitor.customRangeEnd"
    private static let excludedKey = "com.trafficmonitor.excludedProcesses"
    private static let sparklineKey = "com.trafficmonitor.sparkline"
    private static let menuBarFontKey = "com.trafficmonitor.menuBarFontSize"
    private static let retentionEnabledKey = "com.trafficmonitor.retentionEnabled"
    private static let retentionDaysKey = "com.trafficmonitor.retentionDays"
```

当前第 340-346 行（`timeRange` 属性）之后插入两个新属性：

```swift
    static var timeRange: DashboardViewModel.TimeRange {
        get {
            guard let raw = UserDefaults.standard.string(forKey: timeRangeKey) else { return .today }
            return DashboardViewModel.TimeRange(rawValue: raw) ?? .today
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: timeRangeKey) }
    }

    /// `.custom` 预设实际生效的起止日期——默认给"最近 7 天"（没选过 Custom
    /// 时的兜底值，纯粹是个合理的起点，不是什么特殊含义），跟 `Last 7 days`
    /// 的窗口大小一致。
    static var customRangeStart: Date {
        get {
            (UserDefaults.standard.object(forKey: customRangeStartKey) as? Date)
                ?? Calendar.current.date(byAdding: .day, value: -6, to: Date())!
        }
        set { UserDefaults.standard.set(newValue, forKey: customRangeStartKey) }
    }

    static var customRangeEnd: Date {
        get { (UserDefaults.standard.object(forKey: customRangeEndKey) as? Date) ?? Date() }
        set { UserDefaults.standard.set(newValue, forKey: customRangeEndKey) }
    }
```

当前第 185-194 行（`applyTimeRange`）：

```swift
    func applyTimeRange(_ range: DashboardViewModel.TimeRange) async {
        let since = range.start.timeIntervalSince1970
        let until = range.end.timeIntervalSince1970
        let summaries = (try? await DataStore.shared.querySummary(since: since, until: until)) ?? []
        await TrafficPipeline.shared.reloadHistorical(summaries, since: since, until: until)
        await LogStore.shared.log(
            "Time range → \(range.rawValue), loaded \(summaries.count) historical rows",
            level: .info, tag: "Collector"
        )
    }
```

替换成：

```swift
    func applyTimeRange(_ range: DashboardViewModel.TimeRange) async {
        let interval = range.resolvedInterval(
            customStart: Preferences.customRangeStart, customEnd: Preferences.customRangeEnd)
        let since = interval.start.timeIntervalSince1970
        let until = interval.end.timeIntervalSince1970
        let summaries = (try? await DataStore.shared.querySummary(since: since, until: until)) ?? []
        await TrafficPipeline.shared.reloadHistorical(summaries, since: since, until: until)
        await LogStore.shared.log(
            "Time range → \(range.rawValue), loaded \(summaries.count) historical rows",
            level: .info, tag: "Collector"
        )
    }
```

`reloadCurrentTimeRange()`（第 201-203 行）不用改——它已经是"读
`Preferences.timeRange` 再调 `applyTimeRange`"，`.custom` 场景下自然从
`Preferences` 里读到最新选的日期。

`Sources/ViewModels/DashboardViewModel.swift` 当前第 39-46 行
（`selectedTimeRange` 属性）：

```swift
    /// 统计窗口。切换会真正重查数据库并替换管线里的「历史」部分。
    var selectedTimeRange: TimeRange = Preferences.timeRange {
        didSet {
            guard selectedTimeRange != oldValue else { return }
            Preferences.timeRange = selectedTimeRange
            Task { await CollectorService.shared.applyTimeRange(selectedTimeRange) }
        }
    }
```

在它后面追加两个属性：

```swift
    /// 统计窗口。切换会真正重查数据库并替换管线里的「历史」部分。
    var selectedTimeRange: TimeRange = Preferences.timeRange {
        didSet {
            guard selectedTimeRange != oldValue else { return }
            Preferences.timeRange = selectedTimeRange
            Task { await CollectorService.shared.applyTimeRange(selectedTimeRange) }
        }
    }

    /// `.custom` 预设实际生效的起止日期，跟 `Preferences.customRangeStart`/
    /// `customRangeEnd` 保持同步——写法照抄 `selectedTimeRange`：赋值时先跟
    /// 旧值比一次，没变就不写、不重查；变了才落盘，且只有当前正选中
    /// `.custom` 时才需要真的重查一次数据库（选的是别的预设时，改这两个值
    /// 不会立刻影响任何界面，等用户真的切回 Custom 才用得上）。
    var customRangeStart: Date = Preferences.customRangeStart {
        didSet {
            guard customRangeStart != oldValue else { return }
            Preferences.customRangeStart = customRangeStart
            guard selectedTimeRange == .custom else { return }
            Task { await CollectorService.shared.applyTimeRange(selectedTimeRange) }
        }
    }

    var customRangeEnd: Date = Preferences.customRangeEnd {
        didSet {
            guard customRangeEnd != oldValue else { return }
            Preferences.customRangeEnd = customRangeEnd
            guard selectedTimeRange == .custom else { return }
            Task { await CollectorService.shared.applyTimeRange(selectedTimeRange) }
        }
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd ~/Documents/traffic-monitoring && swift test --filter PreferencesCustomRangeTests 2>&1 | tail -30`
Expected: 通过。

- [ ] **Step 5: 跑全量回归**

Run: `cd ~/Documents/traffic-monitoring && swift test 2>&1 | grep -E "Executed [0-9]+ tests|error:|FAIL"`
Expected: `Executed 226 tests, with 1 test skipped and 0 failures (0 unexpected)`
（225 + 1 条新测试）。`TimeRangeRolloverTests.testFramePastWindowEndReloadsCurrentRange`
（用 `.today` 走 `applyTimeRange`）应该继续通过不变——`.today` 走
`resolvedInterval` 后原样等于 `start...end`，行为没变。

- [ ] **Step 6: 提交**

```bash
cd ~/Documents/traffic-monitoring
git add Sources/Core/Collector/CollectorService.swift \
        Sources/ViewModels/DashboardViewModel.swift \
        Tests/TrafficPipelineTests.swift
git commit -m "$(cat <<'EOF'
feat(range): persist and wire up Custom's actual date bounds

CollectorService.applyTimeRange now resolves the real interval via
TimeRange.resolvedInterval instead of reading range.start/range.end
directly, so .custom's persisted dates (Preferences.customRangeStart/
End, new) actually get used by the background historical-reload path
- including reloadCurrentTimeRange's calendar-boundary-rollover call,
which reads Preferences.timeRange directly and has no other way to
learn what Custom's dates are.

DashboardViewModel gets two mirrored, persisted properties
(customRangeStart/End) following the exact pattern selectedTimeRange
already uses: compare-before-write, and only re-trigger a reload when
.custom is the active selection. No UI wiring yet (Task 3) - this task
is purely the storage and background-reload plumbing.

testCustomRangeRoundTrips added; testFramePastWindowEndReloadsCurrentRange
(pre-existing, exercises applyTimeRange via .today) continues to pass
unchanged. Full suite: 226 tests, 1 skipped, 0 failures.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01TJxrNteL6oPeEGnmpAa7Gq
EOF
)"
```

---

### Task 3: 工具条——下拉菜单 + Custom 日期弹窗

**Files:**
- Modify: `Sources/Views/MainWindow/MainWindowView.swift:56-58`（喂图表的 since/until）
- Modify: `Sources/Views/MainWindow/MainWindowView.swift:120-129`（工具条 Picker）
- Modify: `Sources/Resources/en.lproj/Localizable.strings`
- Modify: `Sources/Resources/zh-Hans.lproj/Localizable.strings`

**Interfaces:**
- Consumes: Task 2 的 `dashboard.customRangeStart`/`customRangeEnd`、
  `TimeRange.resolvedInterval`。
- Produces: 完整可用的 7 档下拉菜单 + Custom 日期弹窗。Task 4（双击一天）
  依赖本任务已经存在的 `showingCustomRangePopover` 状态和 `dashboard.customRangeStart`/
  `customRangeEnd`/`selectedTimeRange` 三个可写属性（Task 2 已经产出，这里
  只是第一次真正从 UI 写它们）。

这一步没有新的自动化测试（`MainWindowView` 目前没有可渲染视图状态的测试
设施）——用 Step 4 的手动验证代替。

- [ ] **Step 1: 喂图表的 since/until 改用 `resolvedInterval`**

`Sources/Views/MainWindow/MainWindowView.swift` 当前第 56-58 行：

```swift
            AggregateTrafficCard(
                since: dashboard.selectedTimeRange.start.timeIntervalSince1970,
                until: dashboard.selectedTimeRange.end.timeIntervalSince1970,
```

替换成：

```swift
            AggregateTrafficCard(
                since: dashboard.selectedTimeRange.resolvedInterval(
                    customStart: dashboard.customRangeStart, customEnd: dashboard.customRangeEnd
                ).start.timeIntervalSince1970,
                until: dashboard.selectedTimeRange.resolvedInterval(
                    customStart: dashboard.customRangeStart, customEnd: dashboard.customRangeEnd
                ).end.timeIntervalSince1970,
```

- [ ] **Step 2: 工具条 Picker 换成下拉菜单样式 + Custom 弹窗**

当前第 17-26 行（`@State` 属性声明块）：

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
```

追加一个新状态（紧跟在 `dayBucketSeconds` 后面）：

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
    /// Custom 日期弹窗的显示状态——选中 Custom 时自动弹出一次，之后可以
    /// 通过工具条上只在选中 Custom 时才出现的日历图标按钮再次打开。
    @State private var showingCustomRangePopover = false
```

当前第 87-90 行（`.onChange(of: dashboard.selectedTimeRange)`）：

```swift
        .onChange(of: dashboard.selectedTimeRange) { _, _ in
            selectedHistoricalRange = nil
            selectedHourRange = nil
        }
```

替换成：

```swift
        .onChange(of: dashboard.selectedTimeRange) { _, newValue in
            selectedHistoricalRange = nil
            selectedHourRange = nil
            if newValue == .custom { showingCustomRangePopover = true }
        }
```

当前第 118-129 行（工具条时间范围 `ToolbarItemGroup`）：

```swift
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Picker(L("toolbar.timeRange"), selection: Bindable(dashboard).selectedTimeRange) {
                ForEach(DashboardViewModel.TimeRange.allCases) { range in
                    Text(range.displayName).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
        }
```

替换成：

```swift
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Picker(L("toolbar.timeRange"), selection: Bindable(dashboard).selectedTimeRange) {
                ForEach(DashboardViewModel.TimeRange.allCases) { range in
                    Text(range.displayName).tag(range)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            if dashboard.selectedTimeRange == .custom {
                Button { showingCustomRangePopover = true } label: {
                    Image(systemName: "calendar")
                }
                .help(L("toolbar.customRange.edit"))
                .popover(isPresented: $showingCustomRangePopover) {
                    customRangePopover
                }
            }
        }
```

在 `toolbarContent` 计算属性结束的 `}`（原第 129 行，现在因为上面的插入
往后挪了几行，找 `ToolbarItemGroup` 的下一个 `ToolbarItemGroup {` 开始处
的**前面**）插入这个新的私有计算属性：

```swift
    private var customRangePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("range.custom")).font(.headline)

            DatePicker(L("customRange.from"), selection: Bindable(dashboard).customRangeStart,
                      displayedComponents: .date)

            // `customRangeEnd`（模型层）是排他终点（"这天不算"，跟项目里
            // 所有其它区间同一套约定），但 DatePicker 面向用户，用户心里的
            // "To" 是"包含这天"——两者相差一天，这里用一个 Binding 做转换，
            // 不影响 `customRangeEnd` 自己的存储语义。
            DatePicker(L("customRange.to"), selection: Binding(
                get: {
                    Calendar.current.date(byAdding: .day, value: -1, to: dashboard.customRangeEnd)
                        ?? dashboard.customRangeEnd
                },
                set: { newInclusiveDay in
                    let start = Calendar.current.startOfDay(for: newInclusiveDay)
                    dashboard.customRangeEnd = Calendar.current.date(byAdding: .day, value: 1, to: start)
                        ?? newInclusiveDay
                }
            ), displayedComponents: .date)

            Button(L("customRange.done")) { showingCustomRangePopover = false }
                .keyboardShortcut(.defaultAction)
        }
        .padding(14)
        .frame(width: 240)
    }
```

- [ ] **Step 3: 本地化字符串**

`Sources/Resources/en.lproj/Localizable.strings`，在 `range.custom` 那一行
之后追加：

```
"toolbar.customRange.edit" = "Edit custom range";
"customRange.from"         = "From";
"customRange.to"           = "To";
"customRange.done"         = "Done";
```

`Sources/Resources/zh-Hans.lproj/Localizable.strings`，同样位置追加：

```
"toolbar.customRange.edit" = "编辑自定义范围";
"customRange.from"         = "从";
"customRange.to"           = "到";
"customRange.done"         = "完成";
```

- [ ] **Step 4: 编译 + 跑全量回归**

Run: `cd ~/Documents/traffic-monitoring && swift build 2>&1 | tail -30 && swift test 2>&1 | grep -E "Executed [0-9]+ tests|error:|FAIL"`
Expected: `Build complete!`；`Executed 226 tests, with 1 test skipped and 0 failures (0 unexpected)`
（这一步没加新测试，数字跟 Task 2 结束时一样）。

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

**Note：** 一定要先 `rm -rf /Applications/TrafficMonitor.app` 再
`cp -R`——目标目录已存在时 `cp -R src dst` 会把 `src` 拷贝到 `dst` 里面
变成嵌套目录，而不是覆盖，旧的二进制会在不知不觉中继续跑。

打开后逐条确认（真机截图，同一套"真实渲染 + 截图/操作"方法）：

- 工具条时间范围控件现在是一个下拉按钮（不是三段分段控件），点开能看到
  全部 7 个选项：Today / Yesterday / Last 7 days / Last 30 days /
  This month / Last month / Custom。
- 依次选 Today/Yesterday：顶层图是按小时的（~24 根小时柱），不出现天→
  小时下钻区块（`dayBucketSeconds` 停在 `3_600`，门槛没到）。
- 依次选 Last 7 days/Last 30 days/This month/Last month：顶层图是按天
  分桶的（7/30/28-31/28-31 根天柱），点一天能正常展开那一天的 24 小时
  下钻图（跟已有的 Last 24 days 行为一致）。
- 选 Custom：自动弹出日期弹窗；工具条下拉按钮旁边出现日历图标（选别的
  预设时这个图标不显示）；改 From/To 两个日期，图表和表格应该跟着刷新
  成新的区间；点 Done 收起弹窗；再点一次日历图标能重新打开弹窗调整日期。
- Custom 弹窗的"To"日期选择器：选 9 月 15 号，图表应该显示到 9 月 15 号
  当天结束（不是只到 9 月 14 号，也不是多算进 9 月 16 号）——这条专门验证
  `customRangeEnd` 的"排他终点 vs UI 显示成包含"那个转换有没有算对。

如果哪一条对不上，在这一步直接修，不要留到下一个任务。

- [ ] **Step 6: 提交**

```bash
cd ~/Documents/traffic-monitoring
git add Sources/Views/MainWindow/MainWindowView.swift \
        Sources/Resources/en.lproj/Localizable.strings \
        Sources/Resources/zh-Hans.lproj/Localizable.strings
git commit -m "$(cat <<'EOF'
feat(ui): switch the time-range toolbar control to a dropdown + Custom picker

The 3-option segmented control doesn't fit 7 presets (plus Custom
needing its own date-picker affordance). Switched Picker's style from
.segmented to .menu (SwiftUI's native dropdown-button rendering - no
hand-rolled Menu view needed). Selecting Custom auto-opens a popover
with two DatePickers bound to DashboardViewModel's customRangeStart/
End; a calendar-icon button appears next to the dropdown only when
Custom is the active selection, to reopen that popover later.

The "To" DatePicker shows/edits the user's intended inclusive last
day, translated to and from the model's exclusive-end convention
(same "next midnight doesn't count" rule every other range in this
app follows) via a computed Binding - the model itself is untouched.

MainWindowView's chart since/until now resolve through
TimeRange.resolvedInterval instead of reading .start/.end directly, so
Custom's picked dates actually reach the chart.

No new automated tests (MainWindowView has no view-rendering test
harness) - verified by building, installing, and manually clicking
through all 7 presets plus the Custom popover in the real app,
confirming Today/Yesterday stay hourly with no drill-down while the
other 5 get daily bars + drill-down, and that the To-date's inclusive/
exclusive translation lands on the right calendar day. Full suite:
226 tests, 1 skipped, 0 failures (unchanged - pure UI wiring).

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01TJxrNteL6oPeEGnmpAa7Gq
EOF
)"
```

---

### Task 4: 双击一天的柱子 → 切到 Custom 定位到那一天

**Files:**
- Modify: `Sources/Views/Detail/DetailWindow.swift`（`TrafficChart` 新增
  `onDoubleSelectBucket` 回调 + 双击手势）
- Modify: `Sources/Views/MainWindow/AggregateTrafficCard.swift`（新增
  `onDoubleSelectDay` 回调，透传给 `TrafficChart`）
- Modify: `Sources/Views/MainWindow/MainWindowView.swift`（顶层
  `AggregateTrafficCard` 接上 `onDoubleSelectDay`）

**Interfaces:**
- Consumes: Task 2/3 已经产出的 `dashboard.customRangeStart`/
  `customRangeEnd`/`selectedTimeRange`（可写）、`dayBucketSeconds`
  （`MainWindowView` 已有状态）。
- Produces: 无后续任务依赖——这是本计划最后一个代码任务。

这一步同样没有新的自动化测试（手势层面的行为，跟 Task 3 的门槛判断一样
没有视图渲染测试设施）——用 Step 4 的手动验证代替。

- [ ] **Step 1: `TrafficChart` 新增双击回调**

`Sources/Views/Detail/DetailWindow.swift`，找到 `selectedBucket`/
`onSelectBucket` 这两个属性（当前大致在第 277-280 行）：

```swift
    var selectedBucket: TimelinePoint?
    /// 选中某根柱子对应的时间范围时回调；取消选中传 nil。
    var onSelectBucket: ((TimelinePoint?) -> Void)?
```

改成：

```swift
    var selectedBucket: TimelinePoint?
    /// 双击某根柱子时回调（只在真的双击时触发，单击的 `onSelectBucket` 不
    /// 受影响）。默认不设——目前只有聚合图顶层的天柱需要它（双击一天直接
    /// 切到 Custom 定位到那一天），嵌套的"那一天的 24 小时"卡片和
    /// `DetailWindow` 自己的图都不传这个参数，双击对它们没有任何效果。
    /// 放在 `onSelectBucket` 前面，让后者继续留在最后一个参数的位置，
    /// 调用方尾随闭包写法不用改。
    var onDoubleSelectBucket: ((TimelinePoint) -> Void)?
    /// 选中某根柱子对应的时间范围时回调；取消选中传 nil。
    var onSelectBucket: ((TimelinePoint?) -> Void)?
```

找到 `.chartOverlay` 里那个 `onTapGesture` 手势块（当前大致在第 502-518 行）：

```swift
        .chartOverlay { proxy in
            GeometryReader { geo in
                // `chartXSelection` 在 macOS 上鼠标一划过就连续更新，属于悬浮
                // 预览的语义（`DetailWindow` 本来就要这个效果，保持不变）。
                // "点击选中某根柱子"必须是完全独立的点击手势，不能复用它——
                // 否则鼠标划过去就等于点击了。
                if onSelectBucket != nil {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { location in
                            guard let plotFrame = proxy.plotFrame else { return }
                            let plotRect = geo[plotFrame]
                            let xInPlot = location.x - plotRect.origin.x
                            guard let date: Date = proxy.value(atX: xInPlot) else { return }
                            onSelectBucket?(nearestPoint(to: date))
                        }
                }
```

替换成：

```swift
        .chartOverlay { proxy in
            GeometryReader { geo in
                // `chartXSelection` 在 macOS 上鼠标一划过就连续更新，属于悬浮
                // 预览的语义（`DetailWindow` 本来就要这个效果，保持不变）。
                // "点击选中某根柱子"必须是完全独立的点击手势，不能复用它——
                // 否则鼠标划过去就等于点击了。
                if onSelectBucket != nil {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { location in
                            guard onDoubleSelectBucket != nil, let plotFrame = proxy.plotFrame else { return }
                            let plotRect = geo[plotFrame]
                            let xInPlot = location.x - plotRect.origin.x
                            guard let date: Date = proxy.value(atX: xInPlot),
                                  let point = nearestPoint(to: date)
                            else { return }
                            onDoubleSelectBucket?(point)
                        }
                        .onTapGesture { location in
                            guard let plotFrame = proxy.plotFrame else { return }
                            let plotRect = geo[plotFrame]
                            let xInPlot = location.x - plotRect.origin.x
                            guard let date: Date = proxy.value(atX: xInPlot) else { return }
                            onSelectBucket?(nearestPoint(to: date))
                        }
                }
```

- [ ] **Step 2: `AggregateTrafficCard` 透传双击回调**

`Sources/Views/MainWindow/AggregateTrafficCard.swift`，找到属性声明块
（`selectedRange`/`onSelectRange`/`onBucketSecondsChange` 那几行）：

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

追加一个新属性：

```swift
    var selectedRange: ClosedRange<TimeInterval>?
    /// 选中某根柱子对应的时间范围时回调；取消选中传 nil。
    var onSelectRange: ((ClosedRange<TimeInterval>?) -> Void)?
    /// 实际用的桶大小变化时回调（推算自 `AggregateChartViewModel` 真实返回
    /// 的数据间距）——调用方用它判断"这是不是按天或更粗的粒度"，从而决定
    /// 要不要在下面渲染下钻的小时图。默认不设，不需要感知桶大小的调用方
    /// 不受影响。
    var onBucketSecondsChange: ((TimeInterval) -> Void)?
    /// 双击某一天时回调，把那一天的 `TimelinePoint` 交给调用方——目前只有
    /// `MainWindowView` 顶层的多天聚合图会传这个参数（双击一天切到 Custom
    /// 定位到那一天），嵌套的"那一天的 24 小时"卡片不传，双击小时不做
    /// 任何事。
    var onDoubleSelectDay: ((TimelinePoint) -> Void)?
```

找到 `body` 里的 `TrafficChart(...)` 调用：

```swift
                TrafficChart(points: vm.timeline, style: .bar, range: range,
                            bucketSecondsOverride: bucketSeconds,
                            domainEnd: Date(timeIntervalSince1970: until),
                            selectedBucket: selectedBucket) { point in
                    guard let point else { onSelectRange?(nil); return }
                    onSelectRange?(point.timestamp ... (point.timestamp + bucketSeconds))
                }
```

替换成：

```swift
                TrafficChart(points: vm.timeline, style: .bar, range: range,
                            bucketSecondsOverride: bucketSeconds,
                            domainEnd: Date(timeIntervalSince1970: until),
                            selectedBucket: selectedBucket,
                            onDoubleSelectBucket: onDoubleSelectDay) { point in
                    guard let point else { onSelectRange?(nil); return }
                    onSelectRange?(point.timestamp ... (point.timestamp + bucketSeconds))
                }
```

- [ ] **Step 3: `MainWindowView` 接上双击行为**

`Sources/Views/MainWindow/MainWindowView.swift`，找到顶层
`AggregateTrafficCard` 调用（当前大致在第 56-62 行，如果 Task 3 已经把
`since`/`until` 改成了 `resolvedInterval` 那一大段，接着往下找到
`onBucketSecondsChange: { dayBucketSeconds = $0 }` 那一行）：

```swift
                onSelectRange: { selectedHistoricalRange = $0; selectedHourRange = nil },
                onBucketSecondsChange: { dayBucketSeconds = $0 }
            )
```

替换成：

```swift
                onSelectRange: { selectedHistoricalRange = $0; selectedHourRange = nil },
                onBucketSecondsChange: { dayBucketSeconds = $0 },
                onDoubleSelectDay: { point in
                    // 只在顶层图已经是按天分桶时才有意义——Today/Yesterday
                    // 本身就是单独一天，双击一根小时柱切到"Custom 定位到
                    // 今天"没有意义，直接忽略。
                    guard dayBucketSeconds >= 86_400 else { return }
                    let dayStart = Date(timeIntervalSince1970: point.timestamp)
                    let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
                    dashboard.customRangeStart = dayStart
                    dashboard.customRangeEnd = dayEnd
                    dashboard.selectedTimeRange = .custom
                }
            )
```

**重要：** 这个改动只加在顶层（多天）那一个 `AggregateTrafficCard` 调用
上，**不要**加到嵌套的"那一天的 24 小时"那个 `AggregateTrafficCard` 调用
（`selectedHourRange`/`selectedHourRange = $0` 那一处）——双击小时不做
任何事，嵌套那个调用不传 `onDoubleSelectDay` 参数，保持不变。

- [ ] **Step 4: 编译 + 跑全量回归**

Run: `cd ~/Documents/traffic-monitoring && swift build 2>&1 | tail -30 && swift test 2>&1 | grep -E "Executed [0-9]+ tests|error:|FAIL"`
Expected: `Build complete!`；`Executed 226 tests, with 1 test skipped and 0 failures (0 unexpected)`
（这一步没加新测试，数字跟 Task 3 结束时一样）。

- [ ] **Step 5: 手动验证**

跟 Task 3 Step 5 同一套流程重新打包安装（`make-app.sh` → 装到
`/Applications` → `open`）。逐条确认：

- 切到 Last 7 days（或 Last 30 days/This month/Last month）：**单击**一天
  的柱子，行为跟之前一样——那根柱子高亮，下面展开那一天的 24 小时下钻图。
  这一步确认单击没有被双击手势带偏（SwiftUI 需要等一下确认"不是双击"
  才会触发单击，如果单击变得明显迟钝或者完全不触发，说明两个手势冲突了，
  需要调整实现）。
- **双击**一天的柱子：整个仪表盘切到 Custom，顶层图表和表格都变成只显示
  那一天的数据；Custom 弹窗此时不会自动弹出（双击是直接设值，不经过
  `.onChange(of: dashboard.selectedTimeRange)` 里"选中 custom 就自动弹窗"
  那条逻辑之外的路径——等等，`selectedTimeRange = .custom` 这次赋值一样
  会触发 `.onChange`，所以双击之后 Custom 弹窗**也会**自动弹出，弹窗里
  From/To 应该正好是双击的那一天）。
- 双击之后弹窗里的 From/To 日期，应该正好是双击那一天的日期（比如双击的
  是 9 月 20 号的柱子，From 和 To 都应该显示 9 月 20 号）。
- 在 Today/Yesterday 视图下，双击一根小时柱子：不应该发生任何跳转
  （`dayBucketSeconds` 停在 `3_600`，门槛没到，回调里直接 return）。
- 双击嵌套的"那一天的 24 小时"图里的某个小时柱子：也不应该发生任何跳转
  （这个卡片没有传 `onDoubleSelectDay`，双击手势在 `TrafficChart` 内部
  因为 `onDoubleSelectBucket == nil` 直接不生效）。

如果单击/双击手势互相干扰（比如单击变迟钝），在这一步调整：可以尝试
把 `.onTapGesture(count: 2)` 和 `.onTapGesture` 的先后顺序对调，或者查阅
SwiftUI 文档确认两个不同 `count` 的 `onTapGesture` 加在同一个视图上的
标准写法。

- [ ] **Step 6: 提交**

```bash
cd ~/Documents/traffic-monitoring
git add Sources/Views/Detail/DetailWindow.swift \
        Sources/Views/MainWindow/AggregateTrafficCard.swift \
        Sources/Views/MainWindow/MainWindowView.swift
git commit -m "$(cat <<'EOF'
feat(ui): double-click a day's bar to jump into Custom for that day

Double-clicking a day (in any daily-bucketed multi-day preset - Last
7/30 days, This month, Last month) switches the whole dashboard to
Custom, scoped to exactly that one day (customRangeStart = that day's
start, customRangeEnd = the next day's start, matching every other
range's exclusive-end convention in this app). No new window or
component - it reuses the Custom infrastructure from the previous two
tasks entirely.

TrafficChart gains onDoubleSelectBucket (a separate .onTapGesture(count:
2), placed before the existing single-tap gesture so SwiftUI can
disambiguate them), threaded through AggregateTrafficCard's new
onDoubleSelectDay. Only MainWindowView's top-level (multi-day) card
wires it - the nested hourly drill-down card doesn't pass it, so
double-clicking an hour does nothing. Also guarded on dayBucketSeconds
>= 86_400 so double-clicking an hourly bar in Today/Yesterday's own
view (which shares the same top-level card) is a no-op rather than a
confusing same-day jump.

No new automated tests (gesture-level behavior, same view-rendering
test gap as Task 3) - verified by building, installing, and manually
double-clicking a day bar in the real app, confirming single-click
still works normally alongside it, and confirming double-clicking an
hour bar (in Today/Yesterday or the nested hourly view) is a no-op.
Full suite: 226 tests, 1 skipped, 0 failures (unchanged - pure UI
wiring).

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01TJxrNteL6oPeEGnmpAa7Gq
EOF
)"
```
