import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 主窗口：NavigationSplitView 三栏布局
///
/// 拆分原则：**每个子视图只读它真正需要的属性**。
/// `@Observable` 按属性追踪依赖，因此速率每秒变化只会让 `SummaryRow` 失效，
/// 表格行变化只会让 `ProcessTableView` 失效，外层的 NavigationSplitView /
/// 侧栏 / 工具栏都不会重新求值 —— 也就不会再触发那条 30 层深的
/// `-[NSView _layoutSubtreeWithOldSize:]` 递归。
@MainActor
struct MainWindowView: View {
    @Environment(CollectorService.self) private var collector
    @Environment(DashboardViewModel.self) private var dashboard

    @State private var selectedProcessKey: String?
    @State private var detailTarget: ProcessRow?
    @State private var exportDocument: CSVDocument?
    @State private var selectedHistoricalRange: ClosedRange<TimeInterval>?
    /// 顶层聚合图实际用的桶大小，由 `AggregateTrafficCard.onBucketSecondsChange`
    /// 回报——双击一天时用它判断"当前是不是按天分桶"，不是按天分桶（比如
    /// Today/Yesterday 本身就是单独一天）时双击直接忽略。默认 `3_600`
    /// （跟 `AggregateChartViewModel` 数据到达前的兜底值一致）。
    @State private var dayBucketSeconds: TimeInterval = 3_600
    /// Custom 日期弹窗的显示状态——选中 Custom 时自动弹出一次，之后可以
    /// 通过工具条上只在选中 Custom 时才出现的日历图标按钮再次打开。
    @State private var showingCustomRangePopover = false
    /// 双击一天跳到 Custom 时，日期已经由代码直接算好并设好了，不需要用户
    /// 再确认一遍——但切到 `.custom` 这件事跟"手动从下拉菜单里选 Custom"
    /// 走的是同一个 `selectedTimeRange` 赋值，`.onChange` 那边没法区分这两种
    /// 情况。这个标志在双击那条路径里赋值前先置位，`.onChange` 读到就跳过
    /// 自动弹窗（消费一次就复位）；手动选 Custom 不会经过这条路径，标志
    /// 始终是 false，弹窗行为不变。
    @State private var suppressNextCustomPopover = false
    /// 双击跳到 Custom 之前那一刻的预设/日期，供工具条上的 "Clear filter"
    /// 按钮把用户带回去——`nil` 表示"当前不是从双击跳过来的"，工具条上不
    /// 显示这个按钮。手动从下拉菜单选任何预设（哪怕又选回 Custom）都会
    /// 清空它：那是一次新的手动操作，不再有"回退目标"这回事。
    @State private var beforeDoubleClickJump: (range: DashboardViewModel.TimeRange, customStart: Date, customEnd: Date)?

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

