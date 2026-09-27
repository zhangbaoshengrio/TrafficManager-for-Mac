# 时间范围选择器扩展：7 个预设 + 自定义区间

## 背景

主窗口工具条的时间范围选择器目前是 `Today / Last 24 days / This month` 三档
（`DashboardViewModel.TimeRange`，`.today/.week/.month` 三个 case，`.week` 是
上一个 PR 刚从"日历周"改成"滚动 24 天"的）。用户想换成业界仪表盘常见的
7 档：**Today / Yesterday / Last 7 days / Last 30 days / This month /
Last month / Custom**，完全替换掉现在的 3 档（`.week` 这个"滚动 24 天"整个
下线，被 `Last 7 days`/`Last 30 days` 取代）。所有新档位的图表交互（柱状图
样式、点击/悬停、天→小时下钻）都要跟现在 `Today`/`Last 24 days` 已经做好的
完全一致，不需要新设计——这部分是纯复用。

**追加需求**（brainstorming 过程中提出）：在任意多天预设（Last 7/30 days、
This month、Last month）里，**双击**一天的柱子，直接把整个仪表盘切到
Custom，定位到那一天——不是打开新窗口，是复用本次要做的 Custom 基础设施
（`customRangeStart`/`customRangeEnd` 设成那一天的起止，`selectedTimeRange`
设成 `.custom`）。

## 现状盘点

- `TimeRange` 是一个无内部状态的 `String` 枚举：`start`/`end` 两个计算属性
  只用 `self` + `Date()` + `Calendar` 就能算出来，不依赖任何外部存的值。
  `Custom` 需要用户自己选的两个日期，这个模型放不下——枚举本身不能带载荷
  还要保持 `CaseIterable`/`rawValue` 持久化这套现成写法。
- `dashboard.selectedTimeRange.start`/`.end` 只有一处直接读取：
  `MainWindowView.swift:57-58`（喂给顶层 `AggregateTrafficCard`）。别处
  （`SummaryRow`、`MenuBarView`）只读 `.displayName`，不受影响。
- **容易漏掉的第二个读取点**：`CollectorService.applyTimeRange(_:)`
  （`CollectorService.swift:185-194`）自己也读了一遍 `range.start`/`range.end`
  去重查历史汇总；`reloadCurrentTimeRange()`（同文件 `:201-203`，"跨日历边界
  必须调一次"那个）直接读 `Preferences.timeRange`（不经过
  `DashboardViewModel` 实例）再调 `applyTimeRange`。这意味着 Custom 选中的
  日期**必须持久化到 `Preferences`**，不能只存在 `DashboardViewModel` 的
  内存状态里，否则这条后台重查路径拿不到。
- `Preferences.timeRange`（`CollectorService.swift:340-346`）是
  `enum Preferences` 上的一个普通计算属性，读写 `UserDefaults`，`get` 失败
  时退回 `.today`——新增/删除 case 不需要写迁移代码，旧的
  `"week"`/`"month"` rawValue 读不出匹配的 case 时自然退回 `.today`。
- 工具条 Picker（`MainWindowView.swift:120-127`）现在是
  `.pickerStyle(.segmented)` + `.frame(width: 260)`，3 个选项刚好放得下。
  SwiftUI 的 `Picker` 换成 `.pickerStyle(.menu)` 就是一个原生下拉菜单
  按钮（显示当前选中项 + 一个 chevron，点开列出所有 `ForEach` 的选项）——
  不需要另外手写一个 `Menu` 视图。
- 分桶粒度已经是通用的：`AggregateChartViewModel.usesDailyBuckets(for:)`
  只看 `until - since` 这个跨度（`>= 2 * 86_400` 才按天分桶），完全不关心
  这个跨度是哪个 `TimeRange` 算出来的。天→小时下钻的触发条件
  （`MainWindowView.swift` 里的 `dayBucketSeconds >= 86_400`）同理。**这两处
  一行代码都不用改**，新预设自动获得跟 `Last 24 days`/`This month` 一样的
  按天分桶 + 下钻体验，`Today`/`Yesterday`（跨度 ~1 天）自动留在按小时、不
  触发下钻，跟现在 `Today` 的体验一致。

## 设计

### 1. `TimeRange` 枚举：7 个 case，`.custom` 无载荷

```swift
enum TimeRange: String, CaseIterable, Identifiable {
    case today, yesterday, last7Days, last30Days, thisMonth, lastMonth, custom
    ...
}
```

`.today`/`.thisMonth`（原 `.month`，改名让"这个月"/"上个月"并排时更好读）
的算法不变。新增四档：

