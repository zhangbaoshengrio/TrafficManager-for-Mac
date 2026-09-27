import XCTest
@testable import TrafficMonitor

// ============================================================
// MARK: - 菜单栏行台账
// ============================================================

/// 这一层的职责只有一个：把逐帧抖动的快照变成**不逐帧变化**的列表。
/// 所以测的也全是「什么情况下列表不该变」。
final class MenuBarRowLedgerTests: XCTestCase {
    private func row(_ key: String, rx: Double = 0, tx: Double = 0) -> ProcessRow {
        ProcessRow(key: key, bundleId: nil, displayName: key, icon: "app.dashed",
                   iconPath: nil, totalIn: 1_000, totalOut: 1_000,
                   rxRate: rx, txRate: tx, spark: [])
    }

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - 驻留

    /// 空一帧不该让行消失 —— 这正是面板高度每两秒抖一次的直接原因
    func testRowSurvivesAGapFrame() {
        var ledger = MenuBarRowLedger()
        _ = ledger.update(with: [row("a", rx: 1_000)], now: t0)

        let gap = ledger.update(with: [row("a")], now: t0 + 2)
        XCTAssertEqual(gap.map(\.id), ["a"], "空一帧行就没了")
        XCTAssertTrue(gap[0].isIdle, "空档期的行应标记为 idle，界面据此淡化")

        let back = ledger.update(with: [row("a", rx: 500)], now: t0 + 4)
        XCTAssertFalse(back[0].isIdle)
    }

    /// 但也不能永远赖着 —— 超过驻留窗口就该摘掉
    func testRowIsDroppedAfterLingerWindow() {
        var ledger = MenuBarRowLedger()
        _ = ledger.update(with: [row("a", rx: 1_000)], now: t0)

        let inside = ledger.update(with: [row("a")], now: t0 + MenuBarRowLedger.lingerWindow - 1)
        XCTAssertEqual(inside.count, 1)

        let outside = ledger.update(with: [row("a")], now: t0 + MenuBarRowLedger.lingerWindow + 1)
        XCTAssertTrue(outside.isEmpty, "驻留窗口过了还留着")
    }

    /// 从来没有过流量的进程（只有历史累计）不该占位置
    func testNeverActiveProcessIsNotListed() {
        var ledger = MenuBarRowLedger()
        XCTAssertTrue(ledger.update(with: [row("idle")], now: t0).isEmpty)
    }

    // MARK: - 行数稳定

    /// **回归主项**：真机那种「每帧活跃进程数都不一样」的序列喂进来，
    /// 输出的行数必须一直是满的。
    func testRowCountIsStableWhileActivityChurns() {
        var ledger = MenuBarRowLedger()
        let keys = (0..<10).map { "p\($0)" }
        let activeCounts = [6, 6, 5, 5, 4, 6, 4, 5, 5, 3, 5, 4, 4, 5, 6, 6, 4, 4, 5, 4, 5]

        var counts: [Int] = []
        for (frame, active) in activeCounts.enumerated() {
            // 每帧换一批活跃进程，模拟真实的进出
            let rows = keys.enumerated().map { index, key in
                row(key, rx: (index + frame) % keys.count < active ? Double(1_000 * (index + 1)) : 0)
            }
            counts.append(ledger.update(with: rows, now: t0 + Double(frame) * 2).count)
        }

        XCTAssertEqual(Set(counts.dropFirst()).count, 1,
                       "行数还在抖：\(counts)")
        XCTAssertEqual(counts.last, MenuBarRowLedger.capacity)
    }

    /// 超出容量就截断
    func testCapacityIsRespected() {
        var ledger = MenuBarRowLedger()
        let rows = (0..<20).map { row("p\($0)", rx: Double($0 + 1)) }
        XCTAssertEqual(ledger.update(with: rows, now: t0).count, MenuBarRowLedger.capacity)
    }

    // MARK: - 名次稳定

    /// 单帧的尖峰不该把名次掀翻 —— 排序键是平滑速率，不是瞬时速率
    func testSingleSpikeDoesNotFlipRanking() {
        var ledger = MenuBarRowLedger()
        // 先让 a 稳定地跑在 b 前面
        for step in 0..<10 {
            _ = ledger.update(with: [row("a", rx: 10_000), row("b", rx: 1_000)],
                              now: t0 + Double(step) * 2)
        }
        // b 突然爆一帧
        let spiked = ledger.update(with: [row("a", rx: 10_000), row("b", rx: 20_000)],
                                   now: t0 + 20)
        XCTAssertEqual(spiked.map(\.id), ["a", "b"], "一帧尖峰就把名次换了")

        // 但持续跑高之后，名次该让出来
        for step in 11..<20 {
            _ = ledger.update(with: [row("a", rx: 10_000), row("b", rx: 20_000)],
                              now: t0 + Double(step) * 2)
        }
        let settled = ledger.update(with: [row("a", rx: 10_000), row("b", rx: 20_000)],
                                    now: t0 + 40)
        XCTAssertEqual(settled.map(\.id), ["b", "a"], "持续跑高了名次却不让")
    }

    /// 速率完全相同时也要有确定的名次，否则两行会每帧互换位置
    func testTiesAreOrderedDeterministically() {
        var ledger = MenuBarRowLedger()
        let rows = ["c", "a", "b"].map { row($0, rx: 1_000) }
        let first = ledger.update(with: rows, now: t0).map(\.id)
        let second = ledger.update(with: rows.reversed(), now: t0 + 2).map(\.id)
        XCTAssertEqual(first, second, "并列时名次跟着输入顺序走了")
    }

    // MARK: - 显示的仍是瞬时值

    /// 平滑只用于排名。数字照原样显示，否则用户看到的速率会比实际慢半拍。
    func testDisplayedRatesAreInstantaneous() {
        var ledger = MenuBarRowLedger()
        _ = ledger.update(with: [row("a", rx: 1_000, tx: 2_000)], now: t0)
        let out = ledger.update(with: [row("a", rx: 9_000, tx: 8_000)], now: t0 + 2)
        XCTAssertEqual(out[0].row.rxRate, 9_000)
        XCTAssertEqual(out[0].row.txRate, 8_000)
    }

    // MARK: - 不泄漏

    /// 进程退出后就不再出现在快照里，台账里的两张表也得跟着清，否则只涨不落
    func testStateDoesNotGrowForVanishedProcesses() {
        var ledger = MenuBarRowLedger()
        for step in 0..<50 {
            _ = ledger.update(with: [row("p\(step)", rx: 1_000)], now: t0 + Double(step))
        }
        // 最后一帧只剩一个进程，历史上的 49 个都已退出
        let out = ledger.update(with: [row("p49", rx: 1_000)], now: t0 + 50)
        XCTAssertEqual(out.count, 1, "已退出的进程还留在台账里")
    }
}
