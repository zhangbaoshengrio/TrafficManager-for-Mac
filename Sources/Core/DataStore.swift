import Foundation
import GRDB

/// 数据存储层（GRDB 封装）
///
/// 单例，负责 SQLite 初始化、写入流量事件、查询统计数据。
actor DataStore {
    static let shared = DataStore()

    private var dbWriter: DatabaseWriter?
    private var isSetup = false
    private var currentDBPath: String?

    init() {}

    // MARK: - Setup

    /// 初始化数据库（首次使用时调用，后续调用无副作用）
    func setup() throws {
        try setup(at: Constants.databaseURL)
    }

    /// 使用自定义路径初始化数据库（用于测试或自定义部署）
    func setup(at dbURL: URL) throws {
        guard !isSetup else { return }
        isSetup = true
        currentDBPath = dbURL.path

        // 确保目录存在
        try FileManager.default.createDirectory(
            at: dbURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        print("[DataStore] Opening database at \(dbURL.path)")

        let writer = try DatabasePool(path: dbURL.path)

        // 创建表
        try writer.write { db in
            try db.create(table: "trafficEvent", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp", .double).notNull().indexed()
                t.column("interval", .double).notNull()
                t.column("processKey", .text).notNull().indexed()
                t.column("bundleId", .text)
                t.column("displayName", .text).notNull()
                t.column("bytesIn", .integer).notNull()
                t.column("bytesOut", .integer).notNull()
                t.column("peakIn", .double).notNull().defaults(to: 0)
                t.column("peakOut", .double).notNull().defaults(to: 0)
                t.column("ssid", .text)
            }

            // 复合索引：按时间 + 进程查
            try db.create(index: "idx_traffic_ts_process",
                          on: "trafficEvent",
                          columns: ["timestamp", "processKey"],
                          ifNotExists: true)

            // 迁移：老库补上峰值列。默认 0 = 未知，查询时退回该行自己的
            // `bytes / interval` —— 拿展示桶长度去除会让老数据整体高估。
            let columns = try db.columns(in: "trafficEvent").map(\.name)
            if !columns.contains("peakIn") {
                try db.alter(table: "trafficEvent") { t in
                    t.add(column: "peakIn", .double).notNull().defaults(to: 0)
                    t.add(column: "peakOut", .double).notNull().defaults(to: 0)
                }
            }
            // 迁移：老库补上 ssid 列（可空，老数据统一视为「未知网络」）。
            if !columns.contains("ssid") {
                try db.alter(table: "trafficEvent") { t in
                    t.add(column: "ssid", .text)
                }
            }

            try db.create(table: "alertEvent", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp", .double).notNull().indexed()
                t.column("ruleId", .text).notNull()
                t.column("displayName", .text).notNull()
                t.column("triggerValue", .double).notNull()
            }
        }

        dbWriter = writer
    }

    // MARK: - Write

    /// 批量插入流量事件
    ///
    /// 用单条多值 `INSERT ... VALUES (?,...),(?,...)` 分块写入，
    /// 而不是逐行 `insert`（每行一次 bind + step + 语句复用查找）。
    func insertEvents(_ events: [TrafficEvent]) throws {
        guard let writer = dbWriter, !events.isEmpty else { return }

        try writer.write { db in
            for chunk in stride(from: 0, to: events.count, by: Constants.insertChunkSize) {
                let slice = events[chunk ..< min(chunk + Constants.insertChunkSize, events.count)]
                let placeholders = Array(
                    repeating: "(?,?,?,?,?,?,?,?,?,?)", count: slice.count
                ).joined(separator: ",")
                var args: [DatabaseValueConvertible?] = []
                args.reserveCapacity(slice.count * 10)
                for e in slice {
                    args.append(e.timestamp)
                    args.append(e.interval)
                    args.append(e.processKey)
                    args.append(e.bundleId)
                    args.append(e.displayName)
                    args.append(e.bytesIn)
                    args.append(e.bytesOut)
                    args.append(e.peakIn)
                    args.append(e.peakOut)
                    args.append(e.ssid)
                }
                try db.execute(
                    sql: """
                        INSERT INTO trafficEvent
                        (timestamp, interval, processKey, bundleId, displayName,
                         bytesIn, bytesOut, peakIn, peakOut, ssid)
                        VALUES \(placeholders)
                        """,
                    arguments: StatementArguments(args)
                )
            }
        }
    }

    /// 记一条告警触发事件。告警触发很稀疏（不是每帧都发生），不需要像
    /// `insertEvents` 那样分块批量写。
    func insertAlertEvent(_ event: AlertEvent) throws {
        guard let writer = dbWriter else { return }
        var event = event
        try writer.write { db in
            try event.insert(db)
        }
    }

    /// 查询指定时间范围内触发过的告警，按时间升序 —— 用于在流量图上画 ▲ 标记。
    func queryAlertEvents(
        since: TimeInterval,
        until: TimeInterval = Date().timeIntervalSince1970
    ) throws -> [AlertEvent] {
        guard let writer = dbWriter else { return [] }
        return try writer.read { db in
            try AlertEvent
                .filter(AlertEvent.Columns.timestamp >= since
                        && AlertEvent.Columns.timestamp <= until)
                .order(AlertEvent.Columns.timestamp)
                .fetchAll(db)
        }
    }

    /// 清理超过保留期的明细数据（启动时调用一次）
    func pruneExpired(retentionDays: Double = Constants.retentionDays) throws {
        let cutoff = Date().timeIntervalSince1970 - retentionDays * 86400
        try deleteBefore(cutoff)
    }

    /// 空闲页占比过高时整理数据库文件，把空间还给系统。
    ///
    /// SQLite 删除行只是把页挂到 freelist，文件本身不会缩小 —— 长期运行下
    /// 「删了很多但文件一直很大」。实测某次运行：1531 页里 1159 页是空闲的，
    /// 6 MB 文件只装着 8955 行，**76% 是废弃空间**。
    ///
    /// 不用 `auto_vacuum`：它只能在建库时设定，且会让每次写入都多做页搬移。
    /// 这里改为按需 `VACUUM`，只在浪费确实明显时才做。
    ///
    /// - Returns: 回收的字节数；未达阈值则为 0
    @discardableResult
    func compactIfWasteful(
        minimumFreeRatio: Double = 0.25,
        minimumFreeBytes: Int64 = 1 << 20
    ) throws -> Int64 {
        guard let writer = dbWriter else { return 0 }

        // 先并回 WAL，否则 freelist_count / page_count 反映的是并入前的旧状态
        try checkpoint()

        let (freePages, pageSize) = try writer.read { db -> (Int64, Int64) in
            let free = try Int64.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0
            let total = try Int64.fetchOne(db, sql: "PRAGMA page_count") ?? 0
            let size = try Int64.fetchOne(db, sql: "PRAGMA page_size") ?? 0
            // 总页为 0 时直接跳过，避免除零
            guard total > 0, Double(free) / Double(total) >= minimumFreeRatio else { return (0, size) }
            return (free, size)
        }

        let reclaimable = freePages * pageSize
        guard reclaimable >= minimumFreeBytes else { return 0 }

        let before = databaseSize()
        // VACUUM 要重写整个文件，不能在事务里跑
        try writer.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
        }
        // VACUUM 本身会往 WAL 里写下整个新库。不再 checkpoint 一次的话，
        // 主库虽然缩了（实测 687 页 → 12 页），WAL 却撑大到比原来还多，
        // 「整理完反而变大」。
        try checkpoint()
        return max(0, before - databaseSize())
    }

    // MARK: - Query

    /// 查询指定时间范围内的流量汇总（按进程聚合）
    ///
    /// - Parameters:
    ///   - since: 起始时间戳
    ///   - until: 结束时间戳
    ///   - limit: 最多返回 N 个进程（0 = 不限）
    /// - Returns: 按总流量降序排列的进程统计
    func querySummary(
        since: TimeInterval,
        until: TimeInterval = Date().timeIntervalSince1970,
        limit: Int = 0
    ) throws -> [ProcessSummary] {
        guard let writer = dbWriter else { return [] }

        return try writer.read { db in
            var sql = """
                SELECT processKey,
                       bundleId,
                       displayName,
                       SUM(bytesIn)  AS totalIn,
                       SUM(bytesOut) AS totalOut,
                       COUNT(*)      AS sampleCount,
                       MIN(timestamp) AS firstSeen,
                       MAX(timestamp) AS lastSeen
                FROM trafficEvent
                WHERE timestamp >= ? AND timestamp <= ?
                GROUP BY processKey
                ORDER BY (totalIn + totalOut) DESC
            """
            if limit > 0 {
                sql += " LIMIT \(limit)"
            }

            return try Row.fetchAll(db, sql: sql, arguments: [since, until]).map { row in
                ProcessSummary(
                    processKey: row["processKey"],
                    bundleId: row["bundleId"],
                    displayName: row["displayName"],
                    totalIn: row["totalIn"],
                    totalOut: row["totalOut"],
                    sampleCount: row["sampleCount"],
                    firstSeen: row["firstSeen"],
                    lastSeen: row["lastSeen"]
                )
            }
        }
    }

    /// 查询单个进程的时间线数据（按时间桶聚合）。
    ///
    /// 返回的是**这段时间里监控器确实在采集**的每个桶：
    /// - 该进程有流量 → 真实数值；
    /// - 该进程没流量，但同一分钟别的进程有 → 0（画出来是贴地的线，「确实没传」）；
    /// - 整分钟谁都没有数据（应用关了 / 机器睡了）→ **不返回**。
    ///   上层据此断开线段 —— 否则 07:58 和 14:08 两次突发会被连成一条斜线，
    ///   看起来像这六个小时一直在传。
    func queryTimeline(
        processKey: String,
        since: TimeInterval,
        until: TimeInterval = Date().timeIntervalSince1970,
        bucketSeconds: TimeInterval = 300
    ) throws -> [TimelinePoint] {
        guard let writer = dbWriter else { return [] }

        return try writer.read { db in
            // 有采集的桶：这一分钟里任何一个进程写过行
            let covered = try TimeInterval.fetchSet(
                db,
                sql: """
                    SELECT DISTINCT CAST(timestamp / ? AS INTEGER) * ? AS bucket
                    FROM trafficEvent
                    WHERE timestamp >= ? AND timestamp <= ?
                    """,
                arguments: [bucketSeconds, bucketSeconds, since, until]
            )

            let rows = try Row.fetchAll(db, sql: """
                SELECT CAST(timestamp / ? AS INTEGER) * ? AS bucket,
                       SUM(bytesIn)  AS totalIn,
                       SUM(bytesOut) AS totalOut,
                       -- 峰值逐行取较大的那个（老行没有峰值为 0 → 退回该行自己的
                       -- bytes/interval），再在展示桶里取最大。
                       -- 不能拿展示桶长度去除：换粒度后老行会整体高估。
                       MAX(MAX(peakIn,  bytesIn  / MAX(interval, 0.1))) AS peakIn,
                       MAX(MAX(peakOut, bytesOut / MAX(interval, 0.1))) AS peakOut
                FROM trafficEvent
                WHERE timestamp >= ? AND timestamp <= ? AND processKey = ?
                GROUP BY bucket
                ORDER BY bucket
            """, arguments: [bucketSeconds, bucketSeconds, since, until, processKey])

            var byBucket: [TimeInterval: TimelinePoint] = [:]
            for row in rows {
                let point = TimelinePoint(
                    timestamp: row["bucket"],
                    bytesIn: row["totalIn"],
                    bytesOut: row["totalOut"],
                    peakIn: row["peakIn"],
                    peakOut: row["peakOut"]
                )
                byBucket[point.timestamp] = point
            }

            // 把区间里的每个桶都铺出来：有流量的用真实值，采集在跑但没流量的补 0，
            // 完全没采集的也补 0 但标 isCovered = false（图上画灰带）—— 折线因此连续，
            // 同时不会把「没测到」当成「测到 0」。
            // 从「包含 since 的那个桶」开始铺（floor）：聚合查询用的也是这个桶，
            // 用 ceil 会把 since 所在桶里的数据行挤出网格
            let first = (since / bucketSeconds).rounded(.down) * bucketSeconds
            let last = (until / bucketSeconds).rounded(.down) * bucketSeconds
            guard first <= last else { return [] }

            var points: [TimelinePoint] = []
            points.reserveCapacity(Int((last - first) / bucketSeconds) + 1)
            var bucket = first
            while bucket <= last {
                points.append(byBucket[bucket]
                    ?? TimelinePoint(timestamp: bucket, bytesIn: 0, bytesOut: 0,
                                     isCovered: covered.contains(bucket)))
                bucket += bucketSeconds
            }
            return points
        }
    }

    /// 全部进程合计的时间线（按时间桶聚合），用于主窗口的汇总趋势图。
    ///
    /// 分桶、补洞（`isCovered`）逻辑跟 `queryTimeline` 完全一致，唯一区别是
    /// 不按 `processKey` 过滤/分组 —— 这里的"有没有采集""流量多少"都是
    /// 所有进程的总和。两处查询的补洞逻辑刻意没有抽公共函数：这段 SQL 和
    /// 网格填充逻辑目前只有这两个调用点，提前抽象只会让两边都多绕一层。
    func queryAggregateTimeline(
        since: TimeInterval,
        until: TimeInterval = Date().timeIntervalSince1970,
        bucketSeconds: TimeInterval = 300
    ) throws -> [TimelinePoint] {
        guard let writer = dbWriter else { return [] }

        return try writer.read { db in
            let covered = try TimeInterval.fetchSet(
                db,
                sql: """
                    SELECT DISTINCT CAST(timestamp / ? AS INTEGER) * ? AS bucket
                    FROM trafficEvent
                    WHERE timestamp >= ? AND timestamp <= ?
                    """,
                arguments: [bucketSeconds, bucketSeconds, since, until]
            )

            let rows = try Row.fetchAll(db, sql: """
                SELECT CAST(timestamp / ? AS INTEGER) * ? AS bucket,
                       SUM(bytesIn)  AS totalIn,
                       SUM(bytesOut) AS totalOut,
                       MAX(MAX(peakIn,  bytesIn  / MAX(interval, 0.1))) AS peakIn,
                       MAX(MAX(peakOut, bytesOut / MAX(interval, 0.1))) AS peakOut
                FROM trafficEvent
                WHERE timestamp >= ? AND timestamp <= ?
                GROUP BY bucket
                ORDER BY bucket
            """, arguments: [bucketSeconds, bucketSeconds, since, until])

            var byBucket: [TimeInterval: TimelinePoint] = [:]
            for row in rows {
                let point = TimelinePoint(
                    timestamp: row["bucket"],
                    bytesIn: row["totalIn"],
                    bytesOut: row["totalOut"],
                    peakIn: row["peakIn"],
                    peakOut: row["peakOut"]
                )
                byBucket[point.timestamp] = point
            }

            let first = (since / bucketSeconds).rounded(.down) * bucketSeconds
            let last = (until / bucketSeconds).rounded(.down) * bucketSeconds
            guard first <= last else { return [] }

            var points: [TimelinePoint] = []
            points.reserveCapacity(Int((last - first) / bucketSeconds) + 1)
            var bucket = first
            while bucket <= last {
                points.append(byBucket[bucket]
                    ?? TimelinePoint(timestamp: bucket, bytesIn: 0, bytesOut: 0,
                                     isCovered: covered.contains(bucket)))
                bucket += bucketSeconds
            }
            return points
        }
    }

    /// 按「本地星期几 × 本地小时」聚合流量，用于热力图视图。
    ///
    /// 不能直接用 SQLite 的 `strftime('%w'/'%H', ts, 'unixepoch')`——那返回的是
    /// UTC 的星期几/小时，用户关心的是自己本地时区的作息规律，不是 UTC。
    /// 所以这里先在 SQL 里按整点粗聚合（便宜、行数少），本地时区的换算放在 Swift 里做。
    func queryHeatmap(
        since: TimeInterval,
        until: TimeInterval = Date().timeIntervalSince1970,
        calendar: Calendar = .current
    ) throws -> [HeatmapCell] {
        guard let writer = dbWriter else { return [] }

        let hourlyRows = try writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT CAST(timestamp / 3600 AS INTEGER) * 3600 AS hourBucket,
                       SUM(bytesIn)  AS totalIn,
                       SUM(bytesOut) AS totalOut
                FROM trafficEvent
                WHERE timestamp >= ? AND timestamp <= ?
                GROUP BY hourBucket
            """, arguments: [since, until])
        }

        var byCell: [String: HeatmapCell] = [:]
        for row in hourlyRows {
            let bucketStart: TimeInterval = row["hourBucket"]
            let date = Date(timeIntervalSince1970: bucketStart)
            // Calendar.weekday 是 1...7（周日=1）；减一换成跟 SQLite %w 一致的 0...6
            let weekday = calendar.component(.weekday, from: date) - 1
            let hour = calendar.component(.hour, from: date)
            let key = "\(weekday)-\(hour)"
            let bytesIn: Int64 = row["totalIn"]
            let bytesOut: Int64 = row["totalOut"]
            if let existing = byCell[key] {
                byCell[key] = HeatmapCell(weekday: weekday, hour: hour,
                                           bytesIn: existing.bytesIn + bytesIn,
                                           bytesOut: existing.bytesOut + bytesOut)
            } else {
                byCell[key] = HeatmapCell(weekday: weekday, hour: hour,
                                           bytesIn: bytesIn, bytesOut: bytesOut)
            }
        }
        return Array(byCell.values)
    }

    /// 获取数据库中的数据时间范围
    func timeRange() throws -> (first: TimeInterval, last: TimeInterval) {
        guard let writer = dbWriter else { return (0, 0) }

        return try writer.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT MIN(timestamp) as first, MAX(timestamp) as last
                FROM trafficEvent
            """)
            return (
                first: row?["first"] ?? 0,
                last: row?["last"] ?? 0
            )
        }
    }

    /// 删除指定时间之前的数据
    func deleteBefore(_ timestamp: TimeInterval) throws {
        guard let writer = dbWriter else { return }

        try writer.write { db in
            try db.execute(
                sql: "DELETE FROM trafficEvent WHERE timestamp < ?",
                arguments: [timestamp]
            )
        }
    }

    /// 数据库文件大小
    /// 数据库占用的磁盘空间。
    ///
    /// **要把 `-wal` 一起算上。** WAL 模式下新写入先落在 write-ahead log 里，
    /// checkpoint 之后才并入主库文件 —— 只看主库文件会严重少报：
    /// 实测刚写完两万行时主库仍是 4096 字节，数据全在 WAL 中。
    func databaseSize() -> Int64 {
        guard let path = currentDBPath else { return 0 }
        return ["", "-wal", "-shm"].reduce(into: Int64(0)) { total, suffix in
            let attributes = try? FileManager.default.attributesOfItem(atPath: path + suffix)
            total += (attributes?[.size] as? Int64) ?? 0
        }
    }

    /// 把 WAL 并回主库，让页统计和文件大小反映真实情况
    func checkpoint() throws {
        guard let writer = dbWriter else { return }
        try writer.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    // MARK: - Testing

    /// 重置状态（仅用于测试）
    func resetForTesting() {
        isSetup = false
        dbWriter = nil
        currentDBPath = nil
    }
}