- `.yesterday`：昨天整个日历天。
  ```swift
  case .yesterday:
      guard let y = calendar.date(byAdding: .day, value: -1, to: now) else { return nil }
      return calendar.dateInterval(of: .day, for: y)
  ```
- `.last7Days` / `.last30Days`：滚动窗口，跟上一个 PR 里 `.week`（现在删掉）
  同一套写法，只是往前推的天数不同（`-6`/`-29`，含"今天"正好凑够 7/30 天）：
  ```swift
  case .last7Days, .last30Days:
      let back = self == .last7Days ? -6 : -29
      guard let today = calendar.dateInterval(of: .day, for: now),
            let start = calendar.date(byAdding: .day, value: back, to: today.start)
      else { return nil }
      return DateInterval(start: start, end: today.end)
  ```
- `.lastMonth`：上一个日历月整月。
  ```swift
  case .lastMonth:
      guard let thisMonthStart = calendar.dateInterval(of: .month, for: now)?.start,
            let lastMonthDay = calendar.date(byAdding: .month, value: -1, to: thisMonthStart)
      else { return nil }
      return calendar.dateInterval(of: .month, for: lastMonthDay)
  ```
- `.custom`：枚举自己不算区间，返回 `nil`——`interval(at:calendar:)` 现有的
  调用方（`startDate`/`endDate`）本来就在 `nil` 时退回 `now`，这个值永远不会
  被真正用到（见下面 `resolvedInterval`），只是让 `.custom` 在这套
  `switch` 里有仅有的、明确"我没有自己的区间"的分支，不需要特殊处理。

### 2. `.custom` 的实际日期：持久化在 `Preferences`，`DashboardViewModel` 镜像

新增两个 `Preferences` 属性，跟 `timeRange`同一种读写模式：

```swift
static var customRangeStart: Date {
    get { (UserDefaults.standard.object(forKey: customRangeStartKey) as? Date)
        ?? Calendar.current.date(byAdding: .day, value: -6, to: Date())! }
    set { UserDefaults.standard.set(newValue, forKey: customRangeStartKey) }
}
static var customRangeEnd: Date {
    get { (UserDefaults.standard.object(forKey: customRangeEndKey) as? Date) ?? Date() }
    set { UserDefaults.standard.set(newValue, forKey: customRangeEndKey) }
}
```

默认值给"最近 7 天"（没选过 Custom 时的兜底），跟 `Last 7 days` 的窗口大小
一致，纯粹是个合理的起点，不是什么特殊含义。

`DashboardViewModel` 新增两个镜像属性，写法照抄现有 `selectedTimeRange`：

```swift
var customRangeStart: Date = Preferences.customRangeStart {
    didSet {
        guard customRangeStart != oldValue else { return }
        Preferences.customRangeStart = customRangeStart
        guard selectedTimeRange == .custom else { return }
        Task { await CollectorService.shared.applyTimeRange(selectedTimeRange) }
    }
}
var customRangeEnd: Date = Preferences.customRangeEnd { /* 同上，改 customRangeEnd */ }
```

### 3. 一个共享的区间解析函数，`.custom` 从这里"补回"日期

```swift
extension DashboardViewModel.TimeRange {
    /// 解析出真正生效的起止区间。`.custom` 没有自己的日期，由调用方把
    /// `Preferences`/`DashboardViewModel` 里存的日期传进来；其余 6 个 case
    /// 走原来的 `start`/`end`。`DashboardViewModel`（喂图表）和
    /// `CollectorService`（后台重查历史汇总）两处真正要用区间的地方都调
    /// 这一个函数，不在两边各写一遍"是不是 custom"的判断——两边各写一遍
    /// 正是这次会话里 UTC/本地日那个 bug 的教训：同一件事让两处分头算，
    /// 迟早会算出不一样的答案。
    func resolvedInterval(customStart: Date, customEnd: Date) -> DateInterval {
        guard self == .custom else { return DateInterval(start: start, end: end) }
        let lower = min(customStart, customEnd)
        let upper = max(customStart, customEnd)
        return DateInterval(start: lower, end: upper)
    }
}
```

调用点改动（两处）：

- `MainWindowView.swift:57-58`：
  ```swift
  let interval = dashboard.selectedTimeRange.resolvedInterval(
      customStart: dashboard.customRangeStart, customEnd: dashboard.customRangeEnd)
  // ... since: interval.start.timeIntervalSince1970, until: interval.end.timeIntervalSince1970
  ```
