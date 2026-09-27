import AppKit
import Foundation
import ServiceManagement

/// 开机自启动开关（`SMAppService`，macOS 13+）
///
/// 只对**真正的 .app bundle** 有效：`SMAppService.mainApp` 要向 LaunchServices
/// 注册当前应用，而 `swift run` 产出的裸可执行文件没有 bundle identifier，
/// 注册会失败。所以这里先探测可用性，不可用时让设置项禁用并说明原因，
/// 而不是给一个点了没反应的开关。
@MainActor
enum LaunchAtLogin {
    /// 当前环境是否支持（即是否以 .app 形式运行）
    static var isSupported: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    static var isEnabled: Bool {
        guard isSupported else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    /// 系统设置里被用户关掉了 —— 应用侧无法再打开，只能引导用户去系统设置
    static var requiresApproval: Bool {
        guard isSupported else { return false }
        return SMAppService.mainApp.status == .requiresApproval
    }

    /// - Returns: 失败时返回可直接展示给用户的原因，成功返回 nil
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        guard isSupported else {
            return L("launch.needsAppBundle")
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return (error as NSError).localizedDescription
        }
    }

    /// 打开「系统设置 › 通用 › 登录项」
    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// 说明当前状态的一句话，直接展示在设置里
    static var statusDescription: String? {
        guard isSupported else {
            return L("launch.notBundled")
        }
        return requiresApproval ? L("launch.requiresApproval") : nil
    }
}
