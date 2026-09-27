import Foundation

/// 全局常量
enum Constants {
    // MARK: - 应用标识
    //
    // 版本号与 Bundle ID 的唯一真源：`Scripts/make-app.sh` 在打包时
    // 从这里取值写进 Info.plist，设置窗的「关于」页也读这里，避免三处各写一份。

    /// 应用版本号
    static let appVersion = "0.7.12"

    /// Bundle ID（打包成 .app 时使用；fork 本项目请改成你自己的反向域名）
    static let bundleIdentifier = "com.mo2g.TrafficMonitor"

    // MARK: - 采集

    /// 默认采集间隔（秒）— 2s 是 CPU 与实时性的平衡点
    static let defaultInterval: TimeInterval = 2.0

    /// 最小允许的采集间隔
    static let minInterval: TimeInterval = 1.0

    /// 计算速率时的间隔下限（秒）
    ///
    /// 防止极短间隔（时钟抖动、首帧）把速率算成天文数字。
    static let minRateInterval: TimeInterval = 0.1

    /// UI 快照最快多久推送一次（秒）
    ///
    /// 采集照常按 `interval` 进行，只是不会每帧都惊动 SwiftUI。
    static let uiRefreshInterval: TimeInterval = 1.0

    /// 落库前的内存聚合桶大小（秒）
    ///
    /// 旧实现每进程每 tick 写一行：40 个进程 @2s ≈ 72 万行/天。
    /// 先在内存里按桶聚合，一个桶一个进程只写一行，行数降到 1/30。
    static let storageBucketSeconds: TimeInterval = 60.0

    /// 批量落库的默认间隔（秒）
    static let batchSaveInterval: TimeInterval = 15.0

    /// 单条 INSERT 语句最多带几行（SQLite 变量数上限留足余量）
    static let insertChunkSize = 100

    /// 明细数据保留天数，超期在启动时清理
    static let retentionDays: Double = 30

    /// 行内 sparkline 保留多少帧
    static let sparklineSampleCount = 40

    /// SourceLedger 里 PID→名字 映射的上限，超过则回收已退出进程
    static let maxTrackedProcessNames = 2048

    /// 数据库文件名
    static let databaseFileName = "traffic_monitor.db"

    /// 数据库目录（Application Support 下）
    static var databaseDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("TrafficMonitor")
    }

    /// 数据库完整路径
    static var databaseURL: URL {
        databaseDirectory.appendingPathComponent(databaseFileName)
    }

    /// 排除的进程名（始终不显示）
    static let alwaysExcludedProcesses: Set<String> = [
        "kernel_task", "launchd", "WindowServer",
    ]
}
