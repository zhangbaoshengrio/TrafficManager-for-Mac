import Foundation

struct ProcessGroup: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var processKeys: Set<String>

    func contains(processKey: String) -> Bool {
        processKeys.contains(processKey)
    }
}
