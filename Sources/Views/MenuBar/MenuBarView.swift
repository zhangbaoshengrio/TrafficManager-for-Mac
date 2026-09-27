import AppKit
import SwiftUI

// MARK: - 菜单栏标签

/// 菜单栏上常驻显示的上下行速率，上行在上、下行在下。
///
/// 这里给的是一张**自己画好的 NSImage**，而不是 SwiftUI 视图。
/// 原因见 `MenuBarRateImage` 的说明：SwiftUI 会把 label 栅格化并把高度压到
/// 16pt，两行文字放不下，只会显示一行。
@MainActor
struct MenuBarLabel: View {
    @Environment(DashboardViewModel.self) private var dashboard
    @Environment(CollectorService.self) private var collector

    var body: some View {
        Image(nsImage: MenuBarRateImage.render(
            upBytesPerSecond: dashboard.totalTxRate,
            downBytesPerSecond: dashboard.totalRxRate,
            fontSize: collector.menuBarFontSize
        ))
    }
}

// MARK: - 菜单栏面板

@MainActor
struct MenuBarPanel: View {
    @Environment(DashboardViewModel.self) private var dashboard
    @Environment(CollectorService.self) private var collector
    @Environment(\.openWindow) private var openWindow

    /// 面板里最多列几个进程。再多就该开主窗口了。
    static let rowCapacity = MenuBarRowLedger.capacity
    /// 单行高度。写死而不是让内容撑开 —— 图标、进程名、速率三者的固有高度
    /// 未必一致（换了图标或字体就会变），交给内容决定的话行距会参差不齐。
    static let rowHeight: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            actions
            Divider().padding(.vertical, 6)
            totals
            Divider().padding(.vertical, 6)
            processList
        }
        .padding(10)
        .frame(width: 280)
    }

    // MARK: - 进程列表

    /// 行由 `MenuBarRowLedger` 供给：已经过平滑排序与驻留，成员和顺序都不逐帧变。
    ///
    /// 这一点决定了这里可以让列表**随内容自由增长**而不引发抖动 ——
    /// 台账在正常使用下会稳定填满 `rowCapacity` 个槽位，高度自然不动，
    /// 不需要靠预留空行去凑（那样进程真的少时会留一大块空白）。
    ///
    /// 位置上它仍然放在面板**最底部**：菜单栏面板顶边固定、底边浮动，
    /// 万一列表真的伸缩了，上方按钮的屏幕位置也不会受影响。
    private var processList: some View {
        VStack(spacing: 0) {
            if dashboard.menuBarRows.isEmpty {
                Text(L("menubar.noActivity"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.rowHeight)
            } else {
                ForEach(dashboard.menuBarRows) { processRow($0) }
            }
        }
    }

    private func processRow(_ item: MenuBarRow) -> some View {
        HStack(spacing: 6) {
            ProcessIcon(row: item.row, size: 14)
            Text(item.row.displayName).font(.system(size: 11)).lineLimit(1)
            Spacer(minLength: 6)
            compactRate(item.row.rxRate, .blue)
            compactRate(item.row.txRate, .red)
        }
        .font(.system(size: 10, design: .monospaced))
        .frame(height: Self.rowHeight)
        // 驻留中（此刻没流量）的行淡一档，免得被误读成「正在跑」
        .opacity(item.isIdle ? 0.45 : 1)
    }

    /// 进程行的速率：数字右对齐、单位列紧随其后左对齐。
    /// 两列各占死宽度，所以 `K` / `M` 永远停在同一个 x 上。
    private func compactRate(_ bytesPerSecond: Double, _ color: Color) -> some View {
        valuePair(ByteFormatter.compactRateParts(bytesPerSecond: bytesPerSecond),
                  slot: MetricSlot.slot(.compactRate))
            .foregroundStyle(color)
    }

    // MARK: - 汇总

    /// 三个指标各占一份等宽槽位，标题居中、数值固定位置。见 `MetricSlot`。
    private var totals: some View {
        HStack(spacing: 0) {
            metric(L("summary.downloadRate"),
                   ByteFormatter.rateParts(bytesPerSecond: dashboard.totalRxRate),
                   .blue, .rate)
            metricDivider
            metric(L("summary.uploadRate"),
                   ByteFormatter.rateParts(bytesPerSecond: dashboard.totalTxRate),
                   .red, .rate)
            metricDivider
            metric(dashboard.selectedTimeRange.displayName,
                   ByteFormatter.parts(bytes: dashboard.totalTraffic),
                   .primary, .total)
        }
    }

    private var metricDivider: some View {
        Divider().frame(height: 26).padding(.horizontal, MetricSlot.dividerPadding)
    }

    /// 标题**居中**压在数值上方；数值本身是「右对齐的数字 + 左对齐的单位」。
    ///
    /// 标题居中而不是左对齐，是因为数值组本身居中，标题跟着居中两者才成一竖列；
    /// 左对齐会让短标题和数值组的视觉中心错开。
    private func metric(_ label: String, _ parts: ByteFormatter.Parts,
                        _ color: Color, _ kind: MetricSlot.Kind) -> some View {
        let slot = MetricSlot.slot(kind)
        return VStack(spacing: 1) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            valuePair(parts, slot: slot)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(color)
        }
        // 极端数值宁可缩一点也不要把分隔线推走
        .lineLimit(1)
        // 三份等分铺满面板宽度。面板宽度是写死的 280，所以「等分」也是定值 ——
        // 槽位不会因为内容变化而改变，数值组在其中居中，位置同样固定。
        .frame(minWidth: slot.width, maxWidth: .infinity)
    }

    /// 数字列右对齐 + 单位列左对齐 —— 让单位的左边缘钉死在一个 x 上。
    ///
    /// 若把 `"120.6 KB/s"` 整串交给一个 `Text`：左对齐时数字一变长，
    /// 后面的 `KB/s` 就整体右移；右对齐时改成数字跟着单位一起左移。
    /// 无论哪种，每秒都有东西在横向跳。拆成两列各自定宽就都不动了。
    private func valuePair(_ parts: ByteFormatter.Parts,
                           slot: MetricSlot.Slot) -> some View {
        HStack(spacing: slot.gap) {
            Text(parts.value)
                .monospacedDigit()
                .frame(width: slot.value, alignment: .trailing)
            Text(parts.unit)
                .frame(width: slot.unit, alignment: .leading)
        }
    }

    // MARK: - 操作

    /// 顶部一行紧凑工具栏。
    ///
    /// 三个考虑：
    /// - **位置必须固定**：面板从菜单栏往下挂，顶边固定、底边浮动。
    ///   放在最顶部意味着它的屏幕位置只由面板顶边决定，与下方任何内容无关。
    /// - **不割裂数据**：夹在总计和进程列表中间会把两块数据切开；
    ///   放到最上面，总计与列表就连成一整块。
    /// - **不该喧宾夺主**：开窗口、启停、退出都是低频操作，占三行整宽菜单
    ///   会把真正常看的进程列表挤出视线。压成一行图标 + 短标签即可。
    ///   「退出」单独靠右，与另两个拉开距离，降低误点。
    private var actions: some View {
        HStack(spacing: 4) {
            actionButton(L("menubar.window"), "macwindow") {
                // 无窗口时应用处于菜单栏模式（没有 Dock 图标），
                // 先把 Dock 图标升回来再显示窗口
                DockIconController.shared.restoreDockIcon()
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.contentView != nil }) {
                    window.makeKeyAndOrderFront(nil)
                } else {
                    openWindow(id: MainWindowID.value)
                }
            }
            actionButton(collector.status == .running ? L("toolbar.stop") : L("toolbar.start"),
                         collector.status == .running ? "stop.fill" : "play.fill") {
                if collector.status == .running { collector.stop() }
                else { Task { await collector.start() } }
            }
            Spacer(minLength: 0)
            actionButton(L("menubar.quitShort"), "power") { NSApp.terminate(nil) }
        }
    }

    private func actionButton(_ title: String, _ symbol: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10))
                Text(title).font(.system(size: 11))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(HoverHighlightButtonStyle())
    }
}


