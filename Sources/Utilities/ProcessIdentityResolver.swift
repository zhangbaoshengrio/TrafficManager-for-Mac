import AppKit
import Foundation

/// PID → `ProcessIdentifier` 的解析与缓存
///
/// 解析一次要走 LaunchServices 同步 XPC（`NSRunningApplication(processIdentifier:)`
/// 约 0.046ms，`localizedName` 再一次 XPC），因此每个进程只在首次出现时解析，
/// 之后常驻缓存 —— 稳态下每帧零 XPC。
///
/// PID 复用检测不需要额外 syscall：内核在每帧都给出该 PID 当前的可执行名，
/// 名字变了即说明 PID 被复用，直接重新解析。
///
/// 值类型且**非线程安全**，只在 `TrafficPipeline` actor 内部持有和调用。
struct ProcessIdentityResolver {
    private var cache: [Int32: (execName: String, identity: ProcessIdentifier)] = [:]
    private let maxEntries = 1024

    /// 解析（命中缓存则零开销）
    mutating func identity(pid: Int32, execName: String) -> ProcessIdentifier {
        if let hit = cache[pid], hit.execName == execName { return hit.identity }
        if cache.count >= maxEntries { cache.removeAll(keepingCapacity: true) }
        let identity = Self.resolve(pid: pid, execName: execName)
        cache[pid] = (execName, identity)
        return identity
    }

    mutating func reset() { cache.removeAll(keepingCapacity: true) }

    // MARK: - Resolve（仅缓存未命中时执行）

    private static func resolve(pid: Int32, execName: String) -> ProcessIdentifier {
        let path = executablePath(for: pid)
        let tunnel = isTunnelEgress(execName: execName, path: path)

        // 1. NSRunningApplication —— 最可靠，且能顺带拿到本地化名和 bundle 路径
        if let app = NSRunningApplication(processIdentifier: pid),
           let bundleId = app.bundleIdentifier {
            return ProcessIdentifier(
                bundleId: bundleId,
                execName: execName,
                displayName: app.localizedName,
                iconPath: app.bundleURL?.path ?? path.nilIfEmpty,
                isTunnelEgress: tunnel
            )
        }

        // 2. 可执行文件路径反查 .app Bundle（后台 helper 进程常走这条）
        if let (bundleId, bundlePath) = bundleInfo(fromExecutablePath: path) {
            return ProcessIdentifier(bundleId: bundleId, execName: execName,
                                     iconPath: bundlePath, isTunnelEgress: tunnel)
        }

        // 3. 守护进程 / CLI：用进程名，图标取可执行文件自身（活动监视器同样处理）
        return ProcessIdentifier(
            bundleId: nil,
            execName: execName,
            displayName: execName,
            iconPath: path.nilIfEmpty,
            isTunnelEgress: tunnel
        )
    }

    /// 是否隧道/代理出口：已知进程名，或可执行文件位于 NetworkExtension 隧道类 `.appex` 内。
    static func isTunnelEgress(execName: String, path: String) -> Bool {
        if Constants.tunnelEgressProcessNames.contains(execName.lowercased()) { return true }
        guard let range = path.range(of: ".appex/") else { return false }
        let plist = String(path[..<range.lowerBound]) + ".appex/Contents/Info.plist"
        guard let info = NSDictionary(contentsOfFile: plist),
              let ext = info["NSExtension"] as? [String: Any],
              let point = ext["NSExtensionPointIdentifier"] as? String else { return false }
        return Constants.tunnelExtensionPoints.contains(point)
    }

    private static func bundleInfo(fromExecutablePath path: String) -> (bundleId: String, bundlePath: String)? {
        guard path.contains(".app/") else { return nil }
        let components = path.components(separatedBy: "/")
        guard let appIndex = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        let bundlePath = components[0...appIndex].joined(separator: "/")
        guard let bundleId = Bundle(path: bundlePath)?.bundleIdentifier else { return nil }
        return (bundleId, bundlePath)
    }

    // MARK: - libproc

    @_silgen_name("proc_pidpath")
    private static func proc_pidpath(_ pid: Int32, _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> Int32

    private static func executablePath(for pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, 4096)
        return n > 0 ? String(cString: buf) : ""
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
