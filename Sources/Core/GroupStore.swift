import Foundation

final class GroupStore {
    static let shared = GroupStore()
    private let key = "com.trafficmonitor.processGroups"

    private init() {}

    func load() -> [ProcessGroup] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let groups = try? JSONDecoder().decode([ProcessGroup].self, from: data) else {
            return []
        }
        return groups
    }

    func save(_ groups: [ProcessGroup]) {
        guard let data = try? JSONEncoder().encode(groups) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
