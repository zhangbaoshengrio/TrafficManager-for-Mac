import Foundation

/// 单个 PID 在一帧内的流量增量
///
/// 由 `SourceLedger` 在采集队列上完成「每条连接累计值相减」后产出，
/// 到这里已经是纯增量，下游不再需要任何差值/估算逻辑。
struct PIDDelta: Hashable {
    let pid: Int32
    let execName: String
    let bytesIn: Int64
    let bytesOut: Int64
}

/// 一次采集帧
struct TrafficFrame {
    /// 本帧各进程的增量（已过滤零增量与排除进程）
    let deltas: [PIDDelta]

    /// 采样时刻
    let timestamp: Date

    /// 距上一帧的实际间隔（秒）
    let interval: TimeInterval

    /// 首帧标记
    ///
    /// 首帧里每条连接的「增量」其实是它自建立以来的累计值，不代表这一秒的流量。
    /// 因此首帧只用于建立累计基线和活跃进程集合，不计入流量统计。
    let isBaseline: Bool
}