- `CollectorService.applyTimeRange(_:)`（`CollectorService.swift:185-194`）：
  签名不变（仍然只接收 `TimeRange`），内部把
  ```swift
  let since = range.start.timeIntervalSince1970
  let until = range.end.timeIntervalSince1970
  ```
  换成
  ```swift
  let interval = range.resolvedInterval(
      customStart: Preferences.customRangeStart, customEnd: Preferences.customRangeEnd)
  let since = interval.start.timeIntervalSince1970
  let until = interval.end.timeIntervalSince1970
  ```
  `reloadCurrentTimeRange()` 不用改——它已经是"读 `Preferences.timeRange`
  再调 `applyTimeRange`"，`.custom` 场景下自然从 `Preferences` 里读到最新
  选的日期，即便这次调用是从跟 UI 完全无关的后台路径触发的。

### 4. 工具条：分段控件换成下拉菜单 + Custom 的日期弹窗

```swift
Picker(L("toolbar.timeRange"), selection: Bindable(dashboard).selectedTimeRange) {
    ForEach(DashboardViewModel.TimeRange.allCases) { range in
        Text(range.displayName).tag(range)
    }
}
.pickerStyle(.menu)
.labelsHidden()
```

去掉原来 `.frame(width: 260)`（3 个选项才需要固定宽度撑满；`.menu` 样式的
按钮本身只显示当前选中的一项 + 一个 chevron，宽度交给系统按内容算）。

新增一个 `@State private var showingCustomRangePopover = false`，在现有的
`.onChange(of: dashboard.selectedTimeRange)`（就是上一个 PR 加的、切范围清
选中状态那个）里追加一句：选中的新值是 `.custom` 时把这个状态设成 `true`。
工具条里紧挨着 Picker 放一个日历图标按钮，仅当 `selectedTimeRange == .custom`
时才显示/可点，点击也会打开同一个弹窗（选完一次 Custom 之后，用户还能再点
这个按钮回来改日期，不需要先切到别的档位再切回来）：

```swift
if dashboard.selectedTimeRange == .custom {
    Button { showingCustomRangePopover = true } label: {
        Image(systemName: "calendar")
    }
    .help(L("toolbar.customRange.edit"))
}
```

弹窗内容（`.popover(isPresented: $showingCustomRangePopover)`）：两个
`DatePicker`（`displayedComponents: .date`）。"From" 直接绑定
`Bindable(dashboard).customRangeStart`；"To" **不能**直接绑定
`customRangeEnd`——模型层的 `customRangeEnd` 是排他终点（"这天不算"，跟
项目里所有其它区间同一套约定：`.today`/`.last7Days` 等的 `end` 都是"次日
零点"），但用户在弹窗里选"To"时，心里想的是"包含这一天"，两者相差一天。
用一个 `Binding` 做转换（`get` 时减一天显示给用户看，`set` 时把用户选的
日期当天零点再加一天存回 `customRangeEnd`），只在这个弹窗的展示/编辑层做
换算，不影响 `customRangeEnd` 自己的存储语义。加一个 Done 按钮关闭弹窗
（`DatePicker` 选完就已经实时写回，Done 只是收起弹窗，不是"确认才生效"——
保持跟这个 app 其它设置项"选完立即生效"的一贯风格一致）。

按钮上显示的文字维持 `range.displayName`（Custom 就是"Custom"这个固定
文案，不随日期变化）——先做简单版本，以后如果想让按钮显示实际选中的日期
区间，是个独立的小改动，不在这次范围内。

### 5. 双击一天的柱子 → 切到 Custom 定位到那一天

任意多天预设（Last 7/30 days、This month、Last month）的顶层聚合图里，
**双击**一天的柱子，直接把 `selectedTimeRange` 设成 `.custom`、
`customRangeStart`/`customRangeEnd` 设成那一天的起止——不开新窗口，走的
是上面第 2/3 节已经搭好的 Custom 基础设施。`customRangeEnd` 按存储层的
排他终点约定设成"次日零点"（跟其它任何区间一致），不是那一天当天零点。

复用现有 `TrafficChart`/`AggregateTrafficCard` 的点击手势管线，新增一个
只在双击时触发的回调（`onDoubleSelectBucket`/`onDoubleSelectDay`），
单击原有的选中/下钻行为完全不受影响。只有 `MainWindowView` **顶层**
（多天）那张图接这个回调；嵌套的"那一天的 24 小时"卡片和
`DetailWindow` 自己的单进程图都不接，双击对它们没有任何效果。Today/
Yesterday 视图下双击一根小时柱子也应该是空操作——用现有的
`dayBucketSeconds >= 86_400` 这同一个门槛（已经在用它判断"要不要显示
下钻区块"）判断"当前顶层图是不是按天分桶"，不是按天分桶时双击直接
忽略。

