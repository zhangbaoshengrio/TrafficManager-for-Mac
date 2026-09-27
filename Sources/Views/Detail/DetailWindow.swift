import Charts
import Combine
import SwiftUI

// MARK: - Detail ViewModel

@MainActor
final class DetailViewModel: ObservableObject {
    @Published var timeline: [TimelinePoint] = []

    private var refreshTask: Task<Void, Never>?

    func startRefreshing(processKey: String, range: TimeInterval) {
        stopRefreshing()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.load(processKey: processKey, range: range)
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    func stopRefreshing() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func load(processKey: String, range: TimeInterval) async {
        let since = Date().timeIntervalSince1970 - range
        let points = (try? await DataStore.shared.queryTimeline(
            processKey: processKey,
            since: since,
            bucketSeconds: TimelineBucket.size(for: range)
        )) ?? []
        if timeline != points { timeline = points }
    }
}

// MARK: - 时间桶

/// 时间桶随跨度自适应：跨度越大桶越粗，避免 7 天视图挤上千个点。
/// 纯函数，采集侧和视图侧共用同一套规则。
enum TimelineBucket {
    static func size(for range: TimeInterval) -> TimeInterval {
        switch range {
        case ..<7_200:    60      // ≤1h  → 1 分钟
        case ..<86_400:   300     // ≤24h → 5 分钟
        case ..<259_200:  1_800   // ≤3d  → 30 分钟
        default:          3_600   // 更长 → 1 小时
        }
    }

    /// 稀疏数据点的分段：相邻两点之间空了一个以上的桶 → 中间没有采集到数据，
    /// 线段必须断开。返回每个点所属的段号（从 0 开始，逐洞递增）。
    ///
    /// 阈值取 1.5 个桶：正常相邻是 1 个桶，缺一个就变成 2 个，跨过阈值即断。
    static func segmentIndices(_ points: [TimelinePoint], bucket: TimeInterval) -> [Int] {
        var indices: [Int] = []
        indices.reserveCapacity(points.count)
        var segment = 0
        var previous: TimeInterval?
        for point in points {
            if let previous, point.timestamp - previous > bucket * 1.5 {
                segment += 1
            }
            indices.append(segment)
            previous = point.timestamp
        }
        return indices
    }
}

// MARK: - 图表样式

enum ChartStyle: String, CaseIterable, Identifiable {
    // rawValue 是**持久化用的稳定标识**，不是展示文案。
    // 一开始把中文显示名直接当 rawValue 存进 UserDefaults，
    // 这既让存储内容依赖界面语言（将来做多语言时旧偏好全部失效），
    // 也让 Picker 的初始选中项对不上。展示文案走 `label`。
    case line, area, bar

    var id: String { rawValue }

    var label: String {
        switch self {
        case .line: L("detail.style.line")
        case .area: L("detail.style.area")
        case .bar:  L("detail.style.bar")
        }
    }

    var symbol: String {
        switch self {
        case .line: "chart.xyaxis.line"
        case .area: "chart.line.uptrend.xyaxis"
        case .bar:  "chart.bar.fill"
        }
    }
}

// MARK: - Detail Window

@MainActor
struct DetailWindow: View {
    let row: ProcessRow

    @Environment(\.dismiss) private var dismiss
    @Environment(DashboardViewModel.self) private var dashboard
    @StateObject private var vm = DetailViewModel()

    @AppStorage("com.trafficmonitor.detail.range") private var range: Double = 86_400
    @AppStorage("com.trafficmonitor.detail.style") private var styleRaw: String = ChartStyle.line.rawValue
    /// 上行是否画到零轴下方。默认 false = 与下载同轴（都在上方）。
    @AppStorage("com.trafficmonitor.detail.uploadBelowAxis") private var uploadBelowAxis = false

    private var style: ChartStyle { ChartStyle(rawValue: styleRaw) ?? .line }

