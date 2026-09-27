import XCTest
@testable import TrafficMonitor

// ============================================================
// MARK: - NStatCollector 集成测试（真实内核接口）
// ============================================================

final class NStatCollectorIntegrationTests: XCTestCase {
    func testIsAvailable() throws {
        guard NStatCollector.isAvailable else {
            throw XCTSkip("NetworkStatistics 框架不可用")
        }
        XCTAssertNotNil(NStatCollector())
    }

    /// 首帧应被标成 baseline，且带出当前有流量的进程
    func testFirstFrameIsBaseline() async throws {
        guard NStatCollector.isAvailable, let collector = NStatCollector() else {
            throw XCTSkip("NetworkStatistics 框架不可用")
        }
        defer { collector.stop() }

        var iterator = collector.start(interval: 1.0).makeAsyncIterator()
        guard let first = await iterator.next() else {
            throw XCTSkip("无首帧数据")
        }

        XCTAssertTrue(first.isBaseline)
        // 极安静的机器（例如空闲的 CI runner）可能一条活跃连接都没有
        try XCTSkipIf(first.deltas.isEmpty, "本机当前无网络活动")
        for d in first.deltas {
            XCTAssertGreaterThan(d.pid, 0)
            XCTAssertFalse(d.execName.isEmpty)
            XCTAssertGreaterThanOrEqual(d.bytesIn, 0)
            XCTAssertGreaterThanOrEqual(d.bytesOut, 0)
            XCTAssertGreaterThan(d.bytesIn + d.bytesOut, 0, "零增量应已被过滤")
        }
    }

    /// 后续帧是纯增量：非负，且带上真实的时间间隔
    func testSubsequentFrameIsDeltaWithInterval() async throws {
        guard NStatCollector.isAvailable, let collector = NStatCollector() else {
            throw XCTSkip("NetworkStatistics 框架不可用")
        }
        defer { collector.stop() }

        var iterator = collector.start(interval: 1.0).makeAsyncIterator()
        guard await iterator.next() != nil, let second = await iterator.next() else {
            throw XCTSkip("帧数不足")
        }

        XCTAssertFalse(second.isBaseline)
        XCTAssertGreaterThan(second.interval, 0)
        XCTAssertLessThan(second.interval, 10, "间隔应接近采样周期")
        for d in second.deltas {
            XCTAssertGreaterThanOrEqual(d.bytesIn, 0, "PID \(d.pid) 出现负增量")
            XCTAssertGreaterThanOrEqual(d.bytesOut, 0, "PID \(d.pid) 出现负增量")
        }
    }

    /// 停止后流应结束，不再产出帧
    func testStopFinishesStream() async throws {
        guard NStatCollector.isAvailable, let collector = NStatCollector() else {
            throw XCTSkip("NetworkStatistics 框架不可用")
        }
        var iterator = collector.start(interval: 1.0).makeAsyncIterator()
        _ = await iterator.next()
        collector.stop()
        let afterStop = await iterator.next()
        XCTAssertNil(afterStop, "stop() 后流应结束")
    }
}
