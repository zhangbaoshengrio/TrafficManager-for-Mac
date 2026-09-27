import AppKit
import Foundation

// MARK: - 采集状态

enum CollectorStatus: Equatable {
    case idle
    case running
    case stopped
    case error(String)
}

/// 采集服务：进程生命周期 + 帧消费循环 + UI 可见性
///
/// ```
/// NStatCollector ──AsyncStream(bufferingNewest 1)──▶ TrafficPipeline (actor)
///                                                         │ 节流后
///                                                         ▼
///                                                    snapshotSink → MainActor
/// ```
///
/// 这个类型本身只持有**状态**，不做任何逐帧计算 —— 计算全部在 `TrafficPipeline`
/// 上。同时它用 `@Observable` 而不是 `ObservableObject`：后者的 `objectWillChange`
/// 是对象级通知，一个内部计数器自增就会让所有观察它的视图整树重排。
@Observable
@MainActor
final class CollectorService {
    static let shared = CollectorService()

    private(set) var status: CollectorStatus = .idle

    /// 采集间隔（秒）。写入即落 UserDefaults —— 此前只存在内存里，重启就回默认值。
    var interval: TimeInterval = Preferences.interval {
        didSet {
            guard interval != oldValue else { return }
            Preferences.interval = interval
        }
    }

    /// 落库间隔（秒），同样持久化
    var saveInterval: TimeInterval = Preferences.saveInterval {
        didSet {
            guard saveInterval != oldValue else { return }
            Preferences.saveInterval = saveInterval
        }
    }

    var alertRules: [AlertRule] = []

    /// 界面语言。
    ///
    /// 放在这里是因为它已经是全应用注入的设置载体（菜单栏、趋势图开关都在此）。
    /// 切换时除了改 `L10n` 的查表包，还要让整棵视图树重建 —— `L()` 返回的是
    /// 普通 String，SwiftUI 无从得知它依赖了语言，所以在 App 层用 `.id(language)`
    /// 强制换身份。
    var language: AppLanguage = L10n.stored {
        didSet {
            guard language != oldValue else { return }
            L10n.stored = language
        }
    }

    /// 表格行内显示最近速率的 sparkline（默认关闭）
    var sparklineEnabled: Bool = Preferences.sparklineEnabled {
        didSet {
            guard sparklineEnabled != oldValue else { return }
            Preferences.sparklineEnabled = sparklineEnabled
            let enabled = sparklineEnabled
            Task { await TrafficPipeline.shared.setSparklineEnabled(enabled) }
        }
    }

    /// 菜单栏两行速率的字号。两行必须挤进状态栏的 22pt，所以上限比正文小得多。
    var menuBarFontSize: Double = Preferences.menuBarFontSize {
        didSet {
            guard menuBarFontSize != oldValue else { return }
            Preferences.menuBarFontSize = menuBarFontSize
        }
    }

    /// 菜单栏常驻显示实时速率
    ///
    /// 开启时 UI 可见性闸门必须一直放行 —— 否则主窗口被遮挡后管线停止产出快照，
    /// 菜单栏的数字会冻在最后一帧。
    var menuBarEnabled: Bool = Preferences.menuBarEnabled {
        didSet {
            guard menuBarEnabled != oldValue else { return }
            Preferences.menuBarEnabled = menuBarEnabled
            syncVisibility()
        }
    }

    /// UI 快照出口，由 `DashboardViewModel` 注册
    @ObservationIgnored
    var snapshotSink: (@MainActor (DashboardSnapshot) -> Void)?

    @ObservationIgnored private var collector: NStatCollector?
    @ObservationIgnored private var collectionTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var visibilityObservers: [NSObjectProtocol] = []
    /// 上一次 stop() 的收尾任务，start() 会先等它完成再初始化，
    /// 否则「改设置 → 重启采集」时 reset 可能落在 initialize 之后，把历史累计抹掉
    @ObservationIgnored private var teardownTask: Task<Void, Never>?

    private init() {}

