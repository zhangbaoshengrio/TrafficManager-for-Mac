import Foundation

/// 字节格式化工具
enum ByteFormatter {
    /// 数字与单位分开的格式化结果。
    ///
    /// 界面上要让「KB/s」这类单位**待着不动**，就不能把它和数字拼成一个字符串
    /// 交给 `Text` —— 那样数字从 `0` 涨到 `120.6`，后面的单位会跟着横移。
    /// 拆开之后，数字列右对齐、单位列左对齐，各占死宽度，单位的左边缘就固定了。
    struct Parts: Equatable {
        let value: String
        let unit: String

        /// 拼回单个字符串（`"1.2 MB"`）。不需要对齐的地方仍然用它。
        var joined: String { unit.isEmpty ? value : value + " " + unit }
    }

    // MARK: - 总量

    /// 格式化为人类可读的字符串
    /// - Parameter bytes: 字节数
    /// - Returns: 如 "1.2 MB", "500 KB", "0 B"
    static func string(bytes: Int64) -> String { parts(bytes: bytes).joined }

    /// 格式化为紧凑形式（用于表格等）
    static func stringCompact(bytes: Int64) -> String {
        let p = parts(bytes: bytes)
        return p.value + p.unit
    }

    /// 总量的数字 / 单位拆分形式
    static func parts(bytes: Int64) -> Parts {
        let absBytes = abs(bytes)
        if absBytes < 1024 {
            return Parts(value: "\(bytes)", unit: "B")
        }
        let units = ["KB", "MB", "GB", "TB"]
        var value = Double(absBytes) / 1024.0
        var unitIndex = 0
        while value >= 1024 && unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        let sign = bytes < 0 ? "-" : ""
        return Parts(value: String(format: "%@%.1f", sign, value), unit: units[unitIndex])
    }

    // MARK: - 速率

    /// 格式化为速率形式（如 "1.2 MB/s"）
    static func rateString(bytesPerSecond: Double) -> String {
        rateParts(bytesPerSecond: bytesPerSecond).joined
    }

    /// 速率的数字 / 单位拆分形式
    static func rateParts(bytesPerSecond: Double) -> Parts {
        if bytesPerSecond < 1024 {
            return Parts(value: String(format: "%.0f", bytesPerSecond), unit: "B/s")
        }
        // 要有 TB/s：只到 GB/s 时更大的值不再进位，会输出
        // "1023897.6 GB/s" 这种东西（量各档最宽字符串时发现的）
        let units = ["KB/s", "MB/s", "GB/s", "TB/s"]
        var value = bytesPerSecond / 1024.0
        var unitIndex = 0
        while value >= 1024 && unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        return Parts(value: String(format: "%.1f", value), unit: units[unitIndex])
    }

    /// 极窄处（菜单栏图片、面板进程行）用的速率，单位压成一个字母
    ///
    /// 与 `rateParts` 的分档规则**故意不同**：这里 1000 就进位，
    /// 为的是任何时候数字都不超过三位半，宽度可控。
    static func compactRateParts(bytesPerSecond: Double) -> Parts {
        let units = ["B", "K", "M", "G", "T"]
        var value = bytesPerSecond
        var index = 0
        while value >= 1000, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        let text = index == 0
            ? String(format: "%.0f", value)
            : String(format: value >= 10 ? "%.0f" : "%.1f", value)
        return Parts(value: text, unit: units[index])
    }

    /// 菜单栏用的紧凑速率，**恒定 5 个字符**（如 " 1.2M"、" 999K"、"    0"）
    ///
    /// 定长是硬要求：菜单栏标签每秒刷新，宽度一变 NSStatusItem 就要重新测量，
    /// 既会让整条菜单栏抖动，也会触发 AppKit 的布局递归警告。
    ///
    /// 基础档（B）不带单位字母 —— 菜单栏一列宽度寸土必争，
    /// 而「没有单位就是字节」在这个位置不会有歧义。
    static func rateStringCompact(bytesPerSecond: Double) -> String {
        let p = compactRateParts(bytesPerSecond: bytesPerSecond)
        let text = p.unit == "B" ? p.value : p.value + p.unit
        return String(repeating: " ", count: max(0, 5 - text.count)) + text
    }
}
