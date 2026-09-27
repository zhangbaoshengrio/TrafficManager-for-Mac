import Foundation

// MARK: - 日志条目

struct LogEntry: Identifiable {
    let id: UUID = UUID()
    let timestamp: Date
    let level: Level
    let tag: String
    let message: String

    enum Level: String, Comparable, CaseIterable {
        case debug = "DEBUG"
        case info  = "INFO"
        case warn  = "WARN"
        case error = "ERROR"
        static func < (lhs: Level, rhs: Level) -> Bool {
            allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
        }
    }
}

// MARK: - 日志存储

actor LogStore {
    static let shared = LogStore()

    private var entries: [LogEntry] = []
    private let maxEntries = 300

    private init() {}

    func log(_ message: String, level: LogEntry.Level = .info, tag: String = "app") {
        let entry = LogEntry(timestamp: Date(), level: level, tag: tag, message: message)
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        // 同时输出到 stdout 方便终端调试
        let prefix: String
        switch level {
        case .error: prefix = "❌"
        case .warn:  prefix = "⚠️"
        case .info:  prefix = "ℹ️"
        case .debug: prefix = "🔍"
        }
        print("\(prefix) [\(tag)] \(message)")
    }

    func recentErrors() -> [LogEntry] {
        entries.filter { $0.level == .error || $0.level == .warn }
    }

    func recentEntries(count: Int = 50) -> [LogEntry] {
        let n = min(count, entries.count)
        return Array(entries.suffix(n))
    }
}