// MARK: - 数值槽位

/// 面板里每个数值占的位置。
///
/// 数值每秒都在变，字符串长度也跟着变（`0 B/s` ↔ `120.6 KB/s`）。
/// 若让内容决定宽度，分隔线和右侧指标就会左右横跳；就算固定住槽位总宽，
/// 单位也会因为数字变长而在槽位内部滑动。所以**数字列和单位列分开定宽**。
///
/// 与菜单栏图片同样的做法：不手写模板串，直接把一组覆盖各数量级的值喂进
/// **真正的格式化器**量出最大宽度 —— 格式规则将来变了，宽度会自动跟上。
///
/// 按语言缓存：标题是本地化的，换语言后宽度需要重算。
enum MetricSlot {
    /// 指标之间分隔线两侧的留白
    static let dividerPadding: CGFloat = 8

    struct Slot: Equatable {
        /// 数字列宽（内容右对齐）
        let value: CGFloat
        /// 单位列宽（内容左对齐）
        let unit: CGFloat
        /// 数字列与单位列之间的间隙
        let gap: CGFloat
        /// 连标题一起算的槽位最小宽度
        let width: CGFloat

        /// 数字 + 间隙 + 单位
        var pair: CGFloat { value + gap + unit }
    }

    enum Kind: String {
        /// 顶部的下载 / 上传速率
        case rate
        /// 顶部的时间窗总量
        case total
        /// 进程行里的单字母单位速率
        case compactRate
    }

