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
    case fiveHour
    case weekly
    case sonnet
    case extraUsage
    case balance
    case used
    case monthlyCap

    var title: String {
        switch self {
        case .fiveHour: return "5-hour limit"
        case .weekly: return "Weekly limit"
        case .sonnet: return "Model weekly"
        case .extraUsage: return "Extra usage"
        case .balance: return "Balance"
        case .used: return "Used"
        case .monthlyCap: return "Monthly Cap"
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
        static let speechBubbleEnabled = "pref.speechBubbleEnabled"
    }

    private init() {
        var registration: [String: Any] = [
            Key.colorMode: SpriteColorMode.coral.rawValue,
            Key.motionEnabled: true,
            Key.speechBubbleEnabled: true,
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

    var speechBubbleEnabled: Bool {
        get { defaults.bool(forKey: Key.speechBubbleEnabled) }
        set { defaults.set(newValue, forKey: Key.speechBubbleEnabled); notifyChange() }
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

    private func accountSpeechBubbleKey(_ accountKey: String) -> String {
        "pref.account.speechBubble.\(accountKey)"
    }

    func speechBubbleEnabled(forAccountKey accountKey: String) -> Bool {
        if let v = defaults.object(forKey: accountSpeechBubbleKey(accountKey)) as? Bool { return v }
        return speechBubbleEnabled
    }

    func setSpeechBubbleEnabled(_ enabled: Bool, forAccountKey accountKey: String) {
        defaults.set(enabled, forKey: accountSpeechBubbleKey(accountKey))
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
