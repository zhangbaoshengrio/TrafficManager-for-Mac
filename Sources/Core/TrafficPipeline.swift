import Foundation
import UserNotifications

/// 每进程的累计统计
struct ProcessStats {
    var identity: ProcessIdentifier
    var icon: String
    /// 已落库的历史累计
    var historicalIn: Int64 = 0
    var historicalOut: Int64 = 0

    /// 尚未落库的实时累计
    var liveIn: Int64 = 0
    var liveOut: Int64 = 0
    /// 最近一帧的瞬时速率
    var rxRate: Double = 0
    var txRate: Double = 0
    var sampleCount: Int = 0
    /// 最近若干帧的总速率（sparkline 用）。功能关闭时始终为空，不占内存。
    var history: [Double] = []

    var totalIn: Int64 { historicalIn + liveIn }
    var totalOut: Int64 { historicalOut + liveOut }
    var totalBytes: Int64 { totalIn + totalOut }
}

/// 采集管线：帧 → 身份解析 → 聚合 → 内存统计 → 分桶落库 → UI 快照
///
/// 整条链路都在这个 actor 上跑，**不占用主线程**。
/// 旧实现把 `DeltaCalculator` / `ProcessAggregator`（含 libproc 与 LaunchServices 调用）
/// 放在 `@MainActor` 的 `processSnapshot` 里，等于让主线程做 syscall。
actor TrafficPipeline {
    static let shared = TrafficPipeline()

    // MARK: 状态

    private var stats: [String: ProcessStats] = [:]
    private var resolver = ProcessIdentityResolver()

    /// 一个进程在一个落库桶里的聚合
    private struct BucketSlot {
        var bytesIn: Int64 = 0
        var bytesOut: Int64 = 0
        /// 桶内见过的最高瞬时速率（B/s）。桶会把突发摊平，峰值单独留下来。
        var peakIn: Double = 0
        var peakOut: Double = 0
    }

    /// 待落库的时间桶：bucketStart → processKey → 增量
    private var buckets: [TimeInterval: [String: BucketSlot]] = [:]

    /// 当前统计窗口 `[windowStart, windowEnd)`，由 `reloadHistorical` 装载。
    /// 默认 `0 ... .infinity`，即不裁剪（还没装载窗口时的兜底）。
    private var windowStart: TimeInterval = 0
    private var windowEnd: TimeInterval = .infinity
    /// 有帧越过窗口终点 → 窗口过期，等 `CollectorService` 重查数据库
    private var windowRefreshNeeded = false
    /// 桶里已聚合但还没写库的行数（用于日志/诊断）
    private(set) var pendingRowCount = 0

    /// 用户手动排除的进程（小写）。与 `Constants.alwaysExcludedProcesses` 的区别是：
    /// 后者在 `SourceLedger` 里按可执行名过滤，这里还能匹配本地化展示名
    /// （用户看到的是「微信」，未必知道进程名叫 WeChat）。
    private var excludedProcesses: Set<String> = []

    /// 行内 sparkline 开关。关闭时完全不维护历史缓冲 ——
    /// 默认关闭，因为每行多一张图会把好不容易压下去的渲染成本吃回去一部分。
    private var sparklineEnabled = false

    private var alertRules: [AlertRule] = []
    private var alertThrottle: [String: Date] = [:]
    private let alertThrottleInterval: TimeInterval = 60

    /// UI 推送节流：窗口不可见时完全不生成快照，采集与落库照常
    private var uiVisible = true
    private var lastPushedAt = Date.distantPast

    private init() {}

    // MARK: - 生命周期

    /// 用数据库里某个时间窗的汇总替换「历史」部分。
    ///
    /// 启动时调一次，之后每次切换时间范围再调一次 —— 所以必须是幂等的替换，
    /// 而不是累加。
    ///
    /// - Parameters:
    ///   - summaries: 该时间窗内已落库的汇总
    ///   - since / until: 窗口边界（epoch 秒，左闭右开）。两者都参与裁剪：
    ///     越过 `until` 的帧会把窗口标记为过期（`takeWindowRefreshRequest()`），
    ///     由 `CollectorService` 重查数据库换到新的一天/一周/一月。
    ///
    /// 账目关系：
    /// - `historical` = 该时间窗内已落库的字节
    /// - `live` = 该时间窗内尚未落库的字节（`flush()` 会把它转进 historical）
    /// - `total = historical + live`，两边不重不漏
    ///
    /// 窗口变化后，原来有数据、新窗口里没有的进程，其 historical 要清零，
    /// 否则会把窗口外的流量留在总数里。已解析过的身份（含图标路径）保留不动。
    func reloadHistorical(_ summaries: [ProcessSummary],
                          since: TimeInterval = 0,
                          until: TimeInterval = .infinity) {
        windowStart = since
        windowEnd = until
        windowRefreshNeeded = false

        var remaining = Set(stats.keys)

        for h in summaries {
            remaining.remove(h.processKey)
            if var s = stats[h.processKey] {
                s.historicalIn = h.totalIn
                s.historicalOut = h.totalOut
                s.sampleCount = h.sampleCount
                stats[h.processKey] = s
            } else {
                let identity = ProcessIdentifier(
                    bundleId: h.bundleId,
                    execName: h.processKey,
                    displayName: h.displayName
                )
                stats[h.processKey] = ProcessStats(
                    identity: identity,
                    icon: IconCatalog.icon(for: h.displayName),
                    historicalIn: h.totalIn,
                    historicalOut: h.totalOut,
                    sampleCount: h.sampleCount
                )
            }
        }

        // `live` 是内存桶的镜像，按新窗口重算 —— 窗口外的桶（跨零点时那个 23:59）
        // 不能再算进去，否则「今日」会带上昨天最后一分钟的流量，而且一直带着。
        // 放在历史替换之后：上面新建的条目同样要拿到自己未落库的那部分。
        recomputeLiveFromBuckets()

        for key in remaining {
            guard var s = stats[key] else { continue }
            s.historicalIn = 0
            s.historicalOut = 0
            stats[key] = s
            // 窗口内既无历史也无实时数据的进程直接移出列表
            if s.liveIn == 0, s.liveOut == 0, s.rxRate == 0, s.txRate == 0 {
                stats.removeValue(forKey: key)
            }
        }

        lastPushedAt = .distantPast   // 让下一帧立刻把新窗口的数字推给 UI
    }

    /// 按当前窗口重算 `live`：内存桶的镜像只保留窗口内的那部分。
    ///
    /// 窗口外的桶照常落库（以后切到更大的窗口还要查它们），只是不属于当前窗口。
    private func recomputeLiveFromBuckets() {
        for key in Array(stats.keys) {
            stats[key]?.liveIn = 0
            stats[key]?.liveOut = 0
        }
        for (bucket, slot) in buckets where bucket >= windowStart {
            for (key, v) in slot {
                guard var s = stats[key] else { continue }
                s.liveIn += v.bytesIn
                s.liveOut += v.bytesOut
                stats[key] = s
            }
        }
    }

    /// 取走「窗口已过期」标记（取一次即清零）。
    /// 采集循环靠它知道该重查数据库了。
    func takeWindowRefreshRequest() -> Bool {
        defer { windowRefreshNeeded = false }
        return windowRefreshNeeded
    }

    func setAlertRules(_ rules: [AlertRule]) { alertRules = rules }

    func setSparklineEnabled(_ enabled: Bool) {
        guard enabled != sparklineEnabled else { return }
        sparklineEnabled = enabled
        if !enabled {
            for key in stats.keys { stats[key]?.history = [] }
        }
        lastPushedAt = .distantPast
    }

    /// 设置排除列表，并把已经累计的数据清出去（否则改完设置得重启才生效）
    func setExcludedProcesses(_ names: Set<String>) {
        excludedProcesses = names
        guard !names.isEmpty else { return }
        for (key, s) in stats where isExcluded(s.identity) {
            stats.removeValue(forKey: key)
            for bucket in buckets.keys { buckets[bucket]?.removeValue(forKey: key) }
        }
        lastPushedAt = .distantPast
    }

    private func isExcluded(_ identity: ProcessIdentifier) -> Bool {
        guard !excludedProcesses.isEmpty else { return false }
        return excludedProcesses.contains(identity.execName.lowercased())
            || excludedProcesses.contains(identity.displayName.lowercased())
    }

    func reset() {
        stats.removeAll()
        buckets.removeAll()
        pendingRowCount = 0
        windowStart = 0
        windowEnd = .infinity
        windowRefreshNeeded = false
        alertThrottle.removeAll()
        resolver.reset()
    }

    // MARK: - 摄入一帧

    /// 处理一帧采集数据。
    ///
    /// - Returns: 需要推送给 UI 的快照；不到刷新节拍或窗口不可见时返回 nil。
    ///   这样主线程在多数帧上**完全不被唤醒**。
    func ingest(_ frame: TrafficFrame) async -> DashboardSnapshot? {
        // 帧越过窗口终点（跨零点 / 跨周 / 跨月）→ 当前窗口已过期，标记待重载。
        // 这里只打标记：ingest 在采集主链路上，查库会把它变成一次磁盘 IO。
        if frame.timestamp.timeIntervalSince1970 >= windowEnd {
            windowRefreshNeeded = true
        }

        // 首帧的「增量」是各连接自建立以来的累计值，只用来建立基线和活跃进程集合
        guard !frame.isBaseline else {
            for d in frame.deltas {
                let identity = resolver.identity(pid: d.pid, execName: d.execName)
                guard !isExcluded(identity) else { continue }
                if stats[identity.key] == nil {
                    stats[identity.key] = ProcessStats(
                        identity: identity,
                        icon: IconCatalog.icon(for: identity.displayName)
                    )
                }
            }
            return pushIfDue(at: frame.timestamp)
        }

        // 上一帧还活跃、这一帧没数据的进程，速率归零
        var touched = Set<String>()
        touched.reserveCapacity(frame.deltas.count)

        let interval = max(frame.interval, Constants.minRateInterval)
        let bucket = (frame.timestamp.timeIntervalSince1970 / Constants.storageBucketSeconds)
            .rounded(.down) * Constants.storageBucketSeconds

        var aggregated: [String: (bytesIn: Int64, bytesOut: Int64, identity: ProcessIdentifier)] = [:]
        aggregated.reserveCapacity(frame.deltas.count)

        for d in frame.deltas {
            let identity = resolver.identity(pid: d.pid, execName: d.execName)
            guard !isExcluded(identity) else { continue }
            let key = identity.key
            if let cur = aggregated[key] {
                aggregated[key] = (cur.bytesIn + d.bytesIn, cur.bytesOut + d.bytesOut, cur.identity)
            } else {
                aggregated[key] = (d.bytesIn, d.bytesOut, identity)
            }
        }

        for (key, v) in aggregated {
            touched.insert(key)
            var s = stats[key] ?? ProcessStats(
                identity: v.identity,
                icon: IconCatalog.icon(for: v.identity.displayName)
            )
            // 只累计窗口内的：窗口外照样分桶落库，但不进当前窗口的统计
            if bucket >= windowStart {
                s.liveIn += v.bytesIn
                s.liveOut += v.bytesOut
            }
            let rateIn = Double(v.bytesIn) / interval
            let rateOut = Double(v.bytesOut) / interval
            s.rxRate = rateIn
            s.txRate = rateOut
            s.sampleCount += 1
            if sparklineEnabled { Self.push(s.rxRate + s.txRate, into: &s.history) }
            stats[key] = s

            // 分桶聚合，稍后批量落库。峰值取桶内最大 —— 这一帧的瞬时速率
            // 就是一分钟里真实发生过的速率，落库后仍然拿得回来。
            if buckets[bucket]?[key] == nil { pendingRowCount += 1 }
            var slot = buckets[bucket] ?? [:]
            var cell = slot[key] ?? BucketSlot()
            cell.bytesIn += v.bytesIn
            cell.bytesOut += v.bytesOut
            cell.peakIn = max(cell.peakIn, rateIn)
            cell.peakOut = max(cell.peakOut, rateOut)
            slot[key] = cell
            buckets[bucket] = slot
        }

        // 未出现在本帧的进程速率清零（否则表格会一直显示上一次的速率）
        for (key, var s) in stats where !touched.contains(key) {
            guard s.rxRate != 0 || s.txRate != 0 || !s.history.isEmpty else { continue }
            s.rxRate = 0
            s.txRate = 0
            if sparklineEnabled { Self.push(0, into: &s.history) }
            stats[key] = s
        }

        await checkAlerts(aggregated, interval: interval)
        return pushIfDue(at: frame.timestamp)
    }

    // MARK: - UI 推送节流

    func setUIVisible(_ visible: Bool) {
        uiVisible = visible
        if visible { lastPushedAt = .distantPast }   // 重新可见时立刻补一帧
    }

    private func pushIfDue(at now: Date) -> DashboardSnapshot? {
        guard uiVisible else { return nil }
        guard now.timeIntervalSince(lastPushedAt) >= Constants.uiRefreshInterval else { return nil }
        lastPushedAt = now
        return makeSnapshot()
    }

    /// 定长环形缓冲。用 `removeFirst()` 而不是真环形是因为长度只有几十，
    /// 这点搬移成本远低于维护读写指针的复杂度。
    private static func push(_ value: Double, into history: inout [Double]) {
        history.append(value)
        if history.count > Constants.sparklineSampleCount {
            history.removeFirst(history.count - Constants.sparklineSampleCount)
        }
    }

    // MARK: - UI 快照

    func makeSnapshot() -> DashboardSnapshot {
        var rows: [ProcessRow] = []
        rows.reserveCapacity(stats.count)
        var rx = 0.0, tx = 0.0, totalIn: Int64 = 0, totalOut: Int64 = 0

        for (key, s) in stats {
            rx += s.rxRate
            tx += s.txRate
            totalIn += s.totalIn
            totalOut += s.totalOut
            rows.append(ProcessRow(
                key: key,
                bundleId: s.identity.bundleId,
                displayName: s.identity.displayName,
                icon: s.icon,
                iconPath: s.identity.iconPath,
                totalIn: s.totalIn,
                totalOut: s.totalOut,
                rxRate: s.rxRate,
                txRate: s.txRate,
                spark: s.history
            ))
        }
        rows.sort { $0.totalBytes > $1.totalBytes }
        return DashboardSnapshot(rows: rows, totalRxRate: rx, totalTxRate: tx, totalIn: totalIn, totalOut: totalOut)
    }

    // MARK: - 落库

    /// 把已经封口的时间桶批量写库（当前正在累加的桶保留）
    ///
    /// - Parameter force: 停止采集时传 true，连当前桶一起写出
    func flush(force: Bool = false) async {
        guard !buckets.isEmpty else { return }

        let now = Date().timeIntervalSince1970
        let currentBucket = (now / Constants.storageBucketSeconds)
            .rounded(.down) * Constants.storageBucketSeconds

        let ready = buckets.keys.filter { force || $0 < currentBucket }
        guard !ready.isEmpty else { return }

        var events: [TrafficEvent] = []
        for bucket in ready {
            guard let slot = buckets[bucket] else { continue }
            for (key, v) in slot {
                let s = stats[key]
                events.append(TrafficEvent(
                    id: nil,
                    timestamp: bucket,
                    interval: Constants.storageBucketSeconds,
                    processKey: key,
                    bundleId: s?.identity.bundleId,
                    displayName: s?.identity.displayName ?? key,
                    bytesIn: v.bytesIn,
                    bytesOut: v.bytesOut,
                    peakIn: v.peakIn,
                    peakOut: v.peakOut
                ))
            }
        }
        guard !events.isEmpty else { return }

        do {
            try await DataStore.shared.insertEvents(events)
        } catch {
            await LogStore.shared.log("Batch insert failed: \(error)", level: .error, tag: "Pipeline")
            return  // 桶保留，下次重试
        }

        for bucket in ready { buckets.removeValue(forKey: bucket) }
        pendingRowCount = max(0, pendingRowCount - events.count)

        // 已落库的部分从 live 转入 historical（只算窗口内的：窗口外的桶照常写库，
        // 但不属于当前窗口，转进来的话「今日」就又会带上昨天那部分）
        for e in events where e.timestamp >= windowStart {
            guard var s = stats[e.processKey] else { continue }
            s.historicalIn += e.bytesIn
            s.historicalOut += e.bytesOut
            s.liveIn = max(0, s.liveIn - e.bytesIn)
            s.liveOut = max(0, s.liveOut - e.bytesOut)
            stats[e.processKey] = s
        }
    }

    // MARK: - 告警

    private func checkAlerts(
        _ aggregated: [String: (bytesIn: Int64, bytesOut: Int64, identity: ProcessIdentifier)],
        interval: TimeInterval
    ) async {
        let enabled = alertRules.filter(\.enabled)
        guard !enabled.isEmpty, !aggregated.isEmpty else { return }

        let now = Date()
        for (key, v) in aggregated {
            let delta = ProcessDelta(
                identifier: v.identity,
                bytesIn: v.bytesIn,
                bytesOut: v.bytesOut,
                interval: interval
            )
            for rule in enabled where rule.isTriggered(by: delta) {
                let throttleKey = rule.id.uuidString + "_" + key
                if let last = alertThrottle[throttleKey],
                   now.timeIntervalSince(last) < alertThrottleInterval { continue }
                alertThrottle[throttleKey] = now
                await postAlert(rule: rule, delta: delta)
            }
        }
    }

    private func postAlert(rule: AlertRule, delta: ProcessDelta) async {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let body: String
        let triggerValue: Double
        if let tb = rule.thresholdBytes {
            body = L("alerts.notification.bytes", delta.identifier.displayName,
                     ByteFormatter.string(bytes: delta.totalBytes), ByteFormatter.string(bytes: tb))
            triggerValue = Double(delta.totalBytes)
        } else if let tr = rule.thresholdRate {
            body = L("alerts.notification.rate", delta.identifier.displayName,
                     ByteFormatter.rateString(bytesPerSecond: delta.totalRate),
                     ByteFormatter.rateString(bytesPerSecond: tr))
            triggerValue = delta.totalRate
        } else { return }

        // UNUserNotificationCenter 在 XCTest 宿主进程里不是合法的通知发送方，
        // 调用 `.current()` 会在框架自己的单例初始化里直接抛一个未捕获的
        // NSException 崩掉整个测试进程——这是 ObjC 异常，不是 Swift Error，
        // try?/do-catch 都接不住，只能事先避免调用。
        // `XCTestConfigurationFilePath` 只有 Xcode 的测试宿主会设置，`swift test`
        // 走的是 SwiftPM 自己的测试宿主，不会设置它；用「XCTestCase 这个类有没有
        // 被加载进当前进程」判断，跟具体用什么方式跑测试无关，更可靠。
        if NSClassFromString("XCTestCase") == nil {
            let content = UNMutableNotificationContent()
            content.title = L("alerts.notification.title")
            content.body = body
            content.sound = .default
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            )
        }

        // 跟通知一样是"发出去就不管"：写历史记录失败不该影响告警本身的投递。
        try? await DataStore.shared.insertAlertEvent(AlertEvent(
            id: nil, timestamp: Date().timeIntervalSince1970,
            ruleId: rule.id.uuidString, displayName: body, triggerValue: triggerValue
        ))
    }
}

// MARK: - 图标

/// 进程名 → SF Symbol
///
/// 结果在进程首次出现时算一次并存进 `ProcessStats`，不再每次重建列表都跑一遍。
enum IconCatalog {
    static func icon(for name: String) -> String {
        let l = name.lowercased()
        if l.contains("chrome") || l.contains("edge") { return "globe" }
        if l.contains("safari")  { return "safari" }
        if l.contains("firefox") { return "flame" }
        if l.contains("code")    { return "chevron.left.forwardslash.chevron.right" }
        if l.contains("wechat")  { return "message" }
        if l.contains("telegram") { return "paperplane" }
        if l.contains("slack")   { return "number" }
        if l.contains("discord") { return "headphones" }
        if l.contains("zoom")    { return "video" }
        if l.contains("spotify") { return "music.note" }
        if l.contains("mail")    { return "envelope" }
        if l.contains("terminal") || l.contains("iterm") { return "terminal" }
        if l.contains("shadowrocket") || l.contains("surge") || l.contains("clash") { return "arrow.triangle.swap" }
        return "app.dashed"
    }
}
