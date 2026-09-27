import XCTest
@testable import TrafficMonitor

/// `SourceLedger` 单元测试
///
/// 这是重构后差值计算的唯一落点：按「每条连接」而不是「每个 PID」相减。
final class SourceLedgerTests: XCTestCase {
    private func frame(_ ledger: inout SourceLedger) -> [PIDDelta] {
        var out: [PIDDelta] = []
        ledger.endFrame(into: &out)
        return out.sorted { $0.pid < $1.pid }
    }

    func testFirstSightOfSourceCountsCumulative() {
        var l = SourceLedger()
        l.beginFrame()
        l.record(source: 1, pid: 100, name: "Chrome", rx: 500, tx: 300)
        let out = frame(&l)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].bytesIn, 500)
        XCTAssertEqual(out[0].bytesOut, 300)
    }

    func testSecondFrameSubtracts() {
        var l = SourceLedger()
        l.beginFrame()
        l.record(source: 1, pid: 100, name: "Chrome", rx: 500, tx: 300)
        _ = frame(&l)

        l.beginFrame()
        l.record(source: 1, pid: 100, name: nil, rx: 1200, tx: 900)
        let out = frame(&l)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].bytesIn, 700)
        XCTAssertEqual(out[0].bytesOut, 600)
        XCTAssertEqual(out[0].execName, "Chrome", "名字应沿用首次记录的值")
    }

    func testMultipleSourcesOfSamePIDAreSummed() {
        var l = SourceLedger()
        l.beginFrame()
        l.record(source: 1, pid: 100, name: "Chrome", rx: 100, tx: 10)
        l.record(source: 2, pid: 100, name: nil, rx: 200, tx: 20)
        l.record(source: 3, pid: 100, name: nil, rx: 300, tx: 30)
        let out = frame(&l)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].bytesIn, 600)
        XCTAssertEqual(out[0].bytesOut, 60)
    }

    func testZeroDeltaIsFiltered() {
        var l = SourceLedger()
        l.beginFrame()
        l.record(source: 1, pid: 100, name: "Chrome", rx: 500, tx: 300)
        _ = frame(&l)

        l.beginFrame()
        l.record(source: 1, pid: 100, name: nil, rx: 500, tx: 300)
        XCTAssertTrue(frame(&l).isEmpty)
    }

    func testCounterRegressionClampedToZero() {
        var l = SourceLedger()
        l.beginFrame()
        l.record(source: 1, pid: 100, name: "Chrome", rx: 5000, tx: 3000)
        _ = frame(&l)

        l.beginFrame()
        l.record(source: 1, pid: 100, name: nil, rx: 100, tx: 50)
        XCTAssertTrue(frame(&l).isEmpty, "累计值回退不应产生负增量")
    }

    func testRemovedSourceStopsContributing() {
        var l = SourceLedger()
        l.beginFrame()
        l.record(source: 1, pid: 100, name: "Chrome", rx: 500, tx: 0)
        _ = frame(&l)
        XCTAssertEqual(l.sourceCount, 1)

        l.remove(source: 1)
        XCTAssertEqual(l.sourceCount, 0)

        l.beginFrame()
        XCTAssertTrue(frame(&l).isEmpty)
    }

    /// PID 复用：同一个 source key 换了 PID → 按新连接处理，不做跨进程相减
    func testPIDReuseOnSameSourceKeyDoesNotSubtractAcrossProcesses() {
        var l = SourceLedger()
        l.beginFrame()
        l.record(source: 1, pid: 100, name: "old", rx: 9000, tx: 9000)
        _ = frame(&l)

        l.beginFrame()
        l.record(source: 1, pid: 200, name: "new", rx: 50, tx: 20)
        let out = frame(&l)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].pid, 200)
        XCTAssertEqual(out[0].bytesIn, 50, "换了 PID 应按新连接的累计值计入，而不是相减为 0")
    }

    func testExcludedProcessesFiltered() {
        var l = SourceLedger()
        l.beginFrame()
        for (i, name) in Constants.alwaysExcludedProcesses.enumerated() {
            l.record(source: UInt(i + 1), pid: Int32(i + 1), name: name, rx: 1000, tx: 1000)
        }
        XCTAssertTrue(frame(&l).isEmpty)
    }

    func testUnnamedPIDIsFiltered() {
        var l = SourceLedger()
        l.beginFrame()
        l.record(source: 1, pid: 100, name: nil, rx: 500, tx: 0)   // 从未提供过名字
        XCTAssertTrue(frame(&l).isEmpty)
    }

    func testResetClearsEverything() {
        var l = SourceLedger()
        l.beginFrame()
        l.record(source: 1, pid: 100, name: "Chrome", rx: 500, tx: 300)
        _ = frame(&l)
        l.reset()
        XCTAssertEqual(l.sourceCount, 0)

        l.beginFrame()
        l.record(source: 1, pid: 100, name: "Chrome", rx: 500, tx: 300)
        let out = frame(&l)
        XCTAssertEqual(out[0].bytesIn, 500, "reset 后应重新建立基线")
    }

    func testOutputBufferIsReused() {
        var l = SourceLedger()
        var out: [PIDDelta] = []
        l.beginFrame()
        l.record(source: 1, pid: 100, name: "Chrome", rx: 500, tx: 300)
        l.endFrame(into: &out)
        XCTAssertEqual(out.count, 1)

        l.beginFrame()
        l.endFrame(into: &out)
        XCTAssertTrue(out.isEmpty, "endFrame 必须先清空上一帧内容")
    }
}
