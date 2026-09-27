import Darwin
import Foundation

// MARK: - 原生 NetworkStatistics 采集器

/// 基于私有框架 `NetworkStatistics.framework` 的原生流量采集器。
///
/// 直接调用内核 Network Statistics 子系统（`nettop` / 活动监视器同款后端），
/// 无子进程、非 root 可用、无特殊 entitlement。
///
/// ```
/// NStatManagerCreate(queue, addedBlock)
///   → AddAllTCP / AddAllUDP
///       per-source: SetCountsBlock / SetRemovedBlock
/// 每 interval 秒: QueryAllSourcesUpdate
///   → 每条连接回调一次 → SourceLedger 就地相减、按 PID 累加
///   → 回调派发完毕后在采集队列上收帧 → yield TrafficFrame
/// ```
///
/// ## 性能要点
///
/// counts 回调返回的 CFDictionary **有 47 个键**（rtt、拥塞窗口、地址、缓冲区……），
/// 而我们只需要 4 个。早先用 `dict as? [String: Any]` 整体桥接，实测 340 条连接
/// 一帧要 4.4–10ms，占整帧 wall time 的 55%。现在改用 `CFDictionaryGetValue` +
/// 静态 CFString 键直读，同样数据 0.25–0.58ms（17–20 倍）。
/// 进程名只在该 PID 首次出现时桥接一次。
///
/// ## 已知语义：loopback 自连会双记
///
/// 一个进程通过 127.0.0.1 连自己时，客户端和服务端是同一个 PID 的两条 source，
/// 内核分别记一次发送和一次接收。实测：单进程内经 loopback 传输 10 MiB，
/// NStat 报 rx=10 MiB **且** tx=10 MiB —— 各自都对，但"下载+上传"合计是实际
/// 载荷的 2 倍。真实外网流量不存在这个问题。
final class NStatCollector {
    // MARK: C 函数类型

    private typealias SourceRef = OpaquePointer
    private typealias ManagerRef = OpaquePointer
    private typealias AddedBlock = @convention(block) (SourceRef?) -> Void
    private typealias DictBlock = @convention(block) (CFDictionary?) -> Void
    private typealias VoidBlock = @convention(block) () -> Void
    private typealias FnCreate = @convention(c) (CFAllocator?, OpaquePointer?, @escaping AddedBlock) -> ManagerRef?
    private typealias FnAddAll = @convention(c) (ManagerRef?) -> Int32
    private typealias FnSetDict = @convention(c) (SourceRef?, @escaping DictBlock) -> Void
    private typealias FnSetVoid = @convention(c) (SourceRef?, @escaping VoidBlock) -> Void
    private typealias FnQueryUpdate = @convention(c) (ManagerRef?, @escaping VoidBlock) -> Void
    private typealias FnDestroy = @convention(c) (ManagerRef?) -> Void

    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/NetworkStatistics.framework/NetworkStatistics"

    // MARK: 字典键（静态常量，避免每次回调重新创建 CFString）

    private static let keyProcessID   = "processID"   as CFString
    private static let keyProcessName = "processName" as CFString
    private static let keyRxBytes     = "rxBytes"     as CFString
    private static let keyTxBytes     = "txBytes"     as CFString

    // MARK: 状态（全部只在 `queue` 上访问）

    private let handle: UnsafeMutableRawPointer
    private let queue = DispatchQueue(label: "com.trafficmonitor.nstat", qos: .utility)

    private var manager: ManagerRef?
    /// 传给 C 框架的 queue 引用（passRetained），销毁 manager 后释放
    private var queueRef: UnsafeMutableRawPointer?
    private var continuation: AsyncStream<TrafficFrame>.Continuation?
    private var timer: DispatchSourceTimer?

    private var ledger = SourceLedger()
    /// 复用的输出缓冲，避免每帧分配
    private var frameBuffer: [PIDDelta] = []
    private var lastFrameAt: Date?
    private var emittedBaseline = false

    private let create: FnCreate
    private let addAllTCP: FnAddAll
    private let addAllUDP: FnAddAll
    private let setCounts: FnSetDict
    private let setRemoved: FnSetVoid
    private let queryUpdate: FnQueryUpdate
    private let destroy: FnDestroy

    /// 原生接口是否可用（dlopen + 全部符号绑定成功）
    static var isAvailable: Bool {
        guard let handle = dlopen(frameworkPath, RTLD_NOW) else { return false }
        defer { dlclose(handle) }
        let names = [
            "NStatManagerCreate", "NStatManagerAddAllTCP", "NStatManagerAddAllUDP",
            "NStatSourceSetCountsBlock", "NStatSourceSetRemovedBlock",
            "NStatManagerQueryAllSourcesUpdate", "NStatManagerDestroy",
        ]
        return names.allSatisfy { dlsym(handle, $0) != nil }
    }

