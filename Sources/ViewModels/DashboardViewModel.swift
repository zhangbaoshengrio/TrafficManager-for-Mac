import AppKit
import Foundation

/// 仪表盘 ViewModel
///
/// 只做一件事：接住管线推来的 `DashboardSnapshot`，摊成视图直接可用的属性。
/// 所有聚合计算都发生在 `TrafficPipeline` actor 上，这里不做重活。
///
/// 用 `@Observable` 而非 `ObservableObject`，SwiftUI 按**属性**粒度追踪依赖：
/// 速率数字每秒变化只会让 3 张汇总卡片失效，不会把整个 `NavigationSplitView`
/// 连同表格一起推倒重排（那正是重构前 72% CPU 的来源）。
///
/// 每次赋值前都比一次相等：没变就不写，也就不会触发任何重绘。
@Observable
@MainActor
final class DashboardViewModel {
    /// 应用级唯一实例。菜单栏和主窗口共用同一份状态。
    static let shared = DashboardViewModel()

    // MARK: 视图数据

    private(set) var rows: [ProcessRow] = []
    private(set) var groupRows: [GroupRow] = []
    /// 菜单栏面板的行。经过平滑与驻留，刻意**不随**主窗口的搜索/排序变化 ——
    /// 详见 `MenuBarRowLedger`。
    private(set) var menuBarRows: [MenuBarRow] = []
    private(set) var totalRxRate: Double = 0
    private(set) var totalTxRate: Double = 0
    private(set) var totalTraffic: Int64 = 0
    private(set) var totalDownloaded: Int64 = 0
    private(set) var totalUploaded: Int64 = 0

    // MARK: 视图状态

    var sortOrder: [KeyPathComparator<ProcessRow>] = [
        KeyPathComparator(\ProcessRow.totalBytes, order: .reverse)
    ] {
        didSet { resort() }
    }

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

    /// 进程名过滤（工具栏搜索框）
    var searchText: String = "" {
        didSet { guard searchText != oldValue else { return }; resort() }
    }
    var isGroupedView = false {
        didSet { rebuildGroups() }
    }
    var processGroups: [ProcessGroup] = [] {
        didSet { rebuildGroups() }
    }

    /// 最近一次快照（未排序原始行），排序/分组变化时据此重算
    @ObservationIgnored private var latest = DashboardSnapshot()
    @ObservationIgnored private var menuBarLedger = MenuBarRowLedger()

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

    // MARK: - 订阅

    /// 建立对采集快照的订阅。
    ///
    /// 这件事的生命周期跟着**应用**，不跟着窗口。之前放在主窗口的
    /// `onAppear`/`onDisappear` 里，关掉窗口就把 sink 置空，菜单栏的数字
    /// 随即冻住 —— 而菜单栏模式的整个意义就是没有窗口时也能看。
    ///
    /// 真正该省的开销由管线侧的可见性闸门负责（`setUIVisible`），
    /// 那里能区分「窗口被遮挡」和「菜单栏还需要数据」。
    func startObserving() {
        CollectorService.shared.snapshotSink = { [weak self] snapshot in
            self?.apply(snapshot)
        }
    }

    func loadGroups() { processGroups = GroupStore.shared.load() }

    // MARK: - 快照落地

    func apply(_ snapshot: DashboardSnapshot) {
        latest = snapshot

        if totalRxRate != snapshot.totalRxRate { totalRxRate = snapshot.totalRxRate }
        if totalTxRate != snapshot.totalTxRate { totalTxRate = snapshot.totalTxRate }
        if totalTraffic != snapshot.totalBytes { totalTraffic = snapshot.totalBytes }
        if totalDownloaded != snapshot.totalIn { totalDownloaded = snapshot.totalIn }
        if totalUploaded != snapshot.totalOut { totalUploaded = snapshot.totalOut }

        let sorted = sortedRows(snapshot.rows)
        if rows != sorted { rows = sorted }

        // 喂未过滤的原始行：菜单栏不该受主窗口搜索框影响
        let menu = menuBarLedger.update(with: snapshot.rows)
        if menuBarRows != menu { menuBarRows = menu }

        rebuildGroups()
    }

    // MARK: - 排序 / 分组

    private func resort() {
        let sorted = sortedRows(latest.rows)
        if rows != sorted { rows = sorted }
    }

    private func sortedRows(_ source: [ProcessRow]) -> [ProcessRow] {
        var rows = source
        let needle = searchText.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty {
            rows = rows.filter { $0.displayName.localizedCaseInsensitiveContains(needle) }
        }
        guard !sortOrder.isEmpty else { return rows }
        return rows.sorted(using: sortOrder)
    }

    private func rebuildGroups() {
        guard isGroupedView else {
            if !groupRows.isEmpty { groupRows = [] }
            return
        }
        var items: [GroupRow] = []
        var accounted = Set<String>()

        for g in processGroups {
            var totalIn: Int64 = 0, totalOut: Int64 = 0
            var rx = 0.0, tx = 0.0, count = 0
            for r in latest.rows where g.contains(processKey: r.key) {
                totalIn += r.totalIn; totalOut += r.totalOut
                rx += r.rxRate; tx += r.txRate
                count += 1
                accounted.insert(r.key)
            }
            items.append(GroupRow(id: g.id, name: g.name, isOthers: false,
                                  totalIn: totalIn, totalOut: totalOut,
                                  rxRate: rx, txRate: tx, memberCount: count))
        }

        let others = latest.rows.filter { !accounted.contains($0.key) }
        if !others.isEmpty {
            items.append(GroupRow(
                id: Self.othersGroupID,
                name: L("group.others"),
                isOthers: true,
                totalIn: others.reduce(0) { $0 + $1.totalIn },
                totalOut: others.reduce(0) { $0 + $1.totalOut },
                rxRate: others.reduce(0) { $0 + $1.rxRate },
                txRate: others.reduce(0) { $0 + $1.txRate },
                memberCount: others.count
            ))
        }

        items.sort { $0.totalBytes > $1.totalBytes }
        if groupRows != items { groupRows = items }
    }

    /// 「其他」分组用固定 ID，否则每次重建都是新身份，列表会整体重绘
    private static let othersGroupID = UUID()
}
