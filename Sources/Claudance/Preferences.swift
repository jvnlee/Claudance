import Foundation

enum SpriteColorMode: String {
    case coral
    case adaptive
}

enum UsageRow: String, CaseIterable {
    case account
    case plan
    case fiveHour
    case weekly
    case sonnet

    var title: String {
        switch self {
        case .account: return "Account"
        case .plan: return "Plan"
        case .fiveHour: return "5-hour limit"
        case .weekly: return "Weekly limit"
        case .sonnet: return "Sonnet"
        }
    }
}

final class Preferences {

    static let shared = Preferences()
    static let didChange = Notification.Name("com.hyunjunlee.claudance.preferencesDidChange")

    private let defaults = UserDefaults.standard

    private enum Key {
        static let colorMode = "pref.colorMode"
        static let motionEnabled = "pref.motionEnabled"
        static func usageRow(_ row: UsageRow) -> String { "pref.usage.\(row.rawValue)" }
    }

    private init() {
        var registration: [String: Any] = [
            Key.colorMode: SpriteColorMode.coral.rawValue,
            Key.motionEnabled: true,
        ]
        for row in UsageRow.allCases { registration[Key.usageRow(row)] = true }
        defaults.register(defaults: registration)
    }

    var colorMode: SpriteColorMode {
        get { SpriteColorMode(rawValue: defaults.string(forKey: Key.colorMode) ?? "") ?? .coral }
        set { defaults.set(newValue.rawValue, forKey: Key.colorMode); notifyChange() }
    }

    var motionEnabled: Bool {
        get { defaults.bool(forKey: Key.motionEnabled) }
        set { defaults.set(newValue, forKey: Key.motionEnabled); notifyChange() }
    }

    func isVisible(_ row: UsageRow) -> Bool {
        defaults.bool(forKey: Key.usageRow(row))
    }

    func setVisible(_ row: UsageRow, _ visible: Bool) {
        defaults.set(visible, forKey: Key.usageRow(row))
        notifyChange()
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
