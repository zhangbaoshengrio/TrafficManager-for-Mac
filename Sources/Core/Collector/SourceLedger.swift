import Foundation

/// 每条连接（NStat source）的累计值台账，负责把「累计」折算成「每帧增量」。
///
/// 为什么按 source 相减而不是按 PID 相减：
/// - source 的累计值从连接建立时开始，天然单调递增；连接关闭即被内核移除，
///   不存在「计数器回退」，因此不需要 knownPIDs / 上限钳制之类的启发式。
/// - PID 复用、进程退出都被 source 生命周期自然覆盖。
/// - 中途新建的连接，其累计值就是这段间隔内的真实流量，可以直接计入。
///
/// 性能约束：`record` 每帧要被调用几百次（每条活跃连接一次），因此
/// - 不做任何字符串桥接（进程名只在该 PID 首次出现时取一次，见 `needsName`）
/// - 帧缓冲用 `removeAll(keepingCapacity:)` 复用，不每帧重建字典
///
/// 纯值语义、无框架依赖，可单元测试。非线程安全 —— 只在采集串行队列上使用。
struct SourceLedger {
    private struct SourceState {
        var pid: Int32
        var rx: Int64
        var tx: Int64
    }

    /// key = source 指针地址
    private var sources: [UInt: SourceState] = [:]
    /// pid → 可执行名（每个 PID 只桥接一次字符串）
    private var names: [Int32: String] = [:]
    /// 复用的每帧聚合缓冲
    private var frame: [Int32: (rx: Int64, tx: Int64)] = [:]

    var sourceCount: Int { sources.count }

    /// 该 PID 是否还没有名字 —— 调用方据此决定是否要从字典里取 `processName`
    func needsName(for pid: Int32) -> Bool { names[pid] == nil }

    /// 开始新的一帧
    mutating func beginFrame() {
        frame.removeAll(keepingCapacity: true)
    }

    /// 记录一条 source 的最新累计值，并把增量累加进当前帧
    ///
    /// - Parameter name: 仅当 `needsName(for:)` 为真时才需要传，其余情况传 nil
    mutating func record(source: UInt, pid: Int32, name: String?, rx: Int64, tx: Int64) {
        if let name, !name.isEmpty, names[pid] == nil { names[pid] = name }

        let dRx: Int64
        let dTx: Int64
        if let prev = sources[source], prev.pid == pid {
            dRx = max(0, rx - prev.rx)
            dTx = max(0, tx - prev.tx)
        } else {
            // 首次见到这条连接：累计值即为本间隔内产生的流量
            dRx = rx
            dTx = tx
        }
        sources[source] = SourceState(pid: pid, rx: rx, tx: tx)

        guard dRx > 0 || dTx > 0 else { return }
        if let cur = frame[pid] {
            frame[pid] = (cur.rx + dRx, cur.tx + dTx)
        } else {
            frame[pid] = (dRx, dTx)
        }
    }

    /// 连接关闭
    mutating func remove(source: UInt) {
        sources.removeValue(forKey: source)
    }

    /// 收尾当前帧，把每进程增量写入 `out`（复用其容量）
    mutating func endFrame(into out: inout [PIDDelta]) {
        out.removeAll(keepingCapacity: true)
        out.reserveCapacity(frame.count)
        for (pid, v) in frame {
            guard let name = names[pid], !name.isEmpty else { continue }
            guard !Constants.alwaysExcludedProcesses.contains(name) else { continue }
            out.append(PIDDelta(pid: pid, execName: name, bytesIn: v.rx, bytesOut: v.tx))
        }
        if names.count > Constants.maxTrackedProcessNames { compactNames() }
    }

    mutating func reset() {
        sources.removeAll(keepingCapacity: false)
        names.removeAll(keepingCapacity: false)
        frame.removeAll(keepingCapacity: false)
    }

    /// 丢弃已无任何连接的 PID 名字
    private mutating func compactNames() {
        var live = Set<Int32>()
        live.reserveCapacity(sources.count)
        for s in sources.values { live.insert(s.pid) }
        names = names.filter { live.contains($0.key) }
    }
}
