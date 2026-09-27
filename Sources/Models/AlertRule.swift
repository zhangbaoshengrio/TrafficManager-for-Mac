import Foundation

struct AlertRule: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var processKey: String?
    var displayName: String
    var thresholdBytes: Int64?
    var thresholdRate: Double?
    var enabled: Bool = true

    func isTriggered(by delta: ProcessDelta) -> Bool {
        if let key = processKey, delta.identifier.description != key { return false }
        if let tb = thresholdBytes, delta.totalBytes < tb { return false }
        if let tr = thresholdRate, delta.totalRate < tr { return false }
        return thresholdBytes != nil || thresholdRate != nil
    }
}
