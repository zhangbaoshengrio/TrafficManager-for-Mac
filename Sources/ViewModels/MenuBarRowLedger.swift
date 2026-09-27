import Foundation

/// 菜单栏面板里的一行
struct MenuBarRow: Identifiable, Equatable {
    let row: ProcessRow
    /// 此刻没有流量，只是还在驻留期内。界面据此淡化，避免误读成「正在跑」。
    let isIdle: Bool

    var id: String { row.key }
}

/// 把每帧剧烈抖动的快照，整理成一份**稳定**的菜单栏面板列表。
///
/// ## 为什么需要这一层
///
/// 直接取快照里「速率 > 0」的进程排前几名，实测（真机 40 秒、每 2 秒一帧）：
///
/// ```
/// rows=6 → 5 → 5 → 4 → 6 → 4 → 5 → 5 → 3 → 5 → 4 → 4 → 5 → 6 → 6 → 4 …
/// ```
///
/// 行数在 3~6 之间来回跳，面板高度跟着 149↔203pt 伸缩 —— 而菜单栏面板是
/// 顶边固定、底边浮动的，高度一变窗口原点也跟着上下移（实测 y 在 921↔939 间跳）。
/// 成员和顺序同样几乎每帧重排：edgemac、Chrome、codex、ssh 轮流进出。
/// 用户看到的就是「面板一直在闪」。
///
/// 根子在于**瞬时速率天然是抖的**：一个进程空一帧再回来，是常态而不是异常。
/// 所以稳定必须在展示层做，两条措施：
///
/// - **平滑**：排序键用指数滑动平均而不是瞬时速率。单帧的尖峰或空档不再改变名次。
/// - **驻留**：进程一旦上榜就留在榜上，直到连续 `lingerWindow` 秒没有流量。
///   空档期显示 0 并淡化，而不是整行消失、把下面的行整体顶上来。
///
/// 两条合起来，成员、顺序、行数在正常使用下都不再逐帧变化 ——
/// 面板高度自然也就不动了，不需要靠预留空白去凑。
///
/// 显示的**数字仍然是瞬时速率**，平滑只用于排名。否则用户看到的速率会比实际慢半拍。
struct MenuBarRowLedger {
    /// 面板里最多列几个进程。再多就该开主窗口了。
    static let capacity = 6
    /// 平滑系数：新值占的权重。0.35 大约是三帧的记忆 ——
    /// 足够压掉单帧抖动，又不至于让真正的速率变化迟迟反应不过来。
    static let smoothing = 0.35
    /// 驻留窗口：连续这么久没有流量才把行摘掉。
    /// 取 30 秒是因为实测这个长度下候选进程稳定多于 `capacity`，槽位不会忽满忽缺。
    static let lingerWindow: TimeInterval = 30

    /// 排序用的平滑速率
    private var smoothed: [String: Double] = [:]
    /// 最后一次真正有流量的时刻
    private var lastActive: [String: Date] = [:]

    /// 吃进一帧快照，吐出面板该显示的行。
    ///
    /// - Parameter rows: 快照里的**全部**行（含速率为 0 的），不要预先过滤 ——
    ///   驻留中的行正是靠这些零速率行才能继续拿到累计数据。
    mutating func update(with rows: [ProcessRow], now: Date = Date()) -> [MenuBarRow] {
        var live = Set<String>()
        live.reserveCapacity(rows.count)

        for row in rows {
            live.insert(row.key)
            let rate = row.rxRate + row.txRate
            let previous = smoothed[row.key] ?? 0
            smoothed[row.key] = previous + (rate - previous) * Self.smoothing
            if rate > 0 { lastActive[row.key] = now }
        }

        // 进程退出后就不再出现在快照里。不清理的话这两张表只涨不落。
        if smoothed.count > live.count {
            smoothed = smoothed.filter { live.contains($0.key) }
            lastActive = lastActive.filter { live.contains($0.key) }
        }

        return rows
            .filter { row in
                guard let seen = lastActive[row.key] else { return false }
                return now.timeIntervalSince(seen) <= Self.lingerWindow
            }
            .sorted { lhs, rhs in
                let a = smoothed[lhs.key] ?? 0, b = smoothed[rhs.key] ?? 0
                // 并列时按 key 定序。不加这一手，两行的先后就取决于快照里的顺序，
                // 会每帧互换位置。
                return a == b ? lhs.key < rhs.key : a > b
            }
            .prefix(Self.capacity)
            .map { MenuBarRow(row: $0, isIdle: $0.rxRate + $0.txRate == 0) }
    }
}