    var body: some View {
        VStack(spacing: 0) {
            SummaryRow().padding(.horizontal).padding(.top, 12)
            Divider().padding(.top, 12)
            AggregateTrafficCard(
                since: dashboard.selectedTimeRange.resolvedInterval(
                    customStart: dashboard.customRangeStart, customEnd: dashboard.customRangeEnd
                ).start.timeIntervalSince1970,
                until: dashboard.selectedTimeRange.resolvedInterval(
                    customStart: dashboard.customRangeStart, customEnd: dashboard.customRangeEnd
                ).end.timeIntervalSince1970,
                selectedRange: selectedHistoricalRange,
                onSelectRange: { selectedHistoricalRange = $0 },
                onBucketSecondsChange: { dayBucketSeconds = $0 },
                onDoubleSelectDay: { point in
                    // 只在顶层图已经是按天分桶时才有意义——Today/Yesterday
                    // 本身就是单独一天，双击一根小时柱切到"Custom 定位到
                    // 今天"没有意义，直接忽略。
                    guard dayBucketSeconds >= 86_400 else { return }
                    let dayStart = Date(timeIntervalSince1970: point.timestamp)
                    let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
                    beforeDoubleClickJump = (dashboard.selectedTimeRange,
                                             dashboard.customRangeStart, dashboard.customRangeEnd)
                    dashboard.customRangeStart = dayStart
                    dashboard.customRangeEnd = dayEnd
                    suppressNextCustomPopover = true
                    dashboard.selectedTimeRange = .custom
                }
            )
            .padding(.horizontal).padding(.top, 12)
            Divider().padding(.top, 12)
            if let dayRange = selectedHistoricalRange {
                selectionBanner(dayRange, onClear: { selectedHistoricalRange = nil })
            }
            ContentTable(selection: $selectedProcessKey, onOpenDetail: { detailTarget = $0 },
                        historicalRange: selectedHistoricalRange)
        }
        .onChange(of: dashboard.selectedTimeRange) { _, newValue in
            selectedHistoricalRange = nil
            guard newValue == .custom else { return }
            if suppressNextCustomPopover {
                suppressNextCustomPopover = false
            } else {
                showingCustomRangePopover = true
            }
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

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            // 用 `Menu` 而不是 `Picker(...).pickerStyle(.menu)`：后者在 AppKit 里是
            // "pop-up" 语义（NSPopUpButton，`pullsDown == false`）——弹出时会把
            // *当前选中项* 对齐到按钮位置，选中项之前的选项被挤到按钮上方。窗口
            // 靠近屏幕顶部、选中的又是列表靠后的项（比如 Last 30 days）时，上方
            // 空间不够，AppKit 会把前面几项收进一个只能靠悬停滚动才能看到的
            // 折叠区——用户报过这个问题：选到 Last 30 days 后点开菜单，Today/
            // Yesterday/Last 7 days 都被折叠掉了。`Menu` 对应的是"pull-down"
            // 语义，永远从按钮正下方、列表第一项开始铺开，不会为了对齐选中项而
            // 把前面的项目推到不可见的地方；代价是没有原生的选中态圆点/勾号，
            // 这里手动加一个 checkmark 补上。
            Menu {
                ForEach(DashboardViewModel.TimeRange.allCases) { range in
                    Button {
                        // 手动选预设是一次新的操作，不再是"双击跳过来的"状态——
                        // 清掉回退目标，工具条上的 Clear filter 按钮跟着消失。
                        beforeDoubleClickJump = nil
                        dashboard.selectedTimeRange = range
                    } label: {
                        if range == dashboard.selectedTimeRange {
                            Label(range.displayName, systemImage: "checkmark")
                        } else {
                            Text(range.displayName)
                        }
                    }
                }
            } label: {
                Text(toolbarTimeRangeLabel)
            }
            .help(L("toolbar.timeRange"))

            if dashboard.selectedTimeRange == .custom {
                Button { showingCustomRangePopover = true } label: {
                    Image(systemName: "calendar")
                }
                .help(L("toolbar.customRange.edit"))
                .popover(isPresented: $showingCustomRangePopover) {
                    customRangePopover
                }
            }

            // 只有"双击一天跳到 Custom"这条路径会设置 `beforeDoubleClickJump`，
            // 所以这个按钮只在那之后出现；点一下把用户带回跳转前的预设/日期。
            if let target = beforeDoubleClickJump {
                Button(L("toolbar.clearFilter")) {
                    dashboard.customRangeStart = target.customStart
                    dashboard.customRangeEnd = target.customEnd
                    beforeDoubleClickJump = nil
                    dashboard.selectedTimeRange = target.range
                }
                .buttonStyle(.link)
            }
        }

        ToolbarItemGroup {
            HStack(spacing: 4) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(statusLabel).font(.caption)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(statusColor.opacity(0.12))
            .clipShape(Capsule())

            if collector.status == .running {
                Button { collector.stop() } label: {
                    Label(L("toolbar.stop"), systemImage: "stop.fill")
                }.help(L("toolbar.stop.help"))
            } else {
                Button { Task { await collector.start() } } label: {
                    Label(L("toolbar.start"), systemImage: "play.fill")
                }
                .help(L("toolbar.start.help"))
                .keyboardShortcut(.return, modifiers: [])
            }

            Spacer()

            searchField

            Toggle(isOn: Bindable(dashboard).isGroupedView) {
                Image(systemName: "square.grid.2x2")
            }
            .toggleStyle(.button)
            .disabled(dashboard.processGroups.isEmpty)
            .help(L("toolbar.groupedView"))

            Button { exportDocument = CSVDocument(rows: dashboard.rows) } label: {
                Label(L("toolbar.export"), systemImage: "square.and.arrow.up")
            }.help(L("toolbar.export.help"))
        }
    }

