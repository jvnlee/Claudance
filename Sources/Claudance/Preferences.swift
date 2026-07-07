import Foundation

enum SpriteColorMode: String {
    case coral
    case adaptive
    case custom
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

    private func accountColorModeKey(_ accountKey: String) -> String {
        "pref.account.colorMode.\(accountKey)"
    }

    private func accountCustomColorKey(_ accountKey: String) -> String {
        "pref.account.customColor.\(accountKey)"
    }

    func colorMode(forAccountKey accountKey: String) -> SpriteColorMode {
        if let raw = defaults.string(forKey: accountColorModeKey(accountKey)),
           let mode = SpriteColorMode(rawValue: raw) {
            return mode
        }
        return colorMode
    }

    func setColorMode(_ mode: SpriteColorMode, forAccountKey accountKey: String) {
        defaults.set(mode.rawValue, forKey: accountColorModeKey(accountKey))
        notifyChange()
    }

    func customColorHex(forAccountKey accountKey: String) -> String? {
        defaults.string(forKey: accountCustomColorKey(accountKey))
    }

    func setCustomColorHex(_ hex: String, forAccountKey accountKey: String) {
        defaults.set(hex, forKey: accountCustomColorKey(accountKey))
        notifyChange()
    }

    private func accountMotionKey(_ accountKey: String) -> String {
        "pref.account.motion.\(accountKey)"
    }

    func motionEnabled(forAccountKey accountKey: String) -> Bool {
        if let v = defaults.object(forKey: accountMotionKey(accountKey)) as? Bool { return v }
        return motionEnabled
    }

    func setMotionEnabled(_ enabled: Bool, forAccountKey accountKey: String) {
        defaults.set(enabled, forKey: accountMotionKey(accountKey))
        notifyChange()
    }

    private func accountRowKey<R: MenuRow>(_ row: R, _ accountKey: String) -> String {
        "\(row.defaultsKey).\(accountKey)"
    }

    func isVisible<R: MenuRow>(_ row: R, forAccountKey accountKey: String) -> Bool {
        if let v = defaults.object(forKey: accountRowKey(row, accountKey)) as? Bool {
            return v
        }
        return defaults.bool(forKey: row.defaultsKey)
    }

    func setVisible<R: MenuRow>(_ row: R, _ visible: Bool, forAccountKey accountKey: String) {
        defaults.set(visible, forKey: accountRowKey(row, accountKey))
        notifyChange()
    }

    func setVisible<R: MenuRow>(_ rows: [R], _ visible: Bool, forAccountKey accountKey: String) {
        for row in rows { defaults.set(visible, forKey: accountRowKey(row, accountKey)) }
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