### 6. 本地化

新增/调整 `Localizable.strings`（en + zh-Hans 两个文件都要改）：

- `range.today` 不变（"Today"/"今日"）。
- 删除 `range.week`（原"Last 24 days"/"最近24天"）、`range.month`
  （原"This month"/"本月"）。
- 新增：`range.yesterday`（"Yesterday"/"昨天"）、`range.last7Days`
  （"Last 7 days"/"最近7天"）、`range.last30Days`（"Last 30 days"/
  "最近30天"）、`range.thisMonth`（"This month"/"本月"）、`range.lastMonth`
  （"Last month"/"上个月"）、`range.custom`（"Custom"/"自定义"）。
- 新增：`toolbar.customRange.edit`（"Edit custom range"/"编辑自定义范围"，
  日历图标按钮的 `.help` 提示文案）、`customRange.from`（"From"/"从"）、
  `customRange.to`（"To"/"到"，两个 `DatePicker` 各自的 `Text` 标签）、
  `customRange.done`（"Done"/"完成"，弹窗里收起按钮的文案）。

## 数据流

无新增数据源。`DataStore.querySummary`/`queryAggregateTimeline` 认的都是
`since`/`until` 两个 `TimeInterval`，不关心这两个值是从哪个 `TimeRange`
算出来的——`.custom` 走同一套查询路径，跟其它 6 档没有区别。

## 测试

- `TimeRange` 每个新 case 的区间算法：跟现有 `TimeRangeBoundaryTests` 同一
  个类里加断言（`.yesterday` 是"今天往前一天"整天；`.last7Days`/
  `.last30Days` 跨度分别正好 7/30 个日历天，起点用 `calendar.date(byAdding:)`
  而不是固定秒数（夏令时安全，复用现成的 DST 测试写法）；`.lastMonth` 是
  上一个日历月整月，跨年边界要测一次（比如"现在是 1 月" → 上个月是去年
  12 月）。
- `resolvedInterval(customStart:customEnd:)`：非 custom 的 case 返回值应该
  跟 `DateInterval(start: start, end: end)` 一致；custom 场景下断言
  `customStart`/`customEnd` 传反了（`start > end`）时也能算出正确排序的
  区间（`min`/`max` 那两行）。这是个纯函数，直接测，不需要渲染视图。
- `CollectorService.applyTimeRange`：**不**新增一条端到端跑真实
  `DataStore.shared`/`TrafficPipeline.shared` 的 `.custom` 集成测试——
  `resolvedInterval` 本身已经在上一条纯函数测试里验证得很充分，
  `applyTimeRange` 这次的改动只是把"直接读 `range.start`/`range.end`"换成
  "读 `resolvedInterval(...)` 的结果"，是一处机械的、明显正确的替换；现有
  `TimeRangeRolloverTests.testFramePastWindowEndReloadsCurrentRange`（用
  `.today` 走 `applyTimeRange`）继续通过就足以证明非 custom 路径没有回归。
  只新增一条 `Preferences.customRangeStart`/`customRangeEnd` 的读写往返
  测试（跟其它 `Preferences` 属性同一种测法）。`.custom` 端到端的正确性
  （弹窗改日期 → 图表/表格真的刷新成新区间）留给下面 UI 任务的手动验证。
- 双击一天切到 Custom：没有新的自动化测试（手势层面的行为，
  `MainWindowView`/`TrafficChart` 都没有可渲染视图状态的测试设施，跟这个
  项目里其它纯 UI 接线任务一致）——用 `Scripts/make-app.sh` 打包后手动
  双击验证：双击一天正确切到 Custom 且定位到那一天，单击不受干扰，
  Today/Yesterday 视图下双击一根小时柱子是空操作。
- 工具条下拉菜单 + 日期弹窗：跟这次会话里其它 `MainWindowView` 改动一样，
  没有直接的视图渲染测试设施——用 `Scripts/make-app.sh` 打包后手动点击
  验证（7 个选项都能选中、Custom 弹窗能正常改日期、改完图表和表格都刷新）。

## 范围说明

本次不包含：把"最近 N 天"数字做成用户可配置（`7`/`30` 都是硬编码常量，
跟上个 PR 的 `24` 一样）；不包含让下拉按钮显示 Custom 实际选中的日期区间
（按钮文字固定显示"Custom"）；不包含给超长 Custom 区间（比如跨一整年）加
更粗的分桶档位（周/月级）——沿用现有"按天分桶"的通用逻辑，超长区间会铺出
很多天柱子，暂不处理，后续如果真的成为问题再单独立项。