// MARK: - Query Result Types

/// 进程流量汇总
struct ProcessSummary: Identifiable {
    var id: String { processKey }
    let processKey: String
    let bundleId: String?
    let displayName: String
    let totalIn: Int64
    let totalOut: Int64
    let sampleCount: Int
    let firstSeen: TimeInterval
    let lastSeen: TimeInterval

    var totalBytes: Int64 { totalIn + totalOut }
}

/// 时间线数据点
struct TimelinePoint: Identifiable, Equatable {
    var id: TimeInterval { timestamp }
    let timestamp: TimeInterval
    let bytesIn: Int64
    let bytesOut: Int64
    /// 该展示桶内观测到的最高速率（B/s）。
    /// 老数据没有峰值列，由查询按每行自己的 `interval` 退回。
    var peakIn: Double = 0
    var peakOut: Double = 0
    /// 这个桶里监控器**有没有在采集**（任何一个进程写过行）。
    /// false = 机器休眠 / 应用没在跑，字节数是补出来的 0，图上要标灰带。
    var isCovered: Bool = true

    var totalBytes: Int64 { bytesIn + bytesOut }
}

/// 热力图里的一个格子：某个「本地星期几 + 本地小时」组合的流量合计。
struct HeatmapCell: Identifiable, Equatable {
    var id: String { "\(weekday)-\(hour)" }
    /// 0 = 周日 … 6 = 周六（跟 SQLite `strftime('%w', ...)` 的编号对齐，
    /// 方便跟其它地方的星期几表示互相比较）
    let weekday: Int
    let hour: Int
    let bytesIn: Int64
    let bytesOut: Int64

    var totalBytes: Int64 { bytesIn + bytesOut }
}