    /// 实时速率直接读管线推来的行快照，不另设定时器
    private var live: ProcessRow? { dashboard.rows.first { $0.key == row.key } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            summaryBar.padding(.horizontal).padding(.vertical, 10)
            Divider()
            chartArea
        }
        .frame(minWidth: 720, idealWidth: 860, minHeight: 520, idealHeight: 600)
        .onAppear { vm.startRefreshing(processKey: row.key, range: range) }
        .onDisappear { vm.stopRefreshing() }
        .onChange(of: range) { _, newValue in
            vm.startRefreshing(processKey: row.key, range: newValue)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            ProcessIcon(row: row, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.displayName).font(.title3.weight(.medium))
                if let bundleId = row.bundleId {
                    Text(bundleId).font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer()

            Picker("", selection: $range) {
                Text(L("detail.range.1h")).tag(3_600.0)
                Text(L("detail.range.6h")).tag(21_600.0)
                Text(L("detail.range.24h")).tag(86_400.0)
                Text(L("detail.range.7d")).tag(604_800.0)
            }
            .pickerStyle(.segmented).frame(width: 230).labelsHidden()

            Picker("", selection: $styleRaw) {
                ForEach(ChartStyle.allCases) { s in
                    Image(systemName: s.symbol).tag(s.rawValue).help(s.label)
                }
            }
            .pickerStyle(.segmented).frame(width: 110).labelsHidden()
            .help(L("detail.chartStyle.help"))

            // 上行放在零轴上方（同轴）还是镜像到下方
            Picker("", selection: $uploadBelowAxis) {
                Text(L("detail.layout.above")).tag(false)
                Text(L("detail.layout.mirror")).tag(true)
            }
            .pickerStyle(.menu).fixedSize().labelsHidden()
            .help(L("detail.layout.help"))

            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).help(L("detail.close"))
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal).padding(.vertical, 10)
    }

    // MARK: Summary

    private var summaryBar: some View {
        let totalIn = vm.timeline.reduce(0) { $0 + $1.bytesIn }
        let totalOut = vm.timeline.reduce(0) { $0 + $1.bytesOut }
        // 峰值取桶内记下的最高瞬时速率，而不是「桶字节 ÷ 桶长」——
        // 后者是均值，10 秒跑满 22 Gbps 会被摊成 3.8 Gbps
        let peakIn = vm.timeline.map(\.peakIn).max() ?? 0
        let peakOut = vm.timeline.map(\.peakOut).max() ?? 0

        return HStack(spacing: 0) {
            stat(L("detail.liveDownload"), ByteFormatter.rateString(bytesPerSecond: live?.rxRate ?? 0),
                 .blue, highlight: (live?.rxRate ?? 0) > 0)
            divider
            stat(L("detail.liveUpload"), ByteFormatter.rateString(bytesPerSecond: live?.txRate ?? 0),
                 .red, highlight: (live?.txRate ?? 0) > 0)
            divider
            stat(L("detail.rangeDownload"), ByteFormatter.string(bytes: totalIn), .blue)
            divider
            stat(L("detail.rangeUpload"), ByteFormatter.string(bytes: totalOut), .red)
            divider
            stat(L("detail.total"), ByteFormatter.string(bytes: totalIn + totalOut))
            divider
            stat(L("detail.peakDownload"), ByteFormatter.rateString(bytesPerSecond: peakIn), .blue.opacity(0.7))
            divider
            stat(L("detail.peakUpload"), ByteFormatter.rateString(bytesPerSecond: peakOut), .red.opacity(0.7))
            Spacer()
            // 补零之后 timeline 里大部分点是「采集到了但没流量」，
            // 这里只数真有流量的那些点
            stat(L("detail.dataPoints"),
                 "\(vm.timeline.filter { $0.totalBytes > 0 }.count)", .secondary)
        }
    }

    private var divider: some View {
        Divider().frame(height: 28).padding(.horizontal, 12)
    }

    private func stat(_ label: String, _ value: String,
                     _ color: Color = .primary, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 10)).foregroundStyle(highlight ? color : .secondary)
            Text(value).font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(color)
        }
    }

    // MARK: Chart

    @ViewBuilder
    private var chartArea: some View {
        if vm.timeline.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "chart.xyaxis.line").font(.system(size: 28)).foregroundStyle(.secondary)
                Text(L("detail.noData")).foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            TrafficChart(points: vm.timeline, style: style, range: range,
                         mirrorsUpload: uploadBelowAxis)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
        }
    }
}

// MARK: - 图表

