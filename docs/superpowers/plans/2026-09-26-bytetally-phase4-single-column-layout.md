# Bytetally Phase 4: Single-Column Layout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `MainWindowView`'s `NavigationSplitView` (sidebar + detail) with a single-column layout, per section 1 of `docs/superpowers/specs/2026-09-25-bytetally-style-dashboard-design.md` — moving "time range" from a sidebar list into a segmented control in the toolbar, and "Grouped view" from a sidebar toggle into a toolbar button.

**Architecture:** `MainWindowView.body` drops the `NavigationSplitView`/`SidebarView` pair and becomes a plain `VStack` (the exact content currently inside the `detail:` closure, unchanged). `SidebarView` is deleted outright — nothing else references it. `toolbarContent` gains a new leading `ToolbarItemGroup(placement: .navigation)` holding a `Picker(selection: Bindable(dashboard).selectedTimeRange)` in `.segmented` style, and the existing trailing `ToolbarItemGroup` gains a button-styled `Toggle` bound to `Bindable(dashboard).isGroupedView`, inserted between the search field and the export button. No `DashboardViewModel`, `DataStore`, or other view-model logic changes — this task is pure view wiring, so there is no new pure function to drive with a failing unit test; correctness is verified by full-suite regression (nothing should change) plus a manual build-and-screenshot check, the same method already used for Phase 3 Task 2.

**Tech Stack:** Swift 6.2, SwiftUI, XCTest (regression only — no new tests, see Architecture).

## Global Constraints

- Swift tools version: 5.9; deployment target macOS 14.
- Localization: every user-facing string goes through the `L(_:)` lookup (`Sources/Utilities/Localization.swift`) with matching keys added to **both** `Sources/Resources/en.lproj/Localizable.strings` and `Sources/Resources/zh-Hans.lproj/Localizable.strings` — never a bare string literal in a view.
- Do not touch `DashboardViewModel.TimeRange`, `AggregateTrafficCard`, `ContentTable`, `ProcessTableView`, `GroupTableView`, `EmptyStateView`, or `CSVDocument` — this plan is scoped to `MainWindowView`'s own layout and toolbar only. The Curve/Heatmap toggle, network filter, export-format dropdown, alert bell, and the 6-preset time range expansion (spec sections 3–7) are separate, not-yet-planned work — do not add placeholder UI for them here.
- Run the full suite with `cd ~/Documents/traffic-monitoring && swift test 2>&1 | grep -E "Executed [0-9]+ tests|error:|FAIL"` — expect the same 210 tests, 1 skipped, 0 failures as before this task (this task adds no tests).

---

### Task 1: Single-column layout — remove the sidebar, relocate its two controls into the toolbar

**Files:**
- Modify: `Sources/Views/MainWindow/MainWindowView.swift` (`MainWindowView.body`, `MainWindowView.toolbarContent`; delete the private `SidebarView` struct)
- Modify: `Sources/Resources/en.lproj/Localizable.strings`
- Modify: `Sources/Resources/zh-Hans.lproj/Localizable.strings`

**Interfaces:**
- Consumes (unchanged, already exist): `DashboardViewModel.TimeRange` (`allCases`, `displayName`, `id`, `Identifiable`, `Hashable` via compiler-synthesized enum conformance), `DashboardViewModel.selectedTimeRange: TimeRange`, `DashboardViewModel.isGroupedView: Bool`, `DashboardViewModel.processGroups: [ProcessGroup]`, `Bindable(_:)` (already used in this file for `searchText`).
- Produces: `MainWindowView.toolbarContent` now has two `ToolbarItemGroup`s — a leading `.navigation`-placed one (the time-range segmented control) and the existing trailing one (now also holding the grouped-view toggle). Any later phase that adds more toolbar controls (Curve/Heatmap switch, network filter, export dropdown, alert bell — spec sections 3–7) adds them into these same two groups, not new ones, to keep everything aligned in one toolbar row.

- [ ] **Step 1: Add the new toolbar localization keys, remove the sidebar-only ones**

In `Sources/Resources/en.lproj/Localizable.strings`, replace:

```
"sidebar.timeRange"        = "Time range";
"sidebar.view"             = "View";
"sidebar.groupedView"      = "Grouped view";
"sidebar.currentRange"     = "Range: %@";
```

with:

```
"toolbar.timeRange"        = "Time range";
"toolbar.groupedView"      = "Grouped view";
```

In `Sources/Resources/zh-Hans.lproj/Localizable.strings`, replace:

```
"sidebar.timeRange"        = "时间范围";
"sidebar.view"             = "视图";
"sidebar.groupedView"      = "按分组查看";
"sidebar.currentRange"     = "范围: %@";
```

with:

```
"toolbar.timeRange"        = "时间范围";
"toolbar.groupedView"      = "按分组查看";
```

(`"range.today"`/`"range.week"`/`"range.month"` a few lines below are untouched — `TimeRange.displayName` still uses them.)

- [ ] **Step 2: Rewrite `MainWindowView.body` as a single-column `VStack`**

In `Sources/Views/MainWindow/MainWindowView.swift`, replace the whole `body`:

