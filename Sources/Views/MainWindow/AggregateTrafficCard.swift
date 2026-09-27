import Charts
import SwiftUI

/// 主窗口顶部的聚合流量趋势图卡片：全部进程加总，固定柱状图样式。
///
/// 直接复用 `TrafficChart`（`Views/Detail/DetailWindow.swift`）——它只认
/// `[TimelinePoint]`，从不关心数据是单进程的还是聚合的。
@MainActor
struct AggregateTrafficCard: View {
    /// 查询窗口的起止——用明确的起止时刻而不是"过去 N 秒"，Today 才能铺出
    /// 完整 24 根柱子（今天零点 ~ 明天零点），不会随着"现在是几点"忽多忽少。
    /// `until` 在这里是**排他**终点（"明天零点不算今天"），跟
    /// `DashboardViewModel.TimeRange.end` 的语义一致；`AggregateChartViewModel`/
    /// `DataStore.queryAggregateTimeline` 走的是闭区间，转换在 `queryUntil` 里做。
    let since: TimeInterval
    let until: TimeInterval
    /// 当前生效的选中范围（由 `MainWindowView` 持有并传回）——不在本视图内部
    /// 单独存一份选中状态，否则外部点 Clear 清空后，这里没法知道要跟着取消
    /// 高亮。`nil` = 未选中任何柱子。
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
    /// 定位到那一天）。
    var onDoubleSelectDay: ((TimelinePoint) -> Void)?

    @StateObject private var vm = AggregateChartViewModel()

    private var range: TimeInterval { until - since }

    /// `AggregateChartViewModel.load`/`queryAggregateTimeline` 认的是闭区间
    /// （含 `until` 本身那一刻）；`until` 传进来的是排他终点，减 1 秒换算成
    /// "最后一个仍然算数的时刻"——`until` 正好落在整点上时（Today 的场景），
    /// 不减这 1 秒会多铺出属于下一个周期的第 25 根柱子。
    private var queryUntil: TimeInterval { until - 1 }

    /// 从实际数据点的间距推算桶大小，而不是重新猜一遍
    /// `AggregateChartViewModel` 内部用的规则——两边分桶逻辑一旦哪天改了，
    /// 这里不用跟着改，永远和真实数据对得上。
    private var bucketSeconds: TimeInterval {
        vm.timeline.count >= 2
            ? vm.timeline[1].timestamp - vm.timeline[0].timestamp
            : 3_600
    }

    /// `selectedRange` 只是一对时间戳，换算回 `TrafficChart` 用来判断高亮的
    /// `TimelinePoint`
    private var selectedBucket: TimelinePoint? {
        guard let selectedRange else { return nil }
        return vm.timeline.first { $0.timestamp == selectedRange.lowerBound }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("aggregate.trafficOverTime")).font(.headline)

            if vm.timeline.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "chart.bar")
                        .font(.system(size: 22)).foregroundStyle(.secondary)
                    Text(L("detail.noData")).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                TrafficChart(points: vm.timeline, style: .bar, range: range,
                            bucketSecondsOverride: bucketSeconds,
                            domainEnd: Date(timeIntervalSince1970: until),
                            selectedBucket: selectedBucket,
                            onDoubleSelectBucket: onDoubleSelectDay) { point in
                    guard let point else { onSelectRange?(nil); return }
                    onSelectRange?(point.timestamp ... (point.timestamp + bucketSeconds))
                }
                .frame(height: 300)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.12)))
        .onAppear { vm.startRefreshing(since: since, until: queryUntil) }
        .onDisappear { vm.stopRefreshing() }
        .onChange(of: since) { _, _ in vm.startRefreshing(since: since, until: queryUntil) }
        .onChange(of: until) { _, _ in vm.startRefreshing(since: since, until: queryUntil) }
        .onChange(of: vm.timeline) { _, _ in onBucketSecondsChange?(bucketSeconds) }
    }
}