/// 用 Swift Charts 重写。
///
/// 旧实现是手绘 `Path` + 手算坐标 + 手摆刻度标签，约 200 行，只能画直线折线，
/// 且坐标轴刻度、hover 命中、深色模式配色都得自己维护。
/// Swift Charts 直接给出平滑插值、原生坐标轴与选取覆盖层，样式切换也只是换 Mark 类型。
struct TrafficChart: View {
    let points: [TimelinePoint]
    let style: ChartStyle
    let range: TimeInterval
    /// 上行是否镜像到零轴下方。默认 false = 与下载同轴（都画在零轴上方）。
    var mirrorsUpload = false
    /// 桶大小的显式覆盖。默认 nil = 沿用 `TimelineBucket.size(for: range)`
    /// （`DetailWindow` 现有用法不受影响）。调用方喂进来的 `points` 如果不是
    /// 按这套规则分桶的（比如聚合图对"Today"固定用整点分桶），必须显式传入
    /// 真实桶大小——否则这里推算出的桶大小和数据实际间距对不上，会把每根
    /// 柱子都误判成"孤立"。
    var bucketSecondsOverride: TimeInterval?
    /// x 轴终点的显式覆盖。默认 nil = 用 `Date()`（`DetailWindow` 现有"过去 N
    /// 小时到现在"的语义不变）。聚合图 Today 要铺满整个日历日（零点到零点），
    /// 终点得是"明天零点"而不是"现在"，否则一天没过完时后面的钟点不会出现。
    var domainEnd: Date?
    /// 当前"已确认点击选中"的桶，由调用方持有并传回——这里不自己存点击状态，
    /// 否则外部点 Clear 清空选择时，图表这边的高亮对不上，留下一根不该还亮着
    /// 的柱子。`nil` = 都不高亮，全部正常显示。
    var selectedBucket: TimelinePoint?
    /// 双击某根柱子时回调（只在真的双击时触发，单击的 `onSelectBucket` 不
    /// 受影响）。默认不设——目前只有聚合图顶层的天柱需要它（双击一天直接
    /// 切到 Custom 定位到那一天）。放在 `onSelectBucket` 前面，让后者继续
    /// 留在最后一个参数的位置，调用方尾随闭包写法不用改。
    var onDoubleSelectBucket: ((TimelinePoint) -> Void)?
    /// 选中的桶发生变化时回调（nil = 取消选中）。默认不设，`DetailWindow` 现有
    /// 用法不受影响。放在最后一个参数，调用方可以用尾随闭包写法。
    var onSelectBucket: ((TimelinePoint?) -> Void)?

    /// 光标选中的时间点（悬停）
    @State private var selected: Date?

    /// 虚线 + 悬浮提示卡该显示哪个点：优先悬停中的那个，没有悬停时退回到
    /// 点击选中的桶（`selectedBucket`）——这样点一下柱子，提示卡会钉住显示
    /// 那根柱子的时间段和上传/下载数值，不需要鼠标一直悬停在上面。
    private var displayedPoint: TimelinePoint? { selectedPoint ?? selectedBucket }

    /// 虚线 / 悬浮卡片对齐柱子中心用的时间偏移。聚合图的柱子用 `xStart`/`xEnd`
    /// 往右缩进画（见 `barMark`），柱子的视觉中心比 `Sample.date`（桶的起始
    /// 时刻）晚半个桶；折线/面积图和详情窗口自己的单点柱状（Swift Charts
    /// 按点自动居中）不需要这个偏移，否则虚线反而会偏到柱子外面。
    private var barCenterOffset: TimeInterval {
        style == .bar && bucketSecondsOverride != nil ? bucket / 2 : 0
    }

    private var bucket: TimeInterval { bucketSecondsOverride ?? TimelineBucket.size(for: range) }

