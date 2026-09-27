# Bytetally Phase 3 Task 1: Aggregate Traffic Chart Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the "Traffic over time" aggregate chart (all processes summed) to the main window, between the summary cards and the process table — the visual centerpiece from the Bytetally reference screenshot.

**Architecture:** `TrafficChart` (`Sources/Views/Detail/DetailWindow.swift`) is already generic over `[TimelinePoint]` and has zero dependency on a specific process — it's reused unmodified. A new `AggregateChartViewModel` mirrors `DetailViewModel`'s exact polling pattern but calls `DataStore.queryAggregateTimeline` (Phase 1) instead of `queryTimeline(processKey:)`. A new `AggregateTrafficCard` view wraps it and slots into the existing `NavigationSplitView` detail pane in `MainWindowView` — the sidebar itself is untouched in this task.

**Tech Stack:** Swift 6.2, SwiftUI, Swift Charts, XCTest.

## Global Constraints

- Swift tools version: 5.9; deployment target macOS 14.
- Reuse `TrafficChart`/`ChartStyle`/`TimelineBucket` from `Sources/Views/Detail/DetailWindow.swift` as-is — do not modify that file.
- Every new user-facing string needs both `Sources/Resources/en.lproj/Localizable.strings` and `Sources/Resources/zh-Hans.lproj/Localizable.strings` entries (the project's own `.strings` are declared `.copy` in `Package.swift`, so both locales must exist or the string falls back to showing its raw key).
- Run tests with `cd ~/Documents/traffic-monitoring && swift test --filter <ClassName>/<testMethodName>`.

---

### Task 1: `TimeRange.chartRangeSeconds` — bridge calendar ranges to `TrafficChart`'s seconds-based `range`

**Files:**
- Modify: `Sources/ViewModels/DashboardViewModel.swift` (the `TimeRange` enum, after `endDate(at:calendar:)`)
- Test: `Tests/TrafficPipelineTests.swift` (`TimeRangeBoundaryTests`)

**Interfaces:**
- Produces: `DashboardViewModel.TimeRange.chartRangeSeconds(at:calendar:) -> TimeInterval` and a `Date()`/`.current`-based convenience `var chartRangeSeconds: TimeInterval`.

- [ ] **Step 1: Write the failing test**

Add this method to `TimeRangeBoundaryTests` in `Tests/TrafficPipelineTests.swift`, right after `testAllStartsAreInThePast`:

```swift
    /// `TrafficChart` 认的是「从现在往前数多少秒」，不是日历意义上的起止点——
    /// 这个换算必须跟 `startDate(at:calendar:)` 用的是同一个起点。
    @MainActor
    func testChartRangeSecondsMatchesStartToNow() {
        let now = Date()
        let calendar = Calendar.current
        for range in DashboardViewModel.TimeRange.allCases {
            let expected = now.timeIntervalSince1970
                - range.startDate(at: now, calendar: calendar).timeIntervalSince1970
            XCTAssertEqual(range.chartRangeSeconds(at: now, calendar: calendar), expected, accuracy: 0.001,
                           "\(range.rawValue) 的换算应与 startDate 完全一致")
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/Documents/traffic-monitoring && swift test --filter TimeRangeBoundaryTests/testChartRangeSecondsMatchesStartToNow`
Expected: FAIL to compile — `chartRangeSeconds(at:calendar:)` doesn't exist yet.

- [ ] **Step 3: Implement `chartRangeSeconds`**

In `Sources/ViewModels/DashboardViewModel.swift`, add this to the `TimeRange` enum, directly after `endDate(at:calendar:)`:

```swift
        /// 「现在」到窗口起点的秒数，喂给 `TrafficChart` 的 `range` 参数——
        /// 它决定横轴跨度和分桶粗细（`TimelineBucket.size(for:)`）。
        var chartRangeSeconds: TimeInterval { chartRangeSeconds(at: Date(), calendar: .current) }

        func chartRangeSeconds(at now: Date, calendar: Calendar) -> TimeInterval {
            now.timeIntervalSince1970 - startDate(at: now, calendar: calendar).timeIntervalSince1970
        }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/Documents/traffic-monitoring && swift test --filter TimeRangeBoundaryTests/testChartRangeSecondsMatchesStartToNow`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd ~/Documents/traffic-monitoring
git add Sources/ViewModels/DashboardViewModel.swift Tests/TrafficPipelineTests.swift
git commit -m "$(cat <<'EOF'
feat(chart): add TimeRange.chartRangeSeconds for the aggregate chart

Bridges the calendar-boundary based today/week/month ranges to the
seconds-based range TrafficChart expects, using the exact same
startDate(at:calendar:) the existing range boundary tests already
cover.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `AggregateChartViewModel` — poll the aggregate timeline

**Files:**
- Create: `Sources/ViewModels/AggregateChartViewModel.swift`
- Test: `Tests/AggregateChartViewModelTests.swift`

**Interfaces:**
- Consumes: `DataStore.queryAggregateTimeline(since:until:bucketSeconds:) throws -> [TimelinePoint]` (Phase 1), `TimelineBucket.size(for:)` (`Sources/Views/Detail/DetailWindow.swift`).
- Produces: `@MainActor final class AggregateChartViewModel: ObservableObject` with `@Published var timeline: [TimelinePoint]`, `func startRefreshing(range: TimeInterval)`, `func stopRefreshing()`, `func load(range: TimeInterval) async`. Same shape as `DetailViewModel` (`Sources/Views/Detail/DetailWindow.swift`), consumed by Task 3's view.

- [ ] **Step 1: Write the failing test**

Create `Tests/AggregateChartViewModelTests.swift`:

```swift
import XCTest
@testable import TrafficMonitor

/// `AggregateChartViewModel` 是 `DetailViewModel` 的聚合版：同一套轮询写法，
/// 只是查询换成不按 processKey 过滤的 `queryAggregateTimeline`。
final class AggregateChartViewModelTests: XCTestCase {
    @MainActor
    func testLoadSumsAcrossProcessesFromRealDataStore() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AggregateChartViewModelTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await DataStore.shared.setup(at: dir.appendingPathComponent("aggregate.db"))

        let now = Date().timeIntervalSince1970
        try await DataStore.shared.insertEvents([
            TrafficEvent(id: nil, timestamp: now, interval: 5,
                         processKey: "Chrome", bundleId: nil, displayName: "Chrome",
                         bytesIn: 1000, bytesOut: 0),
            TrafficEvent(id: nil, timestamp: now, interval: 5,
                         processKey: "Edge", bundleId: nil, displayName: "Edge",
                         bytesIn: 500, bytesOut: 0),
        ])

        let vm = AggregateChartViewModel()
        await vm.load(range: 3600)

        let total = vm.timeline.reduce(0) { $0 + $1.bytesIn }
        XCTAssertEqual(total, 1500, "聚合图的 ViewModel 应该把两个进程的流量加在一起")
    }

    /// 空数据库不该崩，也不该抛错到调用方——跟 `DetailViewModel.load` 同样的
    /// `try?` 兜底
    @MainActor
    func testLoadOnEmptyDatabaseYieldsEmptyTimeline() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AggregateChartViewModelTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await DataStore.shared.setup(at: dir.appendingPathComponent("empty.db"))

        let vm = AggregateChartViewModel()
        await vm.load(range: 3600)

        XCTAssertTrue(vm.timeline.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/Documents/traffic-monitoring && swift test --filter AggregateChartViewModelTests/testLoadSumsAcrossProcessesFromRealDataStore`
Expected: FAIL to compile — `AggregateChartViewModel` doesn't exist yet.

- [ ] **Step 3: Implement `AggregateChartViewModel`**

Create `Sources/ViewModels/AggregateChartViewModel.swift`:

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
            bucketSeconds: TimelineBucket.size(for: range)
        )) ?? []
        if timeline != points { timeline = points }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/Documents/traffic-monitoring && swift test --filter AggregateChartViewModelTests`
Expected: PASS (both tests)

- [ ] **Step 5: Commit**

```bash
cd ~/Documents/traffic-monitoring
git add Sources/ViewModels/AggregateChartViewModel.swift Tests/AggregateChartViewModelTests.swift
git commit -m "$(cat <<'EOF'
feat(chart): add AggregateChartViewModel polling queryAggregateTimeline