    /// 工具栏按钮收起时显示的文字。选中 Custom 时不显示"Custom"这个通用
    /// 名字——不打开弹窗就不知道具体是哪几天，改成直接显示日期范围本身
    /// （如"09/20-09/27"，单日则首尾相同，如"09/27-09/27"）。其余 6 个
    /// 预设不受影响，继续显示各自的名字。
    private var toolbarTimeRangeLabel: String {
        guard dashboard.selectedTimeRange == .custom else { return dashboard.selectedTimeRange.displayName }
        // `customRangeEnd` 是排他终点（"这天不算"），换算成用户心里"最后一天"
        // 的写法要往前退一天——跟 `customRangePopover` 里"To" 那个 DatePicker
        // 的转换是同一套逻辑，两处必须一致。
        let lastInclusiveDay = Calendar.current.date(
            byAdding: .day, value: -1, to: dashboard.customRangeEnd
        ) ?? dashboard.customRangeEnd
        return "\(Self.shortDate(dashboard.customRangeStart))-\(Self.shortDate(lastInclusiveDay))"
    }

    /// "MM/DD" 格式，手动拼而不是用 `Date.FormatStyle`——后者的月/日先后顺序
    /// 跟着系统地区设置走，会在某些地区把"09/27"倒过来变成"27/09"，跟用户
    /// 明确要的这个固定格式对不上。
    private static func shortDate(_ date: Date) -> String {
        let comps = Calendar.current.dateComponents([.month, .day], from: date)
        return String(format: "%02d/%02d", comps.month ?? 0, comps.day ?? 0)
    }

    private var customRangePopover: some View {
        // 参考图（DeepSeek 平台的用量筛选面板）用的是双月联动网格：起点终点
        // 都在同一块日历上点，中间的日子整段高亮——比分开两个单月日历直观
        // 得多，这里用 `MonthRangeCalendar`（`Views/Components/`）实现，不是
        // SwiftUI 自带控件。
        VStack(alignment: .leading, spacing: 10) {
            Text(L("range.custom")).font(.headline)

            // `customRangeEnd`（模型层）是排他终点（"这天不算"，跟项目里
            // 所有其它区间同一套约定），但日历面向用户，用户心里的终点是
            // "包含这天"——两者相差一天，这里用一个 Binding 做转换，不影响
            // `customRangeEnd` 自己的存储语义。
            MonthRangeCalendar(
                start: Bindable(dashboard).customRangeStart,
                end: Binding(
                    get: {
                        Calendar.current.date(byAdding: .day, value: -1, to: dashboard.customRangeEnd)
                            ?? dashboard.customRangeEnd
                    },
                    set: { newInclusiveDay in
                        let start = Calendar.current.startOfDay(for: newInclusiveDay)
                        dashboard.customRangeEnd = Calendar.current.date(byAdding: .day, value: 1, to: start)
                            ?? newInclusiveDay
                    }
                )
            )

            Button(L("customRange.done")) { showingCustomRangePopover = false }
                .keyboardShortcut(.defaultAction)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(14)
        .frame(width: 480)
    }

    /// 自己拼一个搜索框，而不是用 `.searchable(placement: .toolbar)`。
    ///
    /// 后者会插入 `NSSearchToolbarItemView`，而它的 `updateConstraints` 内部又去调
    /// `animateToolbarUpdates → layoutSubtreeIfNeeded`，在约束更新过程中重入布局，
    /// AppKit 会打印
    /// "It's not legal to call -layoutSubtreeIfNeeded on a view which is already being laid out"。
    /// 用栈定位到 `-[NSSearchToolbarItemView _updateMinWidthConstraints:]` 后换成普通 TextField。
    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            TextField(L("toolbar.search"), text: Bindable(dashboard).searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(width: 130)
            if !dashboard.searchText.isEmpty {
                Button { dashboard.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.6)))
        .frame(width: 190, alignment: .leading)
    }

    private var statusColor: Color {
        switch collector.status {
        case .idle, .stopped: .gray
        case .running: .green
        case .error: .red
        }
    }

    private var statusLabel: String {
        switch collector.status {
        case .idle: L("toolbar.status.idle")
        case .running: L("toolbar.status.running")
        case .stopped: L("toolbar.status.stopped")
        case .error(let msg): msg
        }
    }
}

// MARK: - 汇总卡片（每秒更新，只有这三张卡失效）

@MainActor
private struct SummaryRow: View {
    @Environment(DashboardViewModel.self) private var dashboard

