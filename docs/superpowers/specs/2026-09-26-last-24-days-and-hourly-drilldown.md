# "Last 24 days" 时间范围 + 按天下钻到小时

## 背景

主窗口顶部工具条的时间范围选择器目前是 `Today / This week / This month`
（`DashboardViewModel.TimeRange`）。`This week` 用的是日历周（`weekOfYear`），
永远固定跨周一到周日 7 天。用户觉得 7 天太窄，想把这个按钮改成显示最近 24
天（数字本身没有特殊含义，够铺开看、不用挤在一起就行）；同时希望在任何按天
分桶的聚合图（`Last 24 days`、`This month`）里，点一天能在下面钻出那一天的
24 小时明细，跟现有 `Today` 视图长得一样。

## 现状盘点

- `TimeRange.week` 通过 `calendar.dateInterval(of: .weekOfYear, for: now)`
  算区间，`start`/`end` 都对齐到日历周边界，不是"最近 N 天"这种滚动窗口。
  `TimeRange.today` 才是滚动窗口的写法（`calendar.dateInterval(of: .day,
  for: now)`，本质上等价于"今天零点到明天零点"，每次调用都用当下的
  `now` 重新算）。
- `AggregateTrafficCard`（`Sources/Views/MainWindow/AggregateTrafficCard.swift`）
  已经是完全通用的组件：只认 `since`/`until`/`selectedRange`/`onSelectRange`，
  桶大小从 `AggregateChartViewModel` 实际返回数据的点间距推算
  （`bucketSeconds`），不关心调用方是哪个 `TimeRange`——**这部分确实不用改**。
- **但查询层目前不会按天分桶**：`AggregateChartViewModel.bucketSeconds(for:)`
  只有 `range <= 86_400` 时才固定用 1 小时桶；更长范围直接复用
  `TimelineBucket.size(for:)`，而它"更长"那一档（`>259_200`，即 >3 天）返回
  的也是 `3_600`（1 小时），不是 1 天。也就是说**现在的 This week/This month
  实际查的是按小时的网格**（7 天 ≈168 根、30 天 ≈720 根），不是这份 spec
  最初以为的"已经按天分桶"。`Last 24 days` 如果不修这里，会渲成 ~576 根挤在
  一起的小时柱，而不是 24 根清爽的天柱——这是本次必须一起改的一块，见下面
  设计第 0 条。
- `MainWindowView` 已经有一层"点一个桶 → 显示 Showing HH:MM–HH:MM · Clear
  banner → 筛选下面的 `ContentTable`"的完整交互（`selectedHistoricalRange`
  + `selectionBanner`），这次的"下钻"就是在同一个模式上再嵌一层，不是
  重新发明。
- 现有测试 `TimeRangeBoundaryTests.testRangeEndsAtNextCalendarBoundary`
  （`Tests/TrafficPipelineTests.swift:355`）断言 `week.end` 落在"下一个日历
  周"的起点上——这条断言要跟着新语义改掉。

## 设计

### 0. 让长范围真正按天分桶（前置修复）

`AggregateChartViewModel.bucketSeconds(for:)`（私有方法）：

```swift
private func bucketSeconds(for range: TimeInterval) -> TimeInterval {
    range <= 86_400 ? 3_600 : 86_400
}
```

不再对长范围复用 `TimelineBucket.size(for:)`——那个函数是给 `DetailWindow`
单进程详情图的"过去 N 小时"滑块用的，语义是"离得越远越粗，但从不到天级"，跟
聚合图这里"1 天以内按小时看、超过 1 天按天看"的需求不是一回事，改
`TimelineBucket.size` 本身会波及 `DetailWindow`，不动它，只改
`AggregateChartViewModel` 自己这条私有规则。

### 1. `TimeRange.week` 改成滚动 24 天窗口

Swift case 名字和持久化用的 `rawValue`（`"week"`）不变，只改 `interval(at:
calendar:)` 里 `.week` 分支的计算方式和 `displayName`：

- `start`：`calendar.startOfDay(for: now)` 往前推 23 个日历天
  （`calendar.date(byAdding: .day, value: -23, to: ...)`，不是减
  `23 * 86400` 秒——夏令时那天不是 24 小时，减固定秒数会落在错误的时刻，
  这一点已经是 `.today`/`.month` 遵循的约定）。
- `end`：跟 `.today` 一样，明天零点（不含）。
- `displayName`：`range.week` 这个 localization key 不变，值从
  "This week"/"本周" 改成 "Last 24 days"/"最近24天"。

结果：任意时刻查询，窗口永远是"过去 23 个完整自然日 + 今天到此刻为止"，
一共 24 个自然日，随时间推移每天自动往前滚动一天。

### 2. 按天分桶时，点一天在下面钻出那一天的 24 小时图

`MainWindowView` 新增一个状态 `selectedHourRange: ClosedRange<TimeInterval>?`
（跟已有的 `selectedHistoricalRange` 同级）。渲染逻辑：

```
AggregateTrafficCard(since:, until:, selectedRange: selectedHistoricalRange, onSelectRange: ...)
if let dayRange = selectedHistoricalRange {
    selectionBanner(dayRange, onClear: { selectedHistoricalRange = nil; selectedHourRange = nil })
    if bucketIsDailyOrCoarser {
        AggregateTrafficCard(
            since: dayRange.lowerBound, until: dayRange.upperBound,
            selectedRange: selectedHourRange, onSelectRange: { selectedHourRange = $0 }
        )
        if let hourRange = selectedHourRange {
            selectionBanner(hourRange, onClear: { selectedHourRange = nil })
        }
    }
}
ContentTable(historicalRange: selectedHourRange ?? selectedHistoricalRange)
```

