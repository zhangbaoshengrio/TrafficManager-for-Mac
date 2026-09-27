# Bytetally Phase 3 Task 2: Hourly Bars + Click-to-Filter Table Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the aggregate chart show bar-only, hourly-bucketed data for short ranges (matching "a day → 24 hourly bars"), and let clicking an hour's bar filter the process table below to that hour's per-app totals — mirroring Bytetally's "Apps in this range — brush the chart to narrow it" behavior.

**Architecture:** `AggregateChartViewModel` gets its own bucket-size rule (hourly for ranges ≤ 1 day) instead of reusing `TimelineBucket.size(for:)` (which stays unchanged for `DetailWindow`'s per-process use). `TrafficChart` gains an optional `onSelectBucket` callback (default `nil`, zero behavior change for `DetailWindow`). `AggregateTrafficCard` drops its style picker (bar-only) and surfaces a selected-range callback. `MainWindowView` owns the selected-range state, shows a clear/banner control, and `ContentTable` swaps to a new read-only `HistoricalSummaryTable` (backed by `DataStore.querySummary`, Phase 1) when a range is selected.

**Tech Stack:** Swift 6.2, SwiftUI, Swift Charts, XCTest.

## Global Constraints

- Swift tools version: 5.9; deployment target macOS 14.
- Do not modify `TimelineBucket.size(for:)` itself — it's shared with `DetailWindow`'s per-process chart, which should keep its existing (finer) bucketing.
- `TrafficChart`'s new `onSelectBucket` parameter must default to `nil` so `DetailWindow`'s existing call site needs no changes.
- Run tests with `cd ~/Documents/traffic-monitoring && swift test --filter <ClassName>/<testMethodName>`.

---

### Task 1: Hourly buckets for the aggregate chart on short ranges

**Files:**
- Modify: `Sources/ViewModels/AggregateChartViewModel.swift`
- Test: `Tests/AggregateChartViewModelTests.swift`

**Interfaces:**
- Produces: a private `AggregateChartViewModel.bucketSeconds(for:) -> TimeInterval` used internally by `load(range:)`. `load`'s public signature is unchanged.

- [ ] **Step 1: Write the failing test**

Add this to `Tests/AggregateChartViewModelTests.swift`:

```swift
    /// Today（≤1 天）范围要按整点分桶，一天正好落成 24 根柱子，跟"按小时看"
    /// 的心智模型对齐；更长范围维持 `TimelineBucket` 原有的粗细规则不变。
    @MainActor
    func testLoadUsesHourlyBucketsForRangesUpToOneDay() async throws {
        await DataStore.shared.resetForTesting()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AggregateChartViewModelTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await DataStore.shared.setup(at: dir.appendingPathComponent("hourly.db"))

        // 同一个小时内两条不同分钟的事件，应该落进同一根柱子
        let hourStart = (Date().timeIntervalSince1970 / 3600).rounded(.down) * 3600
        try await DataStore.shared.insertEvents([
            TrafficEvent(id: nil, timestamp: hourStart + 60, interval: 5,
                         processKey: "a", bundleId: nil, displayName: "a",
                         bytesIn: 1000, bytesOut: 0),
            TrafficEvent(id: nil, timestamp: hourStart + 1800, interval: 5,
                         processKey: "a", bundleId: nil, displayName: "a",
                         bytesIn: 500, bytesOut: 0),
        ])

        let vm = AggregateChartViewModel()
        await vm.load(range: 86_400)

        let bucket = try XCTUnwrap(vm.timeline.first { $0.timestamp == hourStart })
        XCTAssertEqual(bucket.bytesIn, 1500, "同一小时内两条事件应该合并进同一根柱子")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/Documents/traffic-monitoring && swift test --filter AggregateChartViewModelTests/testLoadUsesHourlyBucketsForRangesUpToOneDay`
Expected: FAIL — currently `load(range: 86_400)` uses `TimelineBucket.size(for:)`, which buckets a ≤24h range into 5-minute buckets, not hourly, so no point will have `timestamp == hourStart` with both events merged into it (they'd land in different 5-minute buckets).

- [ ] **Step 3: Implement hourly bucketing for short ranges**

In `Sources/ViewModels/AggregateChartViewModel.swift`, modify `load(range:)`:

```swift
import Foundation

/// 主窗口聚合趋势图的 ViewModel：定期把全部进程的时间线查回来。
///
/// 跟 `DetailViewModel`（`Views/Detail/DetailWindow.swift`）是同一套写法，
/// 区别只是查询走 `queryAggregateTimeline` 而不是按单个 processKey 过滤。
@MainActor
final class AggregateChartViewModel: ObservableObject {
    @Published var timeline: [TimelinePoint] = []

    private var refreshTask: Task<Void, Never>?

    func startRefreshing(range: TimeInterval) {
        stopRefreshing()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.load(range: range)
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    func stopRefreshing() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func load(range: TimeInterval) async {
        let since = Date().timeIntervalSince1970 - range
        let points = (try? await DataStore.shared.queryAggregateTimeline(
            since: since,
            bucketSeconds: bucketSeconds(for: range)
        )) ?? []
        if timeline != points { timeline = points }
    }

    /// 聚合图是给你看大局的总览，不需要跟单进程详情图一样细——
    /// ≤1 天固定按整点分桶（一天 24 根柱子，对应"按小时看"），更长范围
    /// 复用 `TimelineBucket.size(for:)`（本来就已经是按小时/半小时分的）。
    private func bucketSeconds(for range: TimeInterval) -> TimeInterval {
        range <= 86_400 ? 3_600 : TimelineBucket.size(for: range)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/Documents/traffic-monitoring && swift test --filter AggregateChartViewModelTests`
Expected: PASS (all 3 tests in this class)

- [ ] **Step 5: Commit**

```bash
cd ~/Documents/traffic-monitoring
git add Sources/ViewModels/AggregateChartViewModel.swift Tests/AggregateChartViewModelTests.swift
git commit -m "$(cat <<'EOF'
feat(chart): use hourly buckets for the aggregate chart on short ranges

Today's aggregate chart now buckets by the hour (24 bars/day) instead
of reusing DetailWindow's finer 5-minute buckets - matches "click an
hour, see that hour" instead of the per-process diagnostic granularity.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01TscZ9FCs5m5AAzTzDapEJc
EOF
)"
```

---

### Task 2: Bar-only display, click-to-select, and the filtered historical table

**Files:**
- Modify: `Sources/Views/Detail/DetailWindow.swift` (`TrafficChart`, add `onSelectBucket`)
- Modify: `Sources/Views/MainWindow/AggregateTrafficCard.swift` (drop style picker, add `onSelectRange`)
- Create: `Sources/Views/MainWindow/HistoricalSummaryTable.swift`
- Modify: `Sources/Views/MainWindow/MainWindowView.swift` (own selection state, banner, wire `ContentTable`)
- Modify: `Sources/Resources/en.lproj/Localizable.strings`, `Sources/Resources/zh-Hans.lproj/Localizable.strings`

This task is UI wiring on top of Task 1's already-tested data layer and Phase 1's already-tested `querySummary`. Verified by build + full suite + manual screenshot, same as Phase 3 Task 1.

- [ ] **Step 1: Add `onSelectBucket` to `TrafficChart`**

In `Sources/Views/Detail/DetailWindow.swift`, add a new parameter to `TrafficChart` (after `mirrorsUpload`):

```swift
struct TrafficChart: View {
    let points: [TimelinePoint]
    let style: ChartStyle
    let range: TimeInterval
    /// 上行是否镜像到零轴下方。默认 false = 与下载同轴（都画在零轴上方）。
    var mirrorsUpload = false
    /// 选中的桶发生变化时回调（nil = 取消选中）。默认不设，`DetailWindow` 现有
    /// 用法不受影响。
    var onSelectBucket: ((TimelinePoint?) -> Void)?
```

Then, in `body`, add an `.onChange` right after `.chartXSelection(value: $selected)`:

```swift
        .chartXSelection(value: $selected)
        .onChange(of: selectedPoint) { _, newValue in onSelectBucket?(newValue) }
```

- [ ] **Step 2: Simplify `AggregateTrafficCard` to bar-only and add `onSelectRange`**

Replace `Sources/Views/MainWindow/AggregateTrafficCard.swift` entirely:

```swift
import Charts
import SwiftUI

/// 主窗口顶部的聚合流量趋势图卡片：全部进程加总，固定柱状图样式。
///
/// 直接复用 `TrafficChart`（`Views/Detail/DetailWindow.swift`）——它只认
/// `[TimelinePoint]`，从不关心数据是单进程的还是聚合的。
@MainActor
struct AggregateTrafficCard: View {
    let range: TimeInterval
    /// 选中某根柱子对应的时间范围时回调；取消选中传 nil。
    var onSelectRange: ((ClosedRange<TimeInterval>?) -> Void)?

    @StateObject private var vm = AggregateChartViewModel()

    private var bucketSeconds: TimeInterval {
        vm.timeline.count >= 2
            ? vm.timeline[1].timestamp - vm.timeline[0].timestamp
            : 3_600
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
                TrafficChart(points: vm.timeline, style: .bar, range: range) { point in
                    guard let point else { onSelectRange?(nil); return }
                    onSelectRange?(point.timestamp ... (point.timestamp + bucketSeconds))
                }
                .frame(height: 200)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.12)))
        .onAppear { vm.startRefreshing(range: range) }
        .onDisappear { vm.stopRefreshing() }
        .onChange(of: range) { _, newValue in vm.startRefreshing(range: newValue) }
    }
}
```

- [ ] **Step 3: Add the localization strings for the selection banner**

In `Sources/Resources/en.lproj/Localizable.strings`, after `"aggregate.trafficOverTime" = "Traffic over time";`:

```
"aggregate.showingRange" = "Showing %@";
"aggregate.clearSelection" = "Clear";
```

In `Sources/Resources/zh-Hans.lproj/Localizable.strings`, after the corresponding line:

```
"aggregate.showingRange" = "正在显示 %@";
"aggregate.clearSelection" = "清除";
```

- [ ] **Step 4: Create `HistoricalSummaryTable`**

Create `Sources/Views/MainWindow/HistoricalSummaryTable.swift`:

```swift
import SwiftUI

/// 选中聚合图上某根柱子后，用这张表代替实时的 `ProcessTableView`——
/// 数据来自 `DataStore.querySummary`（Phase 1），是那个时间窗里的历史汇总，
/// 不是实时速率，所以没有 Down now/Up now 两列（过去的速率没有意义）。
@MainActor
struct HistoricalSummaryTable: View {
    let since: TimeInterval
    let until: TimeInterval

    @State private var summaries: [ProcessSummary] = []

    var body: some View {
        Group {
            if summaries.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "tray").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text(L("detail.noData")).foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(summaries) {
                    TableColumn(L("column.process"), value: \.displayName) { s in
                        HStack(spacing: 6) {
                            ProcessIcon(iconPath: nil, bundleId: s.bundleId, fallbackSymbol: "app.fill")
                            Text(s.displayName).lineLimit(1)
                        }
                    }.width(min: 140)

                    TableColumn(L("column.download"), value: \.totalIn) { s in
                        Text(ByteFormatter.string(bytes: s.totalIn))
                            .foregroundColor(.blue).monospacedDigit()
                    }.width(min: 90)

                    TableColumn(L("column.upload"), value: \.totalOut) { s in
                        Text(ByteFormatter.string(bytes: s.totalOut))
                            .foregroundColor(.red).monospacedDigit()
                    }.width(min: 90)

                    TableColumn(L("column.total"), value: \.totalBytes) { s in
                        Text(ByteFormatter.string(bytes: s.totalBytes))
                            .fontWeight(.medium).monospacedDigit()
                    }.width(min: 100)
                }
            }
        }
        .task(id: since) {
            summaries = (try? await DataStore.shared.querySummary(since: since, until: until)) ?? []
        }
    }
}
```

- [ ] **Step 5: Wire selection state into `MainWindowView`**

In `Sources/Views/MainWindow/MainWindowView.swift`, add state and modify `body`:

```swift
    @State private var selectedProcessKey: String?
    @State private var detailTarget: ProcessRow?
    @State private var exportDocument: CSVDocument?
    @State private var selectedHistoricalRange: ClosedRange<TimeInterval>?

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 250)
        } detail: {
            VStack(spacing: 0) {
                SummaryRow().padding(.horizontal).padding(.top, 12)
                Divider().padding(.top, 12)
                AggregateTrafficCard(
                    range: dashboard.selectedTimeRange.chartRangeSeconds,
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
        }
```

(Only the `@State` declarations and the `detail:` closure change — everything after it, i.e. `.toolbar`/`.sheet`/`.fileExporter`, stays as-is.)

Add this helper method to `MainWindowView` (near the other private helpers):

```swift
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

- [ ] **Step 6: Make `ContentTable` accept and act on `historicalRange`**

In `Sources/Views/MainWindow/MainWindowView.swift`, modify the `ContentTable` struct:

```swift
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
```

- [ ] **Step 7: Build and run the full test suite**

Run: `cd ~/Documents/traffic-monitoring && swift build 2>&1 | tail -20`
Expected: `Build complete!`, no errors.

Run: `cd ~/Documents/traffic-monitoring && swift test 2>&1 | grep -E "Executed [0-9]+ tests|error:|FAIL"`
Expected: All tests pass, 0 failures.

- [ ] **Step 8: Manual verification**

```bash
cd ~/Documents/traffic-monitoring
pkill -f "/Applications/TrafficMonitor.app" 2>/dev/null
rm -rf .build
./Scripts/make-app.sh .
cp -R "TrafficMonitor.app/Contents/Resources/TrafficMonitor_TrafficMonitor.bundle" "TrafficMonitor.app/TrafficMonitor_TrafficMonitor.bundle"
codesign --force --sign - --timestamp=none "TrafficMonitor.app"
rm -rf /Applications/TrafficMonitor.app
cp -R TrafficMonitor.app /Applications/TrafficMonitor.app
xattr -dr com.apple.quarantine /Applications/TrafficMonitor.app 2>/dev/null || true
open /Applications/TrafficMonitor.app
```

Wait a few seconds, screenshot, and visually confirm: the aggregate chart now shows discrete hourly bars (not a smooth line), clicking a bar shows a "Showing HH:mm–HH:mm" banner above the table, the table switches to Download/Upload/Total-only columns for that hour, and clicking "Clear" returns to the live table.

**Note for whoever runs Step 8:** always fully `rm -rf /Applications/TrafficMonitor.app` before `cp -R` into it — if the destination directory already exists, `cp -R src dst` copies `src` *inside* `dst` as a nested folder instead of overwriting it, silently leaving the old binary running. This bit us once already this session.

- [ ] **Step 9: Commit**

```bash
cd ~/Documents/traffic-monitoring
git add Sources/Views/Detail/DetailWindow.swift Sources/Views/MainWindow/AggregateTrafficCard.swift Sources/Views/MainWindow/HistoricalSummaryTable.swift Sources/Views/MainWindow/MainWindowView.swift Sources/Resources/en.lproj/Localizable.strings Sources/Resources/zh-Hans.lproj/Localizable.strings
git commit -m "$(cat <<'EOF'
feat(ui): click an hour's bar to filter the table to that hour

Aggregate chart is now bar-only (dropped the line/area picker per
user request). Clicking a bar swaps the live process table for a
HistoricalSummaryTable scoped to that hour's DataStore.querySummary
results, with a banner to clear the selection back to the live view -
mirrors Bytetally's "brush the chart to narrow the app list" behavior.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01TscZ9FCs5m5AAzTzDapEJc
EOF
)"
```
