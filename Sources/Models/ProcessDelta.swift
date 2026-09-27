import Foundation

/// 单个进程（按 Bundle ID 聚合后）在一帧内的流量增量
///
/// 只用于告警判定和瞬时速率计算；累计统计走 `TrafficPipeline.stats`。
struct ProcessDelta {
    let identifier: ProcessIdentifier
    let bytesIn: Int64
    let bytesOut: Int64
    /// 采集间隔（秒）
    let interval: TimeInterval

    var totalBytes: Int64 { bytesIn + bytesOut }
    var rxRate: Double { Double(bytesIn) / max(interval, Constants.minRateInterval) }
    var txRate: Double { Double(bytesOut) / max(interval, Constants.minRateInterval) }
    var totalRate: Double { rxRate + txRate }
}
