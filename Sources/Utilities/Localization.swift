import Foundation

// MARK: - 界面语言

enum AppLanguage: String, CaseIterable, Identifiable {
    /// 跟随系统
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    /// 语言名用各自的语言书写，这样无论当前界面是什么语言都认得出
    var displayName: String {
        switch self {
        case .system: L("settings.language.system")
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        }
    }
}

// MARK: - 字符串表

/// 本地化查表。
///
/// 不用 `Text(LocalizedStringKey)` 的默认路径，原因是 SwiftPM 可执行目标的资源
/// 会被打进独立的 `TrafficMonitor_TrafficMonitor.bundle`，而 SwiftUI 默认查
/// `Bundle.main` —— 在这里永远查不到。
///
/// 另外两个实测坑：
/// - 资源必须用 `.copy` 而非 `.process` 声明。`.process` 会把 `zh-Hans.lproj`
///   **小写**成 `zh-hans.lproj`，之后 `Bundle.preferredLocalizations` 再也匹配不上，
///   永远回落到英文。
/// - 因此语言匹配也自己做，不依赖 `preferredLocalizations`。
enum L10n {
    /// 当前语言对应的 `.lproj` 子包
    nonisolated(unsafe) private(set) static var bundle: Bundle = resolve(Self.stored)

    /// 有翻译的语言，按优先级排列
    static let available: [String] = ["zh-Hans", "en"]

    static let fallback = "en"

    // MARK: 语言选择

    private static let key = "com.trafficmonitor.language"

    static var stored: AppLanguage {
        get {
            guard let raw = UserDefaults.standard.string(forKey: key) else { return .system }
            return AppLanguage(rawValue: raw) ?? .system
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            bundle = resolve(newValue)
        }
    }

    /// 实际生效的语言代码
    static var effective: String { match(Self.stored) }

    // MARK: 查表

    static func string(_ key: String) -> String {
        // value 传 key 本身：缺翻译时显示键名，比显示空串更容易发现问题
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    // MARK: 解析

    private static func match(_ language: AppLanguage) -> String {
        if language != .system { return language.rawValue }
        // 跟随系统：拿系统偏好语言逐个比对，只看主语言子标签
        for preferred in Locale.preferredLanguages {
            let code = preferred.lowercased()
            if code.hasPrefix("zh") { return "zh-Hans" }
            if let hit = available.first(where: { code.hasPrefix($0.lowercased()) }) { return hit }
        }
        return fallback
    }

    private static func resolve(_ language: AppLanguage) -> Bundle {
        let wanted = match(language)
        if let path = Bundle.module.path(forResource: wanted, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        if let path = Bundle.module.path(forResource: fallback, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        return Bundle.module
    }
}

// MARK: - 简写

/// 取一条本地化字符串
func L(_ key: String) -> String { L10n.string(key) }

/// 取一条带占位符的本地化字符串（`%@` / `%d` 等，遵循 `String(format:)`）
func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L10n.string(key), arguments: arguments)
}
