import Foundation

/// 进程标识（聚合键 + 预解析好的展示信息）
///
/// 关键约束：`displayName` 是**存储属性**。
/// 重构前它是 computed property，每次读取都同步 XPC 查询 LaunchServices
/// （`runningApplications(withBundleIdentifier:)`，实测 0.24ms/次），而它在
/// 每帧、每进程被读取多次。现在由 `ProcessIdentityResolver` 在首次解析该 PID 时
/// 算好并缓存，稳态下热路径零查询。
///
/// 相等性与哈希只看 `key`：同一个应用即使展示名后来变化，仍归为同一组。
struct ProcessIdentifier: Hashable, CustomStringConvertible {
    /// Bundle ID（如 "com.google.Chrome"），非 .app 进程为 nil
    let bundleId: String?

    /// 可执行文件名（无 Bundle ID 时作为标识）
    let execName: String

    /// 展示名（解析时确定，读取不触发任何查询）
    let displayName: String

    /// 取系统图标用的路径：优先 .app bundle，其次可执行文件本身
    ///
    /// 只存路径（`String`，可跨并发域传递），不存 `NSImage` —— 图标由主线程侧的
    /// `ProcessIconCache` 按需加载并缓存，避免非 Sendable 的 AppKit 对象穿过 actor 边界。
    let iconPath: String?

    /// 该进程是否是隧道/代理的出口进程（如 Shadowrocket 的 PacketTunnel 扩展、tailscaled）。
    ///
    /// 它们的外层 socket 承载的是**其他应用已被内核按进程计过的同一批字节**
    /// （应用 connect() → utun → 代理出口），计入就会重复统计，因此在采集链路上直接丢弃。
    /// 不参与相等性与哈希。
    let isTunnelEgress: Bool

    /// 聚合键：Bundle ID 优先，把 Chrome 的几十个子进程归为一条
    var key: String { bundleId ?? execName }

    var description: String { key }

    var sortKey: String { displayName.lowercased() }

    init(bundleId: String?, execName: String, displayName: String? = nil, iconPath: String? = nil,
         isTunnelEgress: Bool = false) {
        self.bundleId = bundleId
        self.execName = execName
        self.displayName = displayName
            ?? bundleId?.components(separatedBy: ".").last
            ?? execName
        self.iconPath = iconPath
        self.isTunnelEgress = isTunnelEgress
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }

    func hash(into hasher: inout Hasher) { hasher.combine(key) }
}