    init?() {
        guard let handle = dlopen(Self.frameworkPath, RTLD_NOW) else { return nil }
        func bind<T>(_ name: String, _ type: T.Type) -> T? {
            guard let sym = dlsym(handle, name) else { return nil }
            return unsafeBitCast(sym, to: T.self)
        }
        guard let create = bind("NStatManagerCreate", FnCreate.self),
              let addAllTCP = bind("NStatManagerAddAllTCP", FnAddAll.self),
              let addAllUDP = bind("NStatManagerAddAllUDP", FnAddAll.self),
              let setCounts = bind("NStatSourceSetCountsBlock", FnSetDict.self),
              let setRemoved = bind("NStatSourceSetRemovedBlock", FnSetVoid.self),
              let queryUpdate = bind("NStatManagerQueryAllSourcesUpdate", FnQueryUpdate.self),
              let destroy = bind("NStatManagerDestroy", FnDestroy.self)
        else {
            dlclose(handle)
            return nil
        }
        self.handle = handle
        self.create = create
        self.addAllTCP = addAllTCP
        self.addAllUDP = addAllUDP
        self.setCounts = setCounts
        self.setRemoved = setRemoved
        self.queryUpdate = queryUpdate
        self.destroy = destroy
        frameBuffer.reserveCapacity(128)
    }

    deinit {
        teardown()
        dlclose(handle)
    }

    // MARK: - Public

    /// 启动采集，返回帧流。
    ///
    /// 队列策略是 `.bufferingNewest(1)`：消费端（管线 actor）万一慢于生产端，
    /// 只保留最新一帧而不是无限堆积。旧实现用默认的 unbounded 缓冲，
    /// 主线程一卡就会积压。
    func start(interval: TimeInterval) -> AsyncStream<TrafficFrame> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { cont in
            let secs = max(Constants.minInterval, interval)
            queue.async { [weak self] in
                guard let self else { cont.finish(); return }
                self.continuation = cont
                self.setupManager()
                self.queryAndEmit()          // 首帧：建立基线
                self.startTimer(interval: secs)
            }
            cont.onTermination = { [weak self] _ in
                guard let collector = self else { return }
                collector.queue.async { collector.teardown() }
            }
        }
    }

    func stop() {
        queue.sync { teardown() }
    }

    // MARK: - Setup / Teardown

    private func setupManager() {
        let queueRef = Unmanaged.passRetained(queue).toOpaque()
        self.queueRef = queueRef

        let added: AddedBlock = { [weak self] source in
            guard let collector = self, let source else { return }
            let key = UInt(bitPattern: Int(bitPattern: source))
            collector.setCounts(source) { [weak collector] dict in
                guard let collector, let dict else { return }
                collector.consume(dict, source: key)
            }
            collector.setRemoved(source) { [weak collector] in
                collector?.ledger.remove(source: key)
            }
        }
        manager = create(kCFAllocatorDefault, OpaquePointer(queueRef), added)
        _ = addAllTCP(manager)
        _ = addAllUDP(manager)
    }

    private func teardown() {
        timer?.cancel()
        timer = nil
        if let manager {
            destroy(manager)
            self.manager = nil
        }
        if let queueRef {
            Unmanaged<DispatchQueue>.fromOpaque(queueRef).release()
            self.queueRef = nil
        }
        ledger.reset()
        frameBuffer.removeAll(keepingCapacity: false)
        lastFrameAt = nil
        emittedBaseline = false
        continuation?.finish()
        continuation = nil
    }

    private func startTimer(interval: TimeInterval) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        // leeway 给内核合并定时器唤醒的余地，省电且不影响 1s 级精度
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.queryAndEmit() }
        t.resume()
        timer = t
    }

    // MARK: - 采样

    /// counts 回调：零桥接读取 4 个字段
    private func consume(_ dict: CFDictionary, source: UInt) {
        guard let pid64 = Self.int64(dict, Self.keyProcessID) else { return }
        let pid = Int32(truncatingIfNeeded: pid64)
        let rx = Self.int64(dict, Self.keyRxBytes) ?? 0
        let tx = Self.int64(dict, Self.keyTxBytes) ?? 0
        // 进程名只在该 PID 首次出现时桥接一次
        let name = ledger.needsName(for: pid) ? Self.string(dict, Self.keyProcessName) : nil
        ledger.record(source: source, pid: pid, name: name, rx: rx, tx: tx)
    }

    private func queryAndEmit() {
        guard let manager else { return }
        ledger.beginFrame()
        queryUpdate(manager) { [weak self] in
            // counts 回调已全部派发；回采集队列串行收帧，保证顺序
            self?.queue.async { self?.finalizeFrame() }
        }
    }

    private func finalizeFrame() {
        guard let continuation else { return }
        ledger.endFrame(into: &frameBuffer)

        let now = Date()
        let elapsed = lastFrameAt.map { now.timeIntervalSince($0) } ?? 0
        lastFrameAt = now

        let isBaseline = !emittedBaseline
        emittedBaseline = true

        continuation.yield(TrafficFrame(
            deltas: frameBuffer,
            timestamp: now,
            interval: isBaseline ? 0 : elapsed,
            isBaseline: isBaseline
        ))
    }

    // MARK: - CFDictionary 零桥接读取

    @inline(__always)
    private static func int64(_ dict: CFDictionary, _ key: CFString) -> Int64? {
        guard let raw = CFDictionaryGetValue(dict, unsafeBitCast(key, to: UnsafeRawPointer.self)) else {
            return nil
        }
        let number = Unmanaged<CFNumber>.fromOpaque(raw).takeUnretainedValue()
        var out: Int64 = 0
        guard CFNumberGetValue(number, .sInt64Type, &out) else { return nil }
        return out
    }

    @inline(__always)
    private static func string(_ dict: CFDictionary, _ key: CFString) -> String? {
        guard let raw = CFDictionaryGetValue(dict, unsafeBitCast(key, to: UnsafeRawPointer.self)) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }
}
