import Foundation

/// 主窗口聚合趋势图的 ViewModel：定期把全部进程的时间线查回来。
///
/// 跟 `DetailViewModel`（`Views/Detail/DetailWindow.swift`）是同一套写法，
/// 区别只是查询走 `queryAggregateTimeline` 而不是按单个 processKey 过滤。
@MainActor
final class AggregateChartViewModel: ObservableObject {
    @Published var timeline: [TimelinePoint] = []

    /// 可注入，默认用单例。测试传一个独立的 `DataStore()` 实例，避免跟其它
    /// 测试共享 `.shared` 单例——`.shared` 一旦被某个测试 `setup()` 过，
    /// `isSetup` 守卫会让同一进程里后续的 `setup()` 静默失效，多个测试方法
    /// 之间就会互相踩库，`resetForTesting()` 也压不住这种同类互扰。
    private let store: DataStore
    /// 可注入，默认用系统当前时区。`loadDailyBuckets` 靠它把小时点合并成
    /// "本地日历天"——测试传一个固定时区的 `Calendar`，才能在任何跑测试的
    /// 机器上都验证得出"日边界按本地时区对齐，不是 UTC"这件事。
    private let calendar: Calendar
    private var refreshTask: Task<Void, Never>?

    init(store: DataStore = .shared, calendar: Calendar = .current) {
        self.store = store
        self.calendar = calendar
    }

    /// `until` 显式传入而不是默认"现在"——Today 要固定用「今天零点 ~ 明天零点」
    /// 这个完整的日历区间，这样不管现在是几点，都能铺出完整 24 根柱子（还没
    /// 到的钟点自然是 0），而不是只显示"从零点到现在"这一段、越往前柱子越少。
    func startRefreshing(since: TimeInterval, until: TimeInterval) {
        stopRefreshing()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.load(since: since, until: until)
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    func stopRefreshing() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// `until` 跟 `queryAggregateTimeline` 保持同一套闭区间语义
    /// （`timestamp <= until`）——不在这里偷偷改成排他终点。像"今天零点到
    /// 明天零点"这种"明天零点不算今天"的排他终点转换，交给调用方
    /// （`AggregateTrafficCard`）做，因为只有它知道自己传的 `until` 到底是
    /// "现在"（该闭区间，不能排除掉这一刻）还是日历边界（该排他）。
    func load(since: TimeInterval, until: TimeInterval) async {
        let points: [TimelinePoint]
        if usesDailyBuckets(for: until - since) {
            points = (try? await loadDailyBuckets(since: since, until: until)) ?? []
        } else {
            points = (try? await store.queryAggregateTimeline(
                since: since, until: until, bucketSeconds: 3_600
            )) ?? []
        }
        if timeline != points { timeline = points }
    }

    /// 聚合图是给你看大局的总览，不需要跟单进程详情图一样细——
    /// ≤1 天固定按整点分桶（一天 24 根柱子，对应"按小时看"），超过 1 天按
    /// 本地日历天分桶（"Last 24 days" 铺 24 根、"This month" 铺 28-31 根）。
    ///
    /// 阈值用 2 天（`2 * 86_400`）而不是 1 天：夏令时那天本身只有 23 或 25
    /// 小时，Today 自己的 `range` 会略偏离 86_400，用 1 天做分界会在夏令时
    /// 切换那天把 Today 自己误判成"该按天分桶"——跳到 2 天的阈值就不会被这
    /// 1 小时的偏差带偏，Today 永远落在"按小时"这一边。
    private func usesDailyBuckets(for range: TimeInterval) -> Bool {
        range >= 2 * 86_400
    }

    /// 按本地日历天重新分桶。
    ///
    /// `DataStore.queryAggregateTimeline` 的 SQL 是拿 `timestamp / bucketSeconds`
    /// 整除对齐桶边界的，桶大小是一整天（`86_400`）时，边界会落在 **UTC 零点**
    /// ——在非 UTC 时区（比如 +0800）UTC 零点是本地上午 8 点，不是本地零点，
    /// 一整天的桶因此整体偏移了 8 小时，桶的数量也会因为区间端点跟桶边界对不
    /// 齐而多算/少算一根。改成按小时查（小时级的 epoch 对齐在这个问题上没有
    /// 影响——`3_600` 整除的边界跟"整点时区"的本地小时边界本来就重合），再用
    /// `Calendar`（走本地时区，夏令时也交给它处理，不用自己算偏移量）把同一
    /// 本地日历天的小时点合并成一根天柱。
    ///
    /// 一天里只要有任意一个小时"有采集"（`isCovered`），这一天就算有采集——
    /// 一整天完全没开机/没跑采集器才标"没采集"的灰带，采集器当天中途启动
    /// 不该让这一整天都显示成灰带。
    private func loadDailyBuckets(since: TimeInterval, until: TimeInterval) async throws -> [TimelinePoint] {
        let hourly = try await store.queryAggregateTimeline(since: since, until: until, bucketSeconds: 3_600)
        guard !hourly.isEmpty else { return [] }

        var byDay: [TimeInterval: [TimelinePoint]] = [:]
        var dayOrder: [TimeInterval] = []
        for point in hourly {
            let dayStart = calendar.startOfDay(for: Date(timeIntervalSince1970: point.timestamp))
                .timeIntervalSince1970
            if byDay[dayStart] == nil { dayOrder.append(dayStart) }
            byDay[dayStart, default: []].append(point)
        }

        return dayOrder.map { dayStart in
            let hours = byDay[dayStart] ?? []
            return TimelinePoint(
                timestamp: dayStart,
                bytesIn: hours.reduce(0) { $0 + $1.bytesIn },
                bytesOut: hours.reduce(0) { $0 + $1.bytesOut },
                peakIn: hours.map(\.peakIn).max() ?? 0,
                peakOut: hours.map(\.peakOut).max() ?? 0,
                isCovered: hours.contains { $0.isCovered }
            )
        }
    }
}