    // MARK: - 生命周期

    func start() async {
        guard status != .running else { return }
        await teardownTask?.value
        teardownTask = nil

        do {
            try await DataStore.shared.setup()
            if Preferences.retentionEnabled {
                try await DataStore.shared.pruneExpired(retentionDays: Preferences.retentionDays)
                let reclaimed = try await DataStore.shared.compactIfWasteful()
                if reclaimed > 0 {
                    await LogStore.shared.log(
                        "Compacted database, reclaimed \(ByteFormatter.string(bytes: reclaimed))",
                        level: .info, tag: "DataStore"
                    )
                }
            }
        } catch {
            await LogStore.shared.log("Database init failed: \(error)", level: .error, tag: "Collector")
            status = .error(L("error.databaseInit"))
            return
        }

        guard let collector = NStatCollector() else {
            await LogStore.shared.log("NetworkStatistics framework unavailable", level: .error, tag: "Collector")
            status = .error(L("error.frameworkUnavailable"))
            return
        }
        self.collector = collector

        // 历史累计先灌进管线，再开始消费实时帧
        await TrafficPipeline.shared.setExcludedProcesses(
            Preferences.parseExcluded(Preferences.excludedProcessesText))
        await TrafficPipeline.shared.setSparklineEnabled(sparklineEnabled)
        await applyTimeRange(Preferences.timeRange)
        await TrafficPipeline.shared.setAlertRules(alertRules)

        // 单次迭代：首帧由管线自己识别为 baseline，无需在这里先消费一帧
        let stream = collector.start(interval: interval)
        runCollectionLoop(stream)
        startSaveLoop()
        startVisibilityMonitoring()

        status = .running
        await LogStore.shared.log(
            "Started (\(interval)s sample / \(Constants.uiRefreshInterval)s refresh / \(saveInterval)s flush)",
            level: .info, tag: "Collector"
        )
    }

    func stop() {
        status = .stopped
        collectionTask?.cancel()
        collectionTask = nil
        saveTask?.cancel()
        saveTask = nil
        stopVisibilityMonitoring()
        collector?.stop()
        collector = nil
        teardownTask = Task {
            await TrafficPipeline.shared.flush(force: true)
            await TrafficPipeline.shared.reset()
            await LogStore.shared.log("Stopped", level: .info, tag: "Collector")
        }
    }

    /// 改设置后重启采集（保证停止先彻底收尾）
    func restart() async {
        stop()
        await start()
    }

    /// 切换统计窗口：按新窗口重查数据库，替换管线里的历史部分。
    ///
    /// 实时累计（尚未落库的那部分）保持不动 —— 它和历史部分不重叠，
    /// `flush()` 会把它转进历史。
    func applyTimeRange(_ range: DashboardViewModel.TimeRange) async {
        let interval = range.resolvedInterval(
            customStart: Preferences.customRangeStart, customEnd: Preferences.customRangeEnd)
        let since = interval.start.timeIntervalSince1970
        let until = interval.end.timeIntervalSince1970
        let summaries = (try? await DataStore.shared.querySummary(since: since, until: until)) ?? []
        await TrafficPipeline.shared.reloadHistorical(summaries, since: since, until: until)
        await LogStore.shared.log(
            "Time range → \(range.rawValue), loaded \(summaries.count) historical rows",
            level: .info, tag: "Collector"
        )
    }

    /// 按当前范围重查窗口。
    ///
    /// 跨过日历边界后必须调一次：窗口起点停在装载那一刻，不重查的话「今日」会一直
    /// 累计到跨天之后 —— 用户看到的数字成了「从打开应用累积到现在」，只有手动切一次
    /// 范围才会刷新。
    func reloadCurrentTimeRange() async {
        await applyTimeRange(Preferences.timeRange)
    }

    /// 应用「排除进程」列表：立即生效，已累计的数据一并清出
    func applyExcludedProcesses(_ text: String) {
        Preferences.excludedProcessesText = text
        let names = Preferences.parseExcluded(text)
        Task { await TrafficPipeline.shared.setExcludedProcesses(names) }
    }