    var body: some View {
        HStack(spacing: 12) {
            SummaryCard(title: L("summary.totalDownloaded"),
                        value: ByteFormatter.string(bytes: dashboard.totalDownloaded),
                        icon: "arrow.down")
            SummaryCard(title: L("summary.totalUploaded"),
                        value: ByteFormatter.string(bytes: dashboard.totalUploaded),
                        icon: "arrow.up")
            SummaryCard(title: L("summary.rangeTraffic", dashboard.selectedTimeRange.displayName),
                        value: ByteFormatter.string(bytes: dashboard.totalTraffic),
                        icon: "chart.bar")
        }
    }
}

// MARK: - 表格容器（只读 isGroupedView）

@MainActor
private struct ContentTable: View {
    @Environment(DashboardViewModel.self) private var dashboard
    @Environment(CollectorService.self) private var collector
    @Binding var selection: String?
    let onOpenDetail: (ProcessRow) -> Void
    let historicalRange: ClosedRange<TimeInterval>?

    /// 关闭时把列宽和标题都压成空，让这一列实际上消失。
    ///
    /// 本来该用 `@TableColumnBuilder` 的条件列直接不声明它，但 `buildIf`
    /// 要求 macOS 14.4+，而本项目部署目标是 14.0 —— 为一个装饰性的列抬高
    /// 系统要求不划算。
    private var sparklineWidth: CGFloat { collector.sparklineEnabled ? 70 : 0 }

    var body: some View {
        if let historicalRange {
            HistoricalSummaryTable(since: historicalRange.lowerBound, until: historicalRange.upperBound)
        } else if dashboard.isGroupedView {
            GroupTableView()
        } else {
            ProcessTableView(selection: $selection, onOpenDetail: onOpenDetail)
        }
    }
}

// MARK: - 进程表

@MainActor
private struct ProcessTableView: View {
    @Environment(DashboardViewModel.self) private var dashboard
    @Environment(CollectorService.self) private var collector
    @Binding var selection: String?
    let onOpenDetail: (ProcessRow) -> Void

    /// 关闭时把列宽和标题都压成空，让这一列实际上消失。
    ///
    /// 本来该用 `@TableColumnBuilder` 的条件列直接不声明它，但 `buildIf`
    /// 要求 macOS 14.4+，而本项目部署目标是 14.0 —— 为一个装饰性的列抬高
    /// 系统要求不划算。
    private var sparklineWidth: CGFloat { collector.sparklineEnabled ? 70 : 0 }

    var body: some View {
        @Bindable var dashboard = dashboard
        if dashboard.rows.isEmpty {
            EmptyStateView()
        } else {
            Table(dashboard.rows, selection: $selection, sortOrder: $dashboard.sortOrder) {
                TableColumn(L("column.process"), value: \.displayName) { row in
                    HStack(spacing: 6) {
                        ProcessIcon(row: row)
                        Text(row.displayName).lineLimit(1)
                    }
                }
                .width(min: 140)

                TableColumn(L("column.liveDownload"), value: \.rxRate) { row in
                    Text(ByteFormatter.rateString(bytesPerSecond: row.rxRate))
                        .font(.system(size: 12))
                        .foregroundColor(row.rxRate > 0 ? .blue : .secondary)
                        .monospacedDigit()
                }
                .width(min: 85)

                TableColumn(L("column.liveUpload"), value: \.txRate) { row in
                    Text(ByteFormatter.rateString(bytesPerSecond: row.txRate))
                        .font(.system(size: 12))
                        .foregroundColor(row.txRate > 0 ? .red : .secondary)
                        .monospacedDigit()
                }
                .width(min: 85)

                TableColumn(L("column.download"), value: \.totalIn) { row in
                    Text(ByteFormatter.string(bytes: row.totalIn))
                        .foregroundColor(.blue).monospacedDigit()
                }
                .width(min: 75)

                TableColumn(L("column.upload"), value: \.totalOut) { row in
                    Text(ByteFormatter.string(bytes: row.totalOut))
                        .foregroundColor(.red).monospacedDigit()
                }
                .width(min: 75)

                TableColumn(L("column.total"), value: \.totalBytes) { row in
                    Text(ByteFormatter.string(bytes: row.totalBytes))
                        .fontWeight(.medium).monospacedDigit()
                }
                .width(min: 90)

                TableColumn(collector.sparklineEnabled ? L("column.trend") : "") { row in
                    if collector.sparklineEnabled {
                        Sparkline(values: row.spark)
                    }
                }
                .width(min: 0, ideal: sparklineWidth, max: sparklineWidth)
            }
            // primaryAction 即双击。此前是「单击即弹模态框」，导致想排序或选行
            // 都会被详情窗打断。
            .contextMenu(forSelectionType: ProcessRow.ID.self) { keys in
                if let row = row(for: keys) { menu(for: row) }
            } primaryAction: { keys in
                if let row = row(for: keys) { onOpenDetail(row) }
            }
        }
    }

