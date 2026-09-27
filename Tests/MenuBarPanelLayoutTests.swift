import AppKit
import SwiftUI
import XCTest
@testable import TrafficMonitor

// ============================================================
// MARK: - 菜单栏面板布局
// ============================================================

/// 面板从菜单栏往下挂：**顶边固定、底边浮动**。
/// 高度一变，窗口原点跟着上下移 —— 实测旧实现下 y 在 921↔939 之间来回跳，
/// 看起来就是「面板在闪」。
///
/// 这组测试把面板真正渲染成位图来验证，而不是只看代码里写没写 `.frame`。
@MainActor
final class MenuBarPanelLayoutTests: XCTestCase {
    private func row(_ index: Int, rx: Double = 0, tx: Double = 500) -> ProcessRow {
        ProcessRow(key: "p\(index)", bundleId: nil,
                   displayName: "进程 \(index)",
                   icon: "app.dashed", iconPath: nil,
                   totalIn: 1_000, totalOut: 500,
                   rxRate: rx == 0 ? Double(90_000 >> index) : rx,
                   txRate: tx, spark: [])
    }

    private func hosting(processCount: Int) -> NSHostingView<some View> {
        let dashboard = DashboardViewModel.shared
        dashboard.apply(DashboardSnapshot(
            rows: (0..<processCount).map { row($0) },
            totalRxRate: 123_456, totalTxRate: 45_678, totalIn: 10_900_000_000, totalOut: 0
        ))
        let host = NSHostingView(rootView:
            MenuBarPanel().environment(dashboard).environment(CollectorService.shared))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func height(_ processCount: Int) -> CGFloat {
        hosting(processCount: processCount).fittingSize.height
    }

    private func bitmap(_ processCount: Int) -> NSBitmapImageRep {
        let host = hosting(processCount: processCount)
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// 两张位图从第几**点**开始出现差异
    private func firstDifferingRow(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> CGFloat {
        let scale = CGFloat(a.pixelsWide) / a.size.width
        for y in 0..<min(a.pixelsHigh, b.pixelsHigh) {
            for x in 0..<min(a.pixelsWide, b.pixelsWide) where a.colorAt(x: x, y: y) != b.colorAt(x: x, y: y) {
                return CGFloat(y) / scale
            }
        }
        return CGFloat(min(a.pixelsHigh, b.pixelsHigh)) / scale
    }

    // MARK: - 高度不随数据抖动

    /// **回归主项**：拿真机采到的那种「每帧活跃进程数都不一样」的序列跑一遍，
    /// 面板高度必须一动不动。
    ///
    /// 旧实现直接取快照里速率 > 0 的前六名，同一段序列下高度在 149↔203pt 之间
    /// 反复伸缩。现在由 `MenuBarRowLedger` 的驻留机制把行留住，高度恒定。
    func testHeightIsConstantAcrossChurningSnapshots() {
        let dashboard = DashboardViewModel.shared
        // 真机日志里的活跃进程数序列（40 秒、每 2 秒一帧）
        let activeCounts = [6, 6, 5, 5, 4, 6, 4, 5, 5, 3, 5, 4, 4, 5, 6, 6, 4, 4, 5, 4, 5]
        var heights: [CGFloat] = []

        for active in activeCounts {
            // 总共 12 个进程，其中前 active 个这一帧有流量，其余为 0
            let rows = (0..<12).map { index in
                row(index, rx: index < active ? Double(90_000 >> index) : 0,
                    tx: index < active ? 500 : 0)
            }
            dashboard.apply(DashboardSnapshot(rows: rows, totalRxRate: 1, totalTxRate: 1,
                                              totalIn: 10_900_000_000, totalOut: 0))
            let host = NSHostingView(rootView:
                MenuBarPanel().environment(dashboard).environment(CollectorService.shared))
            heights.append(host.fittingSize.height)
        }

        // 第一帧台账还在攒行，从第二帧起必须完全恒定
        let settled = Array(heights.dropFirst())
        XCTAssertEqual(Set(settled).count, 1,
                       "面板高度随活跃进程数抖动了：\(heights)")
    }

    /// 核心断言：面板顶部的固定区必须完整包住三个操作按钮。
    ///
    /// 总计区约 40pt + 分隔线 + 操作行约 26pt ≈ 88pt。阈值取 80pt：
    /// 一旦有人把操作行挪回进程列表**下面**，逐像素一致的前缀会缩到只剩
    /// 总计区（约 40pt），这条就会失败。
    func testFixedRegionCoversActionRow() {
        let identical = firstDifferingRow(bitmap(0), bitmap(MenuBarPanel.rowCapacity))
        XCTAssertGreaterThanOrEqual(identical, 80,
            "顶部固定区只有 \(identical)pt，装不下操作行 —— 按钮会随进程数移位")
    }

    /// 进程数变化只应改变列表区，固定区一像素都不该动
    func testFixedRegionIdenticalAcrossEveryProcessCount() {
        let reference = bitmap(0)
        for count in [1, 2, 3, MenuBarPanel.rowCapacity] {
            let identical = firstDifferingRow(reference, bitmap(count))
            XCTAssertGreaterThanOrEqual(identical, 80, "\(count) 个进程时固定区发生了变化")
        }
    }

    /// 超出容量的进程被截断，面板不会无限变长
    func testExcessProcessesAreTruncated() {
        XCTAssertEqual(height(MenuBarPanel.rowCapacity), height(50))
    }

    // MARK: - 数值与单位不横跳

    private func bitmap(rx: Double, tx: Double, bytes: Int64) -> NSBitmapImageRep {
        let dashboard = DashboardViewModel.shared
        dashboard.apply(DashboardSnapshot(rows: [row(0)],
                                          totalRxRate: rx, totalTxRate: tx, totalIn: bytes, totalOut: 0))
        let host = NSHostingView(rootView:
            MenuBarPanel().environment(dashboard).environment(CollectorService.shared))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// 某一**行**（顶部指标的数值那一行）上，有内容的像素占据的横向区间
    private func inkSpan(row y: CGFloat, of rep: NSBitmapImageRep,
                         from x0: CGFloat, to x1: CGFloat) -> ClosedRange<Int>? {
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        let py = Int(y * scale)
        guard py >= 0, py < rep.pixelsHigh else { return nil }
        // 面板背景是纯色，取最左上角那一点当基准
        let background = rep.colorAt(x: 0, y: 0)
        var lo: Int?, hi: Int?
        for px in Int(x0 * scale)..<min(Int(x1 * scale), rep.pixelsWide)
        where rep.colorAt(x: px, y: py) != background {
            if lo == nil { lo = px }
            hi = px
        }
        guard let lo, let hi else { return nil }
        return lo...hi
    }

    /// 数值长度变化不能推动分隔线。
    ///
    /// `0 B/s` 与 `120.6 KB/s` 差约 40pt —— 若槽位宽度由内容决定，
    /// 分隔线会横移这么多，右侧指标跟着跑。这里直接取分隔线所在的像素列比对。
    func testDividersDoNotMoveWhenValuesChange() {
        let small = bitmap(rx: 0, tx: 0, bytes: 0)
        let large = bitmap(rx: 123_456, tx: 999_999_999, bytes: 10_900_000_000)

        let content = 280 - 20.0                     // 面板宽减去两侧 padding
        let gutter = MetricSlot.dividerPadding * 2 + 1
        let slotWidth = (content - gutter * 2) / 3    // 三个槽位等分剩下的宽度
        let panelPadding: CGFloat = 10
        let firstDivider = panelPadding + slotWidth + gutter / 2
        let secondDivider = firstDivider + slotWidth + gutter

        // 不直接 XCTAssertEqual 两个颜色数组 —— 失败时会把整列像素倒出来，
        // 几千字符里看不出问题。只报差异数量。
        for (index, x) in [firstDivider, secondDivider].enumerated() {
            let a = column(x, of: small), b = column(x, of: large)
            let differing = zip(a, b).filter { $0 != $1 }.count
            XCTAssertEqual(differing, 0,
                "第 \(index + 1) 条分隔线随数值移动了：x=\(x)pt 处有 \(differing)/\(a.count) 个像素不同")
        }
    }

    private func column(_ x: CGFloat, of rep: NSBitmapImageRep) -> [NSColor?] {
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        let px = Int(x * scale)
        guard px >= 0, px < rep.pixelsWide else { return [] }
        return (0..<rep.pixelsHigh).map { rep.colorAt(x: px, y: $0) }
    }

    /// **单位不许跟着数字跑**。
    ///
    /// 这是把「数字右对齐 + 单位左对齐」拆成两列的全部意义所在：
    /// `5.6 KB/s` 和 `999.9 KB/s` 的数字长度差两位，但 `KB/s` 必须停在同一个 x。
    /// 若哪天有人图省事把两者拼回一个 `Text`，无论左对齐还是右对齐，这条都会失败：
    /// 左对齐时单位被数字推向右；右对齐时数字和单位一起左移，右缘齐了但单位仍在动。
    func testUnitStaysPutWhileNumberGrows() {
        // 同一档单位（KB/s）下，数字从 3 位变到 5 位
        let narrow = bitmap(rx: 5.6 * 1024, tx: 0, bytes: 0)
        let wide = bitmap(rx: 999.9 * 1024, tx: 0, bytes: 0)

        // 「下载速率」那一栏的横向范围
        let slotWidth = (280 - 20 - (MetricSlot.dividerPadding * 2 + 1) * 2) / 3.0
        let column: (CGFloat, CGFloat) = (10, 10 + slotWidth)

        // 不写死数值那一行的 y —— 布局一调整就会指错地方。
        // 两张图里标题一模一样、只有数值不同，所以「有差异的那些行」就是数值所在的行；
        // 取它们的并集，得到的就是数值文字的横向包围盒。
        guard let a = valueBox(of: narrow, comparedWith: wide, in: column),
              let b = valueBox(of: wide, comparedWith: narrow, in: column) else {
            return XCTFail("两张图在下载速率栏里没有差异，这条测试没测到东西")
        }

        // 右边缘 = 单位的末尾。数字变长只该向左生长。
        XCTAssertEqual(a.upperBound, b.upperBound,
                       "数字变长把单位推走了：窄值右缘 \(a.upperBound)px，宽值右缘 \(b.upperBound)px")
        XCTAssertLessThan(b.lowerBound, a.lowerBound,
                          "数字变长后左缘没有向左扩展，说明并没有右对齐")
    }

    /// 两张图有差异的那些行上，`rep` 的墨迹横向包围盒
    private func valueBox(of rep: NSBitmapImageRep, comparedWith other: NSBitmapImageRep,
                          in column: (CGFloat, CGFloat)) -> ClosedRange<Int>? {
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        var box: ClosedRange<Int>?
        for py in 0..<min(rep.pixelsHigh, other.pixelsHigh) {
            let y = CGFloat(py) / scale
            let here = inkSpan(row: y, of: rep, from: column.0, to: column.1)
            guard here != inkSpan(row: y, of: other, from: column.0, to: column.1),
                  let here else { continue }
            box = box.map { min($0.lowerBound, here.lowerBound)...max($0.upperBound, here.upperBound) }
                ?? here
        }
        return box
    }

    /// 槽位宽度只由「最宽可能字符串」决定，与当前数值无关
    func testSlotWidthsAreConstant() {
        let before = (MetricSlot.slot(.rate), MetricSlot.slot(.total), MetricSlot.slot(.compactRate))
        _ = bitmap(rx: 0, tx: 0, bytes: 0)
        _ = bitmap(rx: 9_999_999_999, tx: 9_999_999_999, bytes: .max / 2)
        XCTAssertEqual(before.0, MetricSlot.slot(.rate))
        XCTAssertEqual(before.1, MetricSlot.slot(.total))
        XCTAssertEqual(before.2, MetricSlot.slot(.compactRate))
    }

    /// 每个槽位都必须放得下自己最宽的内容，否则会被压缩或裁掉
    func testEverySlotFitsItsWidestContent() {
        for kind in [MetricSlot.Kind.rate, .total, .compactRate] {
            let slot = MetricSlot.slot(kind)
            XCTAssertGreaterThanOrEqual(slot.width, slot.pair,
                                        "\(kind) 槽位 \(slot.width)pt 放不下数值组 \(slot.pair)pt")
        }
    }

    /// 三个槽位加分隔线必须放得进面板，否则会被压缩或裁掉
    func testMetricRowFitsInsidePanel() {
        XCTAssertLessThanOrEqual(MetricSlot.totalRowWidth, 280 - 20,
                                 "指标行 \(MetricSlot.totalRowWidth)pt 放不进面板内容区")
    }

    /// 宽度固定 —— 进程名长短不该改变面板宽度
    func testWidthIsFixed() {
        let dashboard = DashboardViewModel.shared
        func width(_ name: String) -> CGFloat {
            dashboard.apply(DashboardSnapshot(rows: [
                ProcessRow(key: "a", bundleId: nil, displayName: name, icon: "app.dashed",
                           iconPath: nil, totalIn: 1, totalOut: 1, rxRate: 1, txRate: 1, spark: [])
            ]))
            return NSHostingView(rootView: MenuBarPanel()
                .environment(dashboard).environment(CollectorService.shared)).fittingSize.width
        }
        XCTAssertEqual(width("a"), width(String(repeating: "很长的进程名", count: 10)))
    }
}