    func loadAlertRules() {
        alertRules = AlertStore.shared.load()
        let rules = alertRules
        Task { await TrafficPipeline.shared.setAlertRules(rules) }
    }

    func applyAlertRules(_ rules: [AlertRule]) {
        alertRules = rules
        Task { await TrafficPipeline.shared.setAlertRules(rules) }
    }

    // MARK: - 消费循环

    private func runCollectionLoop(_ stream: AsyncStream<TrafficFrame>) {
        collectionTask = Task.detached(priority: .utility) { [weak self] in
            for await frame in stream {
                if Task.isCancelled { break }
                // 一帧只进一次 actor；不到刷新节拍或窗口不可见时返回 nil，
                // 主线程完全不被唤醒
                let snapshot = await TrafficPipeline.shared.ingest(frame)
                // 判定留在管线侧：只有真越过窗口终点（跨零点）才轮到主线程
                if await TrafficPipeline.shared.takeWindowRefreshRequest() {
                    await self?.reloadCurrentTimeRange()
                }
                guard let snapshot else { continue }
                await MainActor.run { [weak self] in
                    self?.snapshotSink?(snapshot)
                }
            }
        }
    }

    private func startSaveLoop() {
        let seconds = saveInterval
        saveTask = Task.detached(priority: .background) {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if Task.isCancelled { break }
                await TrafficPipeline.shared.flush()
            }
        }
    }

    // MARK: - 窗口可见性

    /// 窗口被完全遮挡 / 应用被隐藏时停止生成 UI 快照（采集与落库继续）
    private func startVisibilityMonitoring() {
        guard visibilityObservers.isEmpty else { return }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.willCloseNotification,
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification,
        ]
        visibilityObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                // 延后一个 runloop 再算：willClose 触发时窗口仍是 isVisible，
                // 当场判断会得到「还开着」的错误结论。
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { CollectorService.shared.syncVisibility() }
                }
            }
        }
        syncVisibility()
    }

    private func stopVisibilityMonitoring() {
        visibilityObservers.forEach(NotificationCenter.default.removeObserver)
        visibilityObservers.removeAll()
        Task { await TrafficPipeline.shared.setUIVisible(true) }
    }

    /// 是否已经见过一个可主窗口。用来区分「启动早期还没建好窗口」
    /// 和「用户主动把窗口关掉了」—— 前者要当作可见，后者不该再产出快照。
    private var hasSeenMainWindow = false

    private func syncVisibility() {
        guard !menuBarEnabled else {
            // 菜单栏在显示实时速率，快照不能停
            Task { await TrafficPipeline.shared.setUIVisible(true) }
            return
        }

        let mainWindows = NSApp.windows.filter { $0.canBecomeMain && $0.isVisible }
        if !mainWindows.isEmpty { hasSeenMainWindow = true }

        let visible: Bool
        if mainWindows.isEmpty {
            // 启动早期尚无窗口 → 当作可见，避免首屏空白；
            // 窗口出现过又消失 → 用户关掉了，且菜单栏也没开，没人需要快照
            visible = !hasSeenMainWindow
        } else {
            visible = mainWindows.contains { $0.occlusionState.contains(.visible) }
        }
        Task { await TrafficPipeline.shared.setUIVisible(visible) }
    }
}

// MARK: - 偏好持久化

/// 采集相关偏好的读写。
///
/// 单独抽出来是为了让 `CollectorService` 的属性 `didSet` 保持一行，
/// 同时把 UserDefaults 的 key 集中在一处。
enum Preferences {
    private static let intervalKey = "com.trafficmonitor.interval"
    private static let saveIntervalKey = "com.trafficmonitor.saveInterval"
    private static let menuBarKey = "com.trafficmonitor.menuBarEnabled"
    private static let timeRangeKey = "com.trafficmonitor.timeRange"
    private static let customRangeStartKey = "com.trafficmonitor.customRangeStart"
    private static let customRangeEndKey = "com.trafficmonitor.customRangeEnd"
    private static let excludedKey = "com.trafficmonitor.excludedProcesses"
    private static let sparklineKey = "com.trafficmonitor.sparkline"
    private static let menuBarFontKey = "com.trafficmonitor.menuBarFontSize"
    private static let retentionEnabledKey = "com.trafficmonitor.retentionEnabled"
    private static let retentionDaysKey = "com.trafficmonitor.retentionDays"