    /// 图表按**速率**画而不是按字节，这样换时间跨度（桶大小随之改变）时纵轴含义保持一致
    private struct Sample: Identifiable {
        /// 用「时间 + 方向」做稳定 id：若用 UUID()，每次刷新都是全新身份，
        /// Chart 会把整幅图当作新数据重画并重跑动画。
        var id: String { "\(date.timeIntervalSince1970)-\(direction)" }
        let date: Date
        let rate: Double
        let direction: String
        /// 所属线段。相邻数据点之间空了一个桶就换段 —— 画线时不能跨段连，
        /// 否则「6 小时没有数据」会被画成一条斜线。
        let segment: Int
        /// 这一段只有它自己：断线之后得画个圆点，不然什么都没有。
        let isIsolated: Bool
        /// 柱状堆叠时这根柱子在纵轴上的起止。折线/面积图不用这两个字段
        /// （继续用 `rate`），只有聚合图的同轴柱状（`bucketSecondsOverride`
        /// 不为 nil 且未镜像）会把上传接到下载顶部：下载是 0...rate，
        /// 上传是 downloadRate...(downloadRate+uploadRate) —— 两根柱子首尾
        /// 相接堆成一根，而不是各画到零轴、谁高谁盖住谁。
        let stackStart: Double
        let stackEnd: Double

        /// 画线的分组键：**段 × 方向**。
        /// 只按段分组会把同一段的「下载点」和「上传点」连起来，画出一条竖线。
        var seriesKey: String { "\(direction)#\(segment)" }
    }

    private var samples: [Sample] {
        let segments = TimelineBucket.segmentIndices(points, bucket: bucket)
        var sizeBySegment: [Int: Int] = [:]
        for segment in segments { sizeBySegment[segment, default: 0] += 1 }

        return points.enumerated().flatMap { index, p -> [Sample] in
            let date = Date(timeIntervalSince1970: p.timestamp)
            let segment = segments[index]
            let isolated = sizeBySegment[segment] == 1
            let downloadRate = Double(p.bytesIn) / bucket
            let uploadRate = Double(p.bytesOut) / bucket
            let uploadSigned = (mirrorsUpload ? -1 : 1) * uploadRate
            return [
                // 下载固定画在零轴上方；上行默认同轴（也在上方），开启镜像后取负值
                // 画到轴下方 —— 那样两个方向的填充不再互相叠色。
                Sample(date: date, rate: downloadRate,
                       direction: L("chart.series.download"), segment: segment, isIsolated: isolated,
                       stackStart: 0, stackEnd: downloadRate),
                Sample(date: date, rate: uploadSigned,
                       direction: L("chart.series.upload"), segment: segment, isIsolated: isolated,
                       stackStart: mirrorsUpload ? 0 : downloadRate,
                       stackEnd: mirrorsUpload ? uploadSigned : downloadRate + uploadRate),
            ]
        }
    }

    /// 没采集的时段（连续的 isCovered = false），画成灰带
    private struct CoverageGap: Identifiable {
        var id: TimeInterval { start.timeIntervalSince1970 }
        let start: Date
        let end: Date
    }

    private var coverageGaps: [CoverageGap] {
        var gaps: [CoverageGap] = []
        var runStart: TimeInterval?
        var runEnd: TimeInterval?
        for point in points {
            if point.isCovered {
                if let start = runStart, let end = runEnd {
                    gaps.append(CoverageGap(start: Date(timeIntervalSince1970: start),
                                            end: Date(timeIntervalSince1970: end)))
                }
                runStart = nil
                runEnd = nil
            } else {
                if runStart == nil { runStart = point.timestamp }
                runEnd = point.timestamp + bucket
            }
        }
        if let start = runStart, let end = runEnd {
            gaps.append(CoverageGap(start: Date(timeIntervalSince1970: start),
                                    end: Date(timeIntervalSince1970: end)))
        }
        return gaps
    }

    /// 纵轴范围：从样本推出来并留一点余量，灰带要铺满整个绘图区高度。
    /// 聚合图柱状（`bucketSecondsOverride` 不为 nil）按 `stackStart`/`stackEnd`
    /// 算——同轴时那是堆叠后的总高，镜像时和 `rate` 等价，两种场景都对。
    private var rateRange: ClosedRange<Double> {
        let usesBucketedBars = style == .bar && bucketSecondsOverride != nil
        let values = usesBucketedBars
            ? samples.flatMap { [$0.stackStart, $0.stackEnd] }
            : samples.map(\.rate)
        let lower = min(values.min() ?? 0, 0)
        let upper = max(values.max() ?? 0, 0)
        guard upper > lower else { return 0 ... 1 }
        let pad = (upper - lower) * 0.06
        return (lower - pad) ... (upper + pad)
    }