Same polling shape as DetailViewModel, but sums across every process
instead of filtering to one - the data source for the new main-window
aggregate chart.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `AggregateTrafficCard` view + wire into `MainWindowView`

**Files:**
- Create: `Sources/Views/MainWindow/AggregateTrafficCard.swift`
- Modify: `Sources/Views/MainWindow/MainWindowView.swift:21-31` (`body`)
- Modify: `Sources/Resources/en.lproj/Localizable.strings:27` (after `summary.rangeTraffic`)
- Modify: `Sources/Resources/zh-Hans.lproj/Localizable.strings:27` (after `summary.rangeTraffic`)

**Interfaces:**
- Consumes: `AggregateChartViewModel` (Task 2), `TrafficChart`/`ChartStyle` (`Sources/Views/Detail/DetailWindow.swift`), `DashboardViewModel.TimeRange.chartRangeSeconds` (Task 1).
- Produces: `struct AggregateTrafficCard: View` with `let range: TimeInterval`, mounted in `MainWindowView.body`.

This task is UI wiring with no new pure logic to unit-test (the pure logic — `TrafficChart`'s rendering and `AggregateChartViewModel`'s querying — is already covered by Tasks 1–2 and by the existing `DetailChartTests.swift`). Verification here is: it compiles, the full suite still passes, and a manual screenshot confirms the card actually renders in the real running app.