    static var interval: TimeInterval {
        get { read(intervalKey, default: Constants.defaultInterval) }
        set { UserDefaults.standard.set(newValue, forKey: intervalKey) }
    }

    static var saveInterval: TimeInterval {
        get { read(saveIntervalKey, default: Constants.batchSaveInterval) }
        set { UserDefaults.standard.set(newValue, forKey: saveIntervalKey) }
    }

    static var timeRange: DashboardViewModel.TimeRange {
        get {
            guard let raw = UserDefaults.standard.string(forKey: timeRangeKey) else { return .today }
            return DashboardViewModel.TimeRange(rawValue: raw) ?? .today
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: timeRangeKey) }
    }

    /// `.custom` 预设实际生效的起止日期——默认给"最近 7 天"（没选过 Custom
    /// 时的兜底值，纯粹是个合理的起点，不是什么特殊含义），跟 `Last 7 days`
    /// 的窗口大小一致。
    static var customRangeStart: Date {
        get {
            (UserDefaults.standard.object(forKey: customRangeStartKey) as? Date)
                ?? Calendar.current.date(byAdding: .day, value: -6, to: Date())!
        }
        set { UserDefaults.standard.set(newValue, forKey: customRangeStartKey) }
    }

    static var customRangeEnd: Date {
        get { (UserDefaults.standard.object(forKey: customRangeEndKey) as? Date) ?? Date() }
        set { UserDefaults.standard.set(newValue, forKey: customRangeEndKey) }
    }

    /// 用户手动排除的进程名（原样保存，便于回显到输入框）
    static var excludedProcessesText: String {
        get { UserDefaults.standard.string(forKey: excludedKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: excludedKey) }
    }

    /// 解析成用于比对的小写集合
    static func parseExcluded(_ text: String) -> Set<String> {
        Set(text.components(separatedBy: CharacterSet(charactersIn: ",，\n"))
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty })
    }

    /// 行内 sparkline，默认关闭
    static var sparklineEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: sparklineKey) }
        set { UserDefaults.standard.set(newValue, forKey: sparklineKey) }
    }

    /// 菜单栏两行速率的字号
    static var menuBarFontSize: Double {
        get { read(menuBarFontKey, default: 9) }
        set { UserDefaults.standard.set(newValue, forKey: menuBarFontKey) }
    }

    /// 是否自动清理过期数据。默认开启 —— 这与此前的实际行为一致
    /// （启动时无条件按 30 天清理），只是过去开关是假的、UI 说关着却照清不误。
    static var retentionEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: retentionEnabledKey) != nil else { return true }
            return UserDefaults.standard.bool(forKey: retentionEnabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: retentionEnabledKey) }
    }

    /// 明细数据保留天数
    static var retentionDays: Double {
        get { read(retentionDaysKey, default: Constants.retentionDays) }
        set { UserDefaults.standard.set(newValue, forKey: retentionDaysKey) }
    }

    static var menuBarEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: menuBarKey) != nil else { return true }
            return UserDefaults.standard.bool(forKey: menuBarKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: menuBarKey) }
    }

    /// UserDefaults 对「键不存在」和「值为 0」都返回 0，这里区分开
    private static func read(_ key: String, default fallback: TimeInterval) -> TimeInterval {
        guard UserDefaults.standard.object(forKey: key) != nil else { return fallback }
        let value = UserDefaults.standard.double(forKey: key)
        return value > 0 ? value : fallback
    }
}