    static func slot(_ kind: Kind) -> Slot {
        let key = "\(L10n.effective)-\(kind.rawValue)"
        if let cached = cache[key] { return cached }
        let measured = measure(kind)
        cache[key] = measured
        return measured
    }

    /// 三个槽位加两条分隔线的总宽，用来核对能否放进面板
    static var totalRowWidth: CGFloat {
        slot(.rate).width * 2 + slot(.total).width + (dividerPadding * 2 + 1) * 2
    }

    nonisolated(unsafe) private static var cache: [String: Slot] = [:]

    private static func measure(_ kind: Kind) -> Slot {
        let valueFont: NSFont = switch kind {
        case .rate, .total: .monospacedSystemFont(ofSize: 12, weight: .medium)
        case .compactRate:  .monospacedSystemFont(ofSize: 10, weight: .regular)
        }
        let labelFont = NSFont.systemFont(ofSize: 9)
        func width(_ text: String, _ font: NSFont) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: font]).width
        }

        var value: CGFloat = 0, unit: CGFloat = 0
        // 速率封顶到 GB/s 量级：再往上（TB/s）现实中不会出现，
        // 为它预留宽度只会白白挤掉别的内容。总量则要留到 TB。
        let exponents = kind == .total ? 0...4 : 0...3
        for exponent in exponents {
            for multiplier in [1.0, 9.9, 10.0, 99.0, 999.9] {
                let sample = multiplier * pow(1024, Double(exponent))
                let parts = switch kind {
                case .rate:        ByteFormatter.rateParts(bytesPerSecond: sample)
                case .total:       ByteFormatter.parts(bytes: Int64(sample))
                case .compactRate: ByteFormatter.compactRateParts(bytesPerSecond: sample)
                }
                value = max(value, width(parts.value, valueFont))
                unit = max(unit, width(parts.unit, valueFont))
            }
        }
        value = ceil(value)
        unit = ceil(unit)
        // 「13.6 KB/s」里那个空格是词与词之间的停顿，该有；
        // 「8.2 K」里若也留同样的空隙，单个字母会被读成另一个词。压窄一点。
        let gap: CGFloat = kind == .compactRate ? 1.5 : 3

        let labels: [String] = switch kind {
        case .rate:        [L("summary.downloadRate"), L("summary.uploadRate")]
        case .total:       DashboardViewModel.TimeRange.allCases.map(\.displayName)
        case .compactRate: []      // 进程行的速率列没有标题
        }
        let widest = labels.reduce(value + gap + unit) { max($0, ceil(width($1, labelFont))) }

        return Slot(value: value, unit: unit, gap: gap, width: widest)
    }
}

/// 悬停时给一层浅背景，让这些无边框按钮有可点的提示。
///
/// `@State` 必须放在一个真正的 `View` 里，不能直接放在 `ButtonStyle` 上 ——
/// 样式结构体不是视图，面板每秒重新求值时它会被整个重建，悬停状态跟着丢，
/// 高亮就会一闪一闪。
private struct HoverHighlightButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Highlight(configuration: configuration)
    }

    private struct Highlight: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.16 : (hovering ? 0.08 : 0)))
                )
                .onHover { hovering = $0 }
        }
    }
}

/// 主窗口的 scene id，菜单栏面板要用它把窗口叫回来
enum MainWindowID {
    static let value = "main"
}