    private func row(for keys: Set<ProcessRow.ID>) -> ProcessRow? {
        guard let key = keys.first else { return nil }
        return dashboard.rows.first { $0.key == key }
    }

    @ViewBuilder
    private func menu(for row: ProcessRow) -> some View {
        Button(L("menu.viewTimeline")) { onOpenDetail(row) }
        Divider()
        Button(L("menu.copyName")) { copy(row.displayName) }
        if let bundleId = row.bundleId {
            Button(L("menu.copyBundleID")) { copy(bundleId) }
        }
        if let path = row.iconPath, FileManager.default.fileExists(atPath: path) {
            Divider()
            Button(L("menu.revealInFinder")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - 分组表

@MainActor
private struct GroupTableView: View {
    @Environment(DashboardViewModel.self) private var dashboard

    var body: some View {
        if dashboard.groupRows.isEmpty {
            EmptyStateView()
        } else {
            Table(dashboard.groupRows) {
                TableColumn(L("column.group")) { row in
                    HStack(spacing: 6) {
                        Image(systemName: row.isOthers ? "tray" : "folder")
                            .frame(width: 18).foregroundColor(.accentColor)
                        Text(row.name).lineLimit(1)
                    }
                }.width(min: 140)

                TableColumn(L("column.liveDownload")) { row in
                    Text(ByteFormatter.rateString(bytesPerSecond: row.rxRate))
                        .font(.system(size: 12))
                        .foregroundColor(row.rxRate > 0 ? .blue : .secondary).monospacedDigit()
                }.width(min: 85)

                TableColumn(L("column.liveUpload")) { row in
                    Text(ByteFormatter.rateString(bytesPerSecond: row.txRate))
                        .font(.system(size: 12))
                        .foregroundColor(row.txRate > 0 ? .red : .secondary).monospacedDigit()
                }.width(min: 85)

                TableColumn(L("column.download")) { row in
                    Text(ByteFormatter.string(bytes: row.totalIn)).foregroundColor(.blue).monospacedDigit()
                }.width(min: 75)

                TableColumn(L("column.upload")) { row in
                    Text(ByteFormatter.string(bytes: row.totalOut)).foregroundColor(.red).monospacedDigit()
                }.width(min: 75)

                TableColumn(L("column.total")) { row in
                    Text(ByteFormatter.string(bytes: row.totalBytes)).fontWeight(.medium).monospacedDigit()
                }.width(min: 75)

                TableColumn(L("column.memberCount")) { row in
                    Text("\(row.memberCount)").monospacedDigit()
                }.width(min: 50)
            }
        }
    }
}

// MARK: - 空态

@MainActor
private struct EmptyStateView: View {
    @Environment(CollectorService.self) private var collector

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            if collector.status == .running {
                Image(systemName: "network").font(.system(size: 36)).foregroundColor(.secondary)
                Text(L("empty.waiting")).foregroundColor(.secondary)
            } else {
                Image(systemName: "play.circle").font(.system(size: 36)).foregroundColor(.accentColor)
                Text(L("empty.pressToStart")).foregroundColor(.secondary)
                if case .error(let msg) = collector.status {
                    Text(msg).font(.caption).foregroundColor(.red).padding(.top, 4)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - CSV 导出

struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    let csv: String

    init(rows: [ProcessRow]) {
        var lines = [L("csv.header")]
        for r in rows {
            lines.append("\"\(r.displayName)\",\(Int(r.rxRate)),\(Int(r.txRate)),\(r.totalIn),\(r.totalOut),\(r.totalBytes)")
        }
        csv = lines.joined(separator: "\n")
    }

    init(configuration: ReadConfiguration) throws {
        csv = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: csv.data(using: .utf8)!)
    }
}