现有的 `selectionBanner(_ range:)` 目前**硬编码用 "HH:mm" 格式化 label**——
这对小时级选择（Today 视图现在的行为）是对的，但天级选择的 `range` 是"这天
零点 ~ 次日零点"，照原样格式化会显示成没意义的 "00:00–00:00"。
`selectionBanner` 需要按 `range` 自己的跨度决定格式：跨度 `>= 86_400`（天级）
显示单个日期（"Sep 24"），否则保持原有的 "HH:mm–HH:mm"（小时级，含 Today
现有行为，原样不变）。同时新增 `onClear: () -> Void` 参数替换掉原来写死的
`selectedHistoricalRange = nil`，因为现在 Clear 要清哪个状态取决于是哪一层
banner。

- **是否"按天或更粗"由桶大小判断，不认具体是哪个 `TimeRange`**：
  `AggregateChartViewModel` 已经把推算出的 `bucketSeconds` 暴露给
  `AggregateTrafficCard`（现在只在内部用，需要把它上抛给 `MainWindowView`，
  或者由 `MainWindowView` 自己用同一套推算逻辑跑一遍）。判断标准
  `bucketSeconds >= 86400`——这样 `Last 24 days`、`This month`
  自动都支持，以后任何新增的按天视图也自动支持，不用在这里为每个
  `TimeRange` case 写一条特例。
- **选新的一天会替换掉下面的小时图**，并清空 `selectedHourRange`
  （`onSelectRange` 里：先设 `selectedHistoricalRange`，同时把
  `selectedHourRange` 置 `nil`）。
- **清掉天选择（点日期 banner 的 Clear）连带隐藏整个小时图区块**，因为
  `selectedHistoricalRange == nil` 时上面那段条件渲染整体消失，
  `selectedHourRange` 也一起清空（不会残留一个没有上下文的小时选择）。
- **表格筛选优先级**：`selectedHourRange ?? selectedHistoricalRange`——
  选了小时就按小时筛，只选了天就按天筛，都没选就不筛。
- **小时图内部的点击/悬停/虚线/提示卡**：不需要新代码——这是同一个
  `AggregateTrafficCard`/`TrafficChart` 组件，`since`/`until` 换成那一天的
  起止后，`AggregateChartViewModel` 会推算出小时级的 `bucketSeconds`，
  自动渲染成 24 根小时柱子，点击/悬停/居中虚线/提示卡（时间段 + 上传下载
  总量）全部是现成行为。

## 数据流

无变化。`AggregateChartViewModel.startRefreshing(since:until:)` 本来就是
通用的，两个 `AggregateTrafficCard` 实例各自持有自己的
`@StateObject private var vm`，互不干扰。

## 测试

- 新增：`AggregateChartViewModelTests` 里加一条断言长范围（比如 25 天）查询
  出的相邻两点间距是 `86_400`——照抄现有
  `testLoadUsesHourlyBucketsForRangesUpToOneDay` 的手法（真实
  `DataStore` 实例 + `vm.load(since:until:)`），只是把窗口跨度改成超过
  1 天。
- 新增：`selectionBanner` 的格式化规则——天级 range（跨度 `>= 86_400`）显示
  单个日期，小时级 range（跨度 `< 86_400`）显示 "HH:mm–HH:mm"。这条逻辑要
  抽成跟 `effectiveFilterRange` 一样的纯函数（`rangeLabel(_:) -> String`）
  才能不渲染视图直接测。
- `TimeRangeBoundaryTests.testRangeEndsAtNextCalendarBoundary`
  （`Tests/TrafficPipelineTests.swift:368`）：把断言"`week.end` 落在下一个
  日历周起点"改成跟 `.today` 一样"`week.end` 落在明天零点"。
- 新增：`week.start` 到 `week.end` 正好跨越 24 个日历天
  （用 `calendar.dateComponents([.day], from: start, to: end).day`）。
- 新增：夏令时跨越场景（照 `testDayWindowSpansCalendarDayNot24Hours`
  的写法，固定用 `America/New_York` + 2026-03-08 附近的日期）下，
  `week.start`/`week.end` 依然是按日历天数算出来的，不受当天 23/25 小时
  影响。
- `MainWindowView` 目前没有任何直接测试（`Tests/` 下搜不到这个类型），
  也没有可复用的视图状态测试基础设施。把"表格该按哪个范围筛"这条规则
  抽成一个纯函数（例如 `effectiveFilterRange(day:hour:) ->
  ClosedRange<TimeInterval>?`，返回 `hour ?? day`），放在
  `MainWindowView` 里当一个无副作用的方法或自由函数，直接用 XCTest 断言
  三种输入组合（都没选/只选天/天+小时都选）——不需要渲染视图。
- "选新的一天清空小时选择"“清天连带清小时”是 `onSelectRange`/Clear 按钮
  回调里的两行状态赋值，逻辑本身简单到不值得为此搭一套 SwiftUI 状态测试
  基础设施——用 `Scripts/make-app.sh` 打包后手动点击验证（跟这次会话里
  验证柱状堆叠、提示卡对齐用的是同一套"真实渲染 + 截图/操作"方法）。

## 范围说明

本次不包含：`This month` 之外/`Last 24 days` 之外的其它按天视图（目前也没有
别的按天视图）；不包含把"最近 N 天"做成可配置项——`24` 是硬编码常量；不
包含小时图内部再往下钻到分钟级——`Today` 视图本身就是最细粒度，不需要
第三层。