    /// 点击 / 悬停命中判定：按"柱子视觉中心"找最近点。聚合图的柱子视觉中心
    /// 比 `Sample.date`（桶起始时刻）晚 `barCenterOffset`——直接拿桶起始时刻
    /// 找最近点的话，每根柱子右半边的点击/悬停会被判给下一个桶，跟眼睛看到
    /// 的对不上（分界线卡在柱子中间，而不是柱子和柱子之间的空隙）。
    func nearestPoint(to date: Date) -> TimelinePoint? {
        let target = date.timeIntervalSince1970 - barCenterOffset
        return points.min(by: { abs($0.timestamp - target) < abs($1.timestamp - target) })
    }

    private var selectedPoint: TimelinePoint? {
        guard let selected, let nearest = nearestPoint(to: selected) else { return nil }
        // 光标落在空洞里（离最近的数据点超过一个桶）时不弹气泡 ——
        // 那里没有数据，弹一个远处的读数反而是误导
        let target = selected.timeIntervalSince1970 - barCenterOffset
        return abs(nearest.timestamp - target) <= bucket ? nearest : nil
    }

    var body: some View {
        Chart {
            // 零轴：镜像模式下是上下两个方向的分界，同轴模式下是两条曲线的基线
            RuleMark(y: .value(L("chart.axis.rate"), 0))
                .foregroundStyle(.secondary.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 1))

            // 没采集的时段：补 0 让折线连续，但这里铺一层浅灰带，
            // 说明「这一段没有测量」而不是「测到 0」
            ForEach(coverageGaps) { gap in
                RectangleMark(xStart: .value(L("chart.axis.time"), gap.start),
                              xEnd: .value(L("chart.axis.time"), gap.end),
                              yStart: .value(L("chart.axis.rate"), rateRange.lowerBound),
                              yEnd: .value(L("chart.axis.rate"), rateRange.upperBound))
                    .foregroundStyle(Color.gray.opacity(0.10))
            }

            ForEach(samples) { s in
                switch style {
                case .line:
                    // series 按段分组：空洞两侧的点属于不同 series，线不会跨过去
                    LineMark(x: .value(L("chart.axis.time"), s.date),
                             y: .value(L("chart.axis.rate"), s.rate),
                             series: .value("series", s.seriesKey))
                        .foregroundStyle(by: .value(L("chart.series"), s.direction))
                        .symbol { isolatedSymbol(s) }
                        .interpolationMethod(.monotone)      // 平滑但不过冲：catmullRom 会在尖峰两侧冲出负值
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                case .area:
                    // 各自从 0 填到自己的数值。必须显式 .unstacked：AreaMark 默认按分组
                    // 堆叠，会把两个方向摞到一起（同轴时紫一块蓝一块，读数完全对不上 ——
                    // 0.7.x 修过一次，换成 yStart/yEnd 那个重载时又踩回去了）。
                    AreaMark(x: .value(L("chart.axis.time"), s.date),
                             y: .value(L("chart.axis.rate"), s.rate),
                             series: .value("series", s.seriesKey),
                             stacking: .unstacked)
                        .foregroundStyle(by: .value(L("chart.series"), s.direction))
                        .interpolationMethod(.monotone)      // 同上，速率不能过冲到轴的另一侧
                        .opacity(0.28)
                    LineMark(x: .value(L("chart.axis.time"), s.date),
                             y: .value(L("chart.axis.rate"), s.rate),
                             series: .value("series", s.seriesKey))
                        .foregroundStyle(by: .value(L("chart.series"), s.direction))
                        .symbol { isolatedSymbol(s) }
                        .interpolationMethod(.monotone)      // 同上，速率不能过冲到轴的另一侧
                        .lineStyle(StrokeStyle(lineWidth: 1.5))

                case .bar:
                    barMark(for: s)
                }

                if let displayedPoint, s.date == Date(timeIntervalSince1970: displayedPoint.timestamp) {
                    RuleMark(x: .value(L("chart.axis.time"), s.date.addingTimeInterval(barCenterOffset)))
                        .foregroundStyle(.secondary.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
        }
        // 固定成「所选跨度」而不是按数据自适应：只有一两个点时，
        // 自适应会把轴压到那两点上，位置信息就没了
        .chartXScale(domain: (domainEnd ?? Date()).addingTimeInterval(-range) ... (domainEnd ?? Date()))
        .chartYScale(domain: rateRange)
        .chartForegroundStyleScale([L("chart.series.download"): seriesColor(L("chart.series.download")),
                                    L("chart.series.upload"): seriesColor(L("chart.series.upload"))])
        .chartLegend(position: .top, alignment: .leading, spacing: 8)
        .chartXAxis {
            if let axisTickDates {
                AxisMarks(values: axisTickDates) { _ in
                    AxisGridLine().foregroundStyle(.primary.opacity(0.06))
                    AxisTick()
                    AxisValueLabel(format: axisDateFormat)
                        .font(.system(size: 9, design: .monospaced))
                }
            } else {
                AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                    AxisGridLine().foregroundStyle(.primary.opacity(0.06))
                    AxisTick()
                    AxisValueLabel(format: axisDateFormat)
                        .font(.system(size: 9, design: .monospaced))
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                AxisGridLine().foregroundStyle(.primary.opacity(0.06))
                AxisValueLabel {
                    if let rate = value.as(Double.self) {
                        // 镜像图：标签给幅值，方向看上/下位置与图例
                        Text(ByteFormatter.rateString(bytesPerSecond: abs(rate)))
                            .font(.system(size: 9, design: .monospaced))
                    }
                }
            }
        }
        .chartXSelection(value: $selected)
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
                if let displayedPoint, let plotFrame = proxy.plotFrame {
                    // 之前用固定的 26pt（相对整个图表，含图例行）当 y，柱子靠左时
                    // 提示卡会盖住左上角的图例文字（"Download"/"Upload"）。改成
                    // 相对**绘图区**顶边（图例已经被 Swift Charts 挪到绘图区外面
                    // 上方了）留一段间距，不管图例本身多高都不会被压到。
                    let plotRect = geo[plotFrame]
                    tooltip(for: displayedPoint)
                        .position(
                            x: tooltipX(for: displayedPoint, proxy: proxy, geo: geo, plot: plotFrame),
                            y: plotRect.minY + 34
                        )
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// 显式给坐标轴指定刻度位置，而不是让 Swift Charts 在连续日期轴上自动
    /// 挑"整齐"的位置——聚合图的柱子用 `xStart`/`xEnd` 往右缩进画（见
    /// `barMark`），柱子视觉中心比自动挑出来的刻度值（桶起始时刻）晚
    /// `barCenterOffset`，直接用 `.automatic` 会让刻度整体偏在柱子左边，
    /// 而不是柱子正下方。`nil` 时退回原来的 `.automatic`——`barCenterOffset
    /// == 0` 的场景（`DetailWindow` 自己的单点柱状，Swift Charts 按点自动
    /// 居中）本来就没有这个偏移问题，不需要接管。
    private var axisTickDates: [Date]? {
        guard barCenterOffset != 0, !points.isEmpty else { return nil }
        let desiredCount = 6
        let strideBy = max(1, Int((Double(points.count) / Double(desiredCount)).rounded()))
        return points.enumerated()
            .filter { $0.offset % strideBy == 0 }
            .map { Date(timeIntervalSince1970: $0.element.timestamp).addingTimeInterval(barCenterOffset) }
    }

    private var axisDateFormat: Date.FormatStyle {
        // 天级分桶（聚合图 Last 7/30 days 等）：每个刻度本来就对应一整天，
        // 标签只给日期，不带一个必然是 00 的小时数。子进程详情图从不按天
        // 分桶（`TimelineBucket.size` 最粗到 1 小时），这条分支只影响聚合图。
        if bucket >= 86_400 {
            return .dateTime.month(.defaultDigits).day()
        }
        return range <= 86_400
            ? .dateTime.hour().minute()
            : .dateTime.month(.defaultDigits).day().hour()
    }

    private func tooltipX(for point: TimelinePoint, proxy: ChartProxy,
                          geo: GeometryProxy, plot: Anchor<CGRect>) -> CGFloat {
        let date = Date(timeIntervalSince1970: point.timestamp).addingTimeInterval(barCenterOffset)
        let plotRect = geo[plot]
        let x = (proxy.position(forX: date) ?? 0) + plotRect.origin.x
        // 贴边时把气泡拉回可视区内
        return min(max(x, 90), geo.size.width - 90)
    }

    /// 柱状图的单个 mark，从 `body` 里拆出来——把这段内联在 `switch` 里会让
    /// `Chart` 那个 `@ChartContentBuilder` 表达式复杂到编译器报
    /// "unable to type-check in reasonable time"。
    ///
    /// 不能 `position(by:)`（会画歪）。`.ratio`/`.fixed` 是给分类轴（band
    /// scale）用的；x 轴这里是连续的时间轴，`.ratio` 算出来的"步长"没有
    /// 良定义，实测柱子直接消失。聚合图（`bucketSecondsOverride` 不为 nil）
    /// 改用 `xStart`/`xEnd` 显式给出这根柱子在时间轴上该占的区间——单位就是
    /// "秒"，不依赖 Swift Charts 怎么猜连续轴上的类目宽度，稳定可控；纵向用
    /// `yStart`/`yEnd`（来自 `Sample.stackStart`/`stackEnd`）显式堆叠——同轴时
    /// 上传接在下载顶部形成一根柱子，镜像时两个方向各画到零轴自己一侧，两种
    /// 场景都不依赖 Swift Charts 对"同 x 同色"该不该堆叠的默认判断。
    /// `DetailWindow` 保持原来的单点 `x`/`y` 写法不变（现有测试基于这个）。
    @ChartContentBuilder
    private func barMark(for s: Sample) -> some ChartContent {
        if let bucketSecondsOverride {
            let inset = bucketSecondsOverride * 0.075   // 两侧各留 7.5%，柱宽占 85%
            let barStart: Date = s.date.addingTimeInterval(inset)
            let barEnd: Date = s.date.addingTimeInterval(bucketSecondsOverride - inset)
            let yLow: Double = s.stackStart
            let yHigh: Double = s.stackEnd
            // 四个坐标（xStart/xEnd/yStart/yEnd）全给定的矩形，`BarMark` 没有
            // 这个签名（它只接受"一段范围 + 一个点"，不是两段范围）——
            // `RectangleMark` 才是画完整矩形的 mark，用法和上面 `coverageGaps`
            // 的灰带一致。
            RectangleMark(xStart: .value(L("chart.axis.time"), barStart),
                          xEnd: .value(L("chart.axis.time"), barEnd),
                          yStart: .value(L("chart.axis.rate"), yLow),
                          yEnd: .value(L("chart.axis.rate"), yHigh))
                .foregroundStyle(by: .value(L("chart.series"), s.direction))
                // 用透明度而不是换一套灰色调色板来"调暗"：换调色板得往
                // `chartForegroundStyleScale` 里塞额外的取值，那些取值会被
                // Swift Charts 当成独立的图例项，在图例里多出两个不该让用户
                // 看到的 "xxx.dimmed" 条目。`ChartContent.opacity(_:)`
                // 不影响取值本身，也就不影响图例。
                .opacity(isDimmed(s) ? 0.35 : 1)
                .cornerRadius(2)
        } else {
            BarMark(x: .value(L("chart.axis.time"), s.date), y: .value(L("chart.axis.rate"), s.rate))
                .foregroundStyle(by: .value(L("chart.series"), s.direction))
                .opacity(isDimmed(s) ? 0.35 : 1)
                .cornerRadius(2)
        }
    }

    /// 孤点（这一段只有它自己）画个小圆点；成段的点不画，免得密数据糊成一片。
    ///
    /// 自定义符号**不会**继承 mark 的 `foregroundStyle`，得自己上色 ——
    /// 否则会落回系统强调色（蓝），上传方向的孤点会跟着变蓝。
    @ViewBuilder
    private func isolatedSymbol(_ sample: Sample) -> some View {
        if sample.isIsolated {
            Circle()
                .fill(seriesColor(sample.direction))
                .frame(width: 5, height: 5)
        }
    }

    /// 系列色只在两处用：样式表与孤点符号。两处必须一致。
    private func seriesColor(_ direction: String) -> Color {
        direction == L("chart.series.upload") ? .red : .blue
    }

    /// 有柱子被点击选中时，其它柱子要调暗——选中的那根保持原色醒目，
    /// 没选中的降低透明度。
    private func isDimmed(_ sample: Sample) -> Bool {
        guard let selectedBucket else { return false }
        return sample.date != Date(timeIntervalSince1970: selectedBucket.timestamp)
    }

    private func tooltip(for point: TimelinePoint) -> some View {
        let start = Date(timeIntervalSince1970: point.timestamp)
        // 天级分桶：一个点就是一整天，标题只给这一天的日期（本地日历日，
        // 显式 `.current` 时区——ISO8601FormatStyle 默认时区是 GMT，直接用
        // 默认值会在东八区之类的地方把日期错位掉一天，这正是这份代码里
        // 修过好几次的那类 bug）。小时级分桶（Today/Yesterday 点一个小时）
        // 仍然给这一小时的起止时刻——这个标题格式的区分和下面均速/峰值
        // 要不要显示是两件独立的事，后者按 `bucketSecondsOverride` 判断。
        let isDayBucket = bucket >= 86_400
        return VStack(alignment: .leading, spacing: 3) {
            if isDayBucket {
                Text(start.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day()))
                    .font(.system(size: 11, weight: .semibold))
            } else {
                let stamp: Date.FormatStyle = range <= 86_400
                    ? .dateTime.hour().minute()
                    : .dateTime.month(.defaultDigits).day().hour().minute()
                let end = start.addingTimeInterval(bucket)
                // 「03:00–04:00」：一个点代表的是一整段桶，不是瞬时采样，标题给
                // 完整的起止时刻而不是"起点 + 时长"，读的时候不用心算加法。
                Text("\(start.formatted(stamp))–\(end.formatted(stamp))")
                    .font(.system(size: 11, weight: .semibold))
            }
            if point.isCovered {
                // 聚合卡片（`bucketSecondsOverride != nil`，Today/Yesterday/
                // Last 7 days 等仪表盘顶层预设共用同一份提示气泡）不管桶多粗
                // 都只显示总量，跟 Last 7 days 那份保持同样的字段；均速/峰值
                // 只保留给 `DetailWindow` 自己的单进程图（`bucketSecondsOverride
                // == nil`），那边桶最粗也就是 1 小时，均速/峰值仍然有意义。
                let showRate = bucketSecondsOverride == nil
                HStack(spacing: 10) {
                    legend(.blue, "↓", average: Double(point.bytesIn) / bucket,
                           peak: point.peakIn, bytes: point.bytesIn, showRate: showRate)
                    legend(.red, "↑", average: Double(point.bytesOut) / bucket,
                           peak: point.peakOut, bytes: point.bytesOut, showRate: showRate)
                }
            } else {
                Text(L("detail.noCoverage"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        // 固定白色不透明背景（用户要求），不再跟系统深浅色走。同时把这块
        // 子树的 colorScheme 钉死成 .light——.primary/.secondary 这些动态色
        // 是按系统当前深浅色取值的，深色模式下它们会解析成"适合深色背景"
        // 的浅色，直接叠在固定白底上会看不清；钉死 .light 后它们照常解析成
        // "适合浅色背景"的深色，不用挨个 Text 手动换色。
        .environment(\.colorScheme, .light)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white))
        .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
        .allowsHitTesting(false)
    }

    /// 这一桶的总量放最显眼的位置——"这一小时下载/上传了多少"问的是总量，
    /// 不是均速；均速和峰值退到更小的次要行。`showRate == false`（仪表盘
    /// 顶层聚合卡片）干脆不显示这两行——跟 Last 7 days 保持同样的字段。
    private func legend(_ color: Color, _ arrow: String,
                        average: Double, peak: Double, bytes: Int64,
                        showRate: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(arrow) \(ByteFormatter.string(bytes: bytes))")
                .font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(color)
            if showRate {
                Text(ByteFormatter.rateString(bytesPerSecond: average))
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                if peak > average * 1.05 {
                    Text("\(L("detail.peakShort")) \(ByteFormatter.rateString(bytesPerSecond: peak))")
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(color.opacity(0.75))
                }
            }
        }
    }
}
