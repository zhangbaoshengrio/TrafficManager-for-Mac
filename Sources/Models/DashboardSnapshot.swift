import Foundation

/// 表格中的一行
///
/// 值类型 + `Equatable`：SwiftUI `Table` 才能做行级差分，只重绘真正变化的行。
/// 旧实现用的是 `NSObject` 子类且没有 `Equatable`，每次刷新都导致 NSTableView 全量 reload。
struct ProcessRow: Identifiable, Equatable {
    var id: String { key }
    let key: String
    let bundleId: String?
    let displayName: String
    /// SF Symbol 名，作为拿不到真实图标时的兜底
    let icon: String
    /// 真实应用图标的路径，由 `ProcessIconCache` 在主线程侧按需加载
    let iconPath: String?
    let totalIn: Int64
    let totalOut: Int64
    let rxRate: Double
    let txRate: Double
    /// 最近若干帧的总速率，用于行内 sparkline。关闭该功能时为空数组。
    let spark: [Double]

    var totalBytes: Int64 { totalIn + totalOut }
}

/// 分组视图中的一行
struct GroupRow: Identifiable, Equatable {
    let id: UUID
    let name: String
    /// 是否为「其他」这一兜底分组。
    /// 此前靠 `name == "其他"` 判断，本地化之后这种比较必然失效。
    let isOthers: Bool
    let totalIn: Int64
    let totalOut: Int64
    let rxRate: Double
    let txRate: Double
    let memberCount: Int

    var totalBytes: Int64 { totalIn + totalOut }
}

/// 一次推送给 UI 的完整快照
///
/// 管线在后台 actor 上算好整份快照，MainActor 只做一次赋值 —— 旧实现要在
/// 主线程上分 4 次写 `@Published`，再触发一轮 `RowItem` 重建和二次布局。
struct DashboardSnapshot: Equatable {
    var rows: [ProcessRow] = []
    var totalRxRate: Double = 0
    var totalTxRate: Double = 0
    var totalIn: Int64 = 0
    var totalOut: Int64 = 0

    var totalBytes: Int64 { totalIn + totalOut }
}
