import Foundation
import GRDB

/// 一次告警规则触发的记录。
///
/// 跟 `AlertRule`（存在 UserDefaults 里的配置）不是一回事：这张表存的是
/// "历史上真的响过几次、什么时候、因为什么值"，用来在流量图上画 ▲ 标记。
struct AlertEvent: Identifiable, Codable {
    /// 自增主键
    var id: Int64?

    /// 触发时刻（Unix 秒）
    let timestamp: TimeInterval

    /// 对应哪条 `AlertRule`（`rule.id.uuidString`）
    let ruleId: String

    /// 触发时展示用的文案（比如"Chrome 超过 1GB"），冗余存一份避免规则被
    /// 删除/改名后历史记录变得无法理解
    let displayName: String

    /// 触发时的具体数值（字节数或速率，取决于规则类型）
    let triggerValue: Double
}

extension AlertEvent: TableRecord, FetchableRecord, MutablePersistableRecord {
    enum Columns {
        static let id = Column(CodingKeys.id)
        static let timestamp = Column(CodingKeys.timestamp)
        static let ruleId = Column(CodingKeys.ruleId)
        static let displayName = Column(CodingKeys.displayName)
        static let triggerValue = Column(CodingKeys.triggerValue)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
