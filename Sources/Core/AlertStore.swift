import Foundation

final class AlertStore {
    static let shared = AlertStore()
    private let key = "com.trafficmonitor.alertRules"

    private init() {}

    func load() -> [AlertRule] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let rules = try? JSONDecoder().decode([AlertRule].self, from: data) else {
            return []
        }
        return rules
    }

    func save(_ rules: [AlertRule]) {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