```swift
    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 250)
        } detail: {
            VStack(spacing: 0) {
                SummaryRow().padding(.horizontal).padding(.top, 12)
                Divider().padding(.top, 12)
                AggregateTrafficCard(
                    since: dashboard.selectedTimeRange.start.timeIntervalSince1970,
                    until: dashboard.selectedTimeRange.end.timeIntervalSince1970,
                    selectedRange: selectedHistoricalRange,
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

with:

```swift
    var body: some View {
        VStack(spacing: 0) {
            SummaryRow().padding(.horizontal).padding(.top, 12)
            Divider().padding(.top, 12)
            AggregateTrafficCard(
                since: dashboard.selectedTimeRange.start.timeIntervalSince1970,
                until: dashboard.selectedTimeRange.end.timeIntervalSince1970,
                selectedRange: selectedHistoricalRange,
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

(Only the `NavigationSplitView { SidebarView()... } detail: { ... }` wrapper is gone — the `VStack` and everything after `.toolbar` is byte-for-byte the same as what used to be inside `detail:`.)

- [ ] **Step 3: Add the time-range segmented control and grouped-view toggle to `toolbarContent`**

In the same file, replace `toolbarContent`:

```swift
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
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

            Button { exportDocument = CSVDocument(rows: dashboard.rows) } label: {
                Label(L("toolbar.export"), systemImage: "square.and.arrow.up")
            }.help(L("toolbar.export.help"))
        }
    }
```

with:

```swift
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Picker(L("toolbar.timeRange"), selection: Bindable(dashboard).selectedTimeRange) {
                ForEach(DashboardViewModel.TimeRange.allCases) { range in
                    Text(range.displayName).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
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
```

- [ ] **Step 4: Delete the `SidebarView` struct entirely**

In the same file, delete the whole `// MARK: - 侧栏` section — the private `SidebarView` struct (from `@MainActor private struct SidebarView: View {` through its closing brace, including its `sectionHeader(_:)` and `icon(for:)` helper methods). Nothing else in the codebase references `SidebarView` or that `icon(for:)` (verified: `grep -rn "SidebarView\|icon(for:" Sources/` before this task showed only this file and `IconCatalog.icon(for:)` in `TrafficPipeline.swift`, an unrelated function on a different type).

- [ ] **Step 5: Build**

Run: `cd ~/Documents/traffic-monitoring && swift build 2>&1 | tail -30`
Expected: `Build complete!`, no errors. (A pre-existing `NStatCollector` Sendable warning is unrelated and expected to still appear.)

- [ ] **Step 6: Run the full test suite (regression check)**

Run: `cd ~/Documents/traffic-monitoring && swift test 2>&1 | grep -E "Executed [0-9]+ tests|error:|FAIL"`
Expected: `Executed 210 tests, with 1 test skipped and 0 failures (0 unexpected)` — the same count as before this task. This task changes no view-model or data logic, so no test should newly pass, fail, or need adding.

- [ ] **Step 7: Manual verification**

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

Wait a couple seconds, activate the app, and screenshot. Visually confirm:
- No sidebar — the window is one column: toolbar, summary cards, chart, table.
- The toolbar's leading segmented control shows all three time-range labels (Today / This week / This month per current locale) without clipping; clicking each one updates the summary cards, chart, and table exactly as the old sidebar list used to.
- The grouped-view toggle button (grid icon, next to the search field) switches the table between the process list and `GroupTableView`, matching the old sidebar checkbox's behavior; it's disabled (dimmed, non-interactive) when there are no process groups defined.
- Clicking an hour's bar on the chart still shows the "Showing HH:mm–HH:mm / Clear" banner and swaps in `HistoricalSummaryTable` (Phase 3 behavior, unaffected by this task).

If the segmented control's labels clip at `width: 260`, widen the `.frame(width:)` value until they don't, re-screenshot, and note the final value in the commit message.

**Note for whoever runs this step:** always fully `rm -rf /Applications/TrafficMonitor.app` before `cp -R` into it — if the destination directory already exists, `cp -R src dst` copies `src` *inside* `dst` as a nested folder instead of overwriting it, silently leaving the old binary running. This bit a previous session already.

- [ ] **Step 8: Commit**

```bash
cd ~/Documents/traffic-monitoring
git add Sources/Views/MainWindow/MainWindowView.swift Sources/Resources/en.lproj/Localizable.strings Sources/Resources/zh-Hans.lproj/Localizable.strings
git commit -m "$(cat <<'EOF'
feat(ui): replace sidebar with single-column layout (Bytetally redesign)

MainWindowView drops NavigationSplitView/SidebarView for a single VStack
per spec section 1 (docs/superpowers/specs/2026-09-25-bytetally-style-
dashboard-design.md). Time range moves from a sidebar list into a
segmented Picker in a new leading toolbar group; "Grouped view" moves
from a sidebar checkbox into a button-styled Toggle next to the search
field. No view-model or data-layer changes - pure view wiring, verified
by the unchanged 210-test regression suite plus a manual screenshot pass.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Es5J9vsdkwCV38NZGpBVGC
EOF
)"
```