- [ ] **Step 1: Add the new localization strings**

In `Sources/Resources/en.lproj/Localizable.strings`, after line 27 (`"summary.rangeTraffic" = "%@ traffic";`):

```
"aggregate.trafficOverTime" = "Traffic over time";
```

In `Sources/Resources/zh-Hans.lproj/Localizable.strings`, after the corresponding line:

```
"aggregate.trafficOverTime" = "流量趋势";
```

- [ ] **Step 2: Create the card view**

Create `Sources/Views/MainWindow/AggregateTrafficCard.swift`:

```swift
import Charts
import SwiftUI

/// 主窗口顶部的聚合流量趋势图卡片：全部进程加总。
///
/// 直接复用 `TrafficChart`（`Views/Detail/DetailWindow.swift`）——它只认
/// `[TimelinePoint]`，从不关心数据是单进程的还是聚合的。
@MainActor
struct AggregateTrafficCard: View {
    let range: TimeInterval

    @StateObject private var vm = AggregateChartViewModel()
    @AppStorage("com.trafficmonitor.aggregate.style") private var styleRaw: String = ChartStyle.line.rawValue

    private var style: ChartStyle { ChartStyle(rawValue: styleRaw) ?? .line }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("aggregate.trafficOverTime")).font(.headline)
                Spacer()
                Picker("", selection: $styleRaw) {
                    ForEach(ChartStyle.allCases) { s in
                        Image(systemName: s.symbol).tag(s.rawValue).help(s.label)
                    }
                }
                .pickerStyle(.segmented).frame(width: 110).labelsHidden()
            }

            if vm.timeline.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.system(size: 22)).foregroundStyle(.secondary)
                    Text(L("detail.noData")).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                TrafficChart(points: vm.timeline, style: style, range: range)
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

- [ ] **Step 3: Wire it into `MainWindowView`**

In `Sources/Views/MainWindow/MainWindowView.swift`, modify `body` (around line 21):

```swift
    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 250)
        } detail: {
            VStack(spacing: 0) {
                SummaryRow().padding(.horizontal).padding(.top, 12)
                Divider().padding(.top, 12)
                AggregateTrafficCard(range: dashboard.selectedTimeRange.chartRangeSeconds)
                    .padding(.horizontal).padding(.top, 12)
                Divider().padding(.top, 12)
                ContentTable(selection: $selectedProcessKey, onOpenDetail: { detailTarget = $0 })
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
```

(Only the `detail:` closure's `VStack` body changes — the `.toolbar`/`.sheet`/`.fileExporter` modifiers after it are unchanged, shown here only so the insertion point is unambiguous.)

- [ ] **Step 4: Build and run the full test suite**

Run: `cd ~/Documents/traffic-monitoring && swift build 2>&1 | tail -20`
Expected: `Build complete!` with no errors or warnings about the new file.

Run: `cd ~/Documents/traffic-monitoring && swift test 2>&1 | grep -E "Executed [0-9]+ tests|error:|FAIL"`
Expected: All tests pass (208 from before + 3 new = 211), 0 failures.

- [ ] **Step 5: Manual verification — package and run the app, screenshot the result**

```bash
cd ~/Documents/traffic-monitoring
./Scripts/make-app.sh .
cp -R TrafficMonitor.app /Applications/TrafficMonitor.app
xattr -dr com.apple.quarantine /Applications/TrafficMonitor.app 2>/dev/null || true
open /Applications/TrafficMonitor.app
```

Wait a few seconds, take a screenshot, and visually confirm: the main window shows a "Traffic over time" / "流量趋势" card with a line chart between the summary cards and the process table, and it isn't empty (assuming the app has been collecting for a while, which it has been throughout this session).

- [ ] **Step 6: Commit**

```bash
cd ~/Documents/traffic-monitoring
git add Sources/Views/MainWindow/AggregateTrafficCard.swift Sources/Views/MainWindow/MainWindowView.swift Sources/Resources/en.lproj/Localizable.strings Sources/Resources/zh-Hans.lproj/Localizable.strings
git commit -m "$(cat <<'EOF'
feat(ui): add aggregate traffic chart to the main window

Slots an AggregateTrafficCard (wrapping the existing TrafficChart,
unmodified) between the summary cards and the process table -
the visual centerpiece from the Bytetally reference screenshots.
Sidebar layout is untouched in this task; that redesign is separate.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## What's next (not in this plan)

The Curve/Heatmap toggle (swapping this chart for the Phase-1 `queryHeatmap` grid), alert markers (▲ on the chart from Phase 2's `AlertEvent` log), the network filter dropdown, export-format dropdown, expanded time-range presets, and the eventual sidebar removal are all separate follow-up tasks, per the phased approach.
