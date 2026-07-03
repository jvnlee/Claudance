import Foundation

enum SpriteColorMode: String {
    case coral
    case adaptive
}

protocol MenuRow {
    var title: String { get }
    var defaultsKey: String { get }
}

enum SessionRow: String, CaseIterable, MenuRow {
    case total
    case working
    case waiting
    case idle

    var title: String {
        switch self {
        case .total: return "Total"
        case .working: return "Working"
        case .waiting: return "Waiting"
        case .idle: return "Idle"
        }
    }

    var defaultsKey: String { "pref.session.\(rawValue)" }
}

enum UsageRow: String, CaseIterable, MenuRow {
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

    var defaultsKey: String { "pref.usage.\(rawValue)" }
}

final class Preferences {

    static let shared = Preferences()
    static let didChange = Notification.Name("com.hyunjunlee.claudance.preferencesDidChange")

    private let defaults = UserDefaults.standard

    private enum Key {
        static let colorMode = "pref.colorMode"
        static let motionEnabled = "pref.motionEnabled"
    }

    private init() {
        var registration: [String: Any] = [
            Key.colorMode: SpriteColorMode.coral.rawValue,
            Key.motionEnabled: true,
        ]
        for row in SessionRow.allCases { registration[row.defaultsKey] = true }
        for row in UsageRow.allCases { registration[row.defaultsKey] = true }
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

    func isVisible<R: MenuRow>(_ row: R) -> Bool {
        defaults.bool(forKey: row.defaultsKey)
    }

    private func accountClawdKey(_ accountKey: String) -> String {
        "pref.account.clawd.\(accountKey)"
    }

    func showsClawd(forAccountKey accountKey: String) -> Bool {
        defaults.object(forKey: accountClawdKey(accountKey)) as? Bool ?? true
    }

    func setShowsClawd(_ shows: Bool, forAccountKey accountKey: String) {
        defaults.set(shows, forKey: accountClawdKey(accountKey))
        notifyChange()
    }

    func setVisible<R: MenuRow>(_ row: R, _ visible: Bool) {
        defaults.set(visible, forKey: row.defaultsKey)
        notifyChange()
    }

    func setVisible<R: MenuRow>(_ rows: [R], _ visible: Bool) {
        for row in rows { defaults.set(visible, forKey: row.defaultsKey) }
        notifyChange()
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
