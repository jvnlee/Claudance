import Foundation

struct UsageBucket: Codable {
    var percent: Int
    var resetsAt: Date?
    var severity: String?
}

struct ScopedBucket: Codable {
    var label: String
    var bucket: UsageBucket
}

struct MoneyAmount: Codable, Equatable {
    var minor: Int
    var currency: String
    var exponent: Int

    static func cents(_ raw: Any?, currency: String?) -> MoneyAmount? {
        guard let n = raw as? NSNumber, n.doubleValue.isFinite else { return nil }
        return MoneyAmount(minor: Int(n.doubleValue.rounded()), currency: currency ?? "USD", exponent: 2)
    }

    static func parse(_ raw: Any?) -> MoneyAmount? {
        guard let d = raw as? [String: Any],
              let minor = (d["amount_minor"] as? NSNumber)?.intValue else { return nil }
        return MoneyAmount(minor: minor,
                           currency: (d["currency"] as? String) ?? "USD",
                           exponent: (d["exponent"] as? NSNumber)?.intValue ?? 2)
    }

    var text: String {
        let value = Double(minor) / pow(10.0, Double(max(0, exponent)))
        let s = String(format: "%.\(max(0, exponent))f", value)
        return currency.uppercased() == "USD" ? "$\(s)" : "\(s) \(currency.uppercased())"
    }
}

struct UsageSnapshot: Codable {
    var signedIn = false
    var account: String?
    var planName: String?
    var fiveHour: UsageBucket?
    var sevenDay: UsageBucket?
    var sonnet: UsageBucket?
    var scopedWeekly: [ScopedBucket] = []
    var extraUsageEnabled = false
    var extraUsage: UsageBucket?
    var extraUsageUsed: MoneyAmount?
    var extraUsageLimit: MoneyAmount?
    var creditBalance: MoneyAmount?
    var fetchedAt: Date?
    var statusMessage: String?

    var hasData: Bool { fiveHour != nil || sevenDay != nil }
    var hasExtraUsage: Bool { extraUsageEnabled && (extraUsage != nil || extraUsageUsed != nil || extraUsageLimit != nil) }
}

final class UsageMonitor {

    private let fm = FileManager.default
    private let queue = DispatchQueue(label: "com.hyunjunlee.claudance.usage", qos: .utility)

    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let userAgent = "Claudance/1.0"

    static let mockExtraUsage: (balance: MoneyAmount?, used: MoneyAmount, limit: MoneyAmount?)? = {
        guard let v = ProcessInfo.processInfo.environment["CLAUDANCE_MOCK_CREDITS"], !v.isEmpty else { return nil }
        func money(_ dollars: Double) -> MoneyAmount { MoneyAmount(minor: Int((dollars * 100).rounded()), currency: "USD", exponent: 2) }
        let parts = v.split(separator: ",").compactMap { Double($0) }
        if parts.count >= 3 { return (money(parts[0]), money(parts[1]), parts[2] > 0 ? money(parts[2]) : nil) }
        if parts.count == 2 { return (nil, money(parts[0]), parts[1] > 0 ? money(parts[1]) : nil) }
        return (nil, money(7.90), money(50.00))
    }()

    private let cacheMaxAge: TimeInterval = 180
    private let rateLimitBackoff: TimeInterval = 300
    private let errorBackoff: TimeInterval = 30
    private let authBackoff: TimeInterval = 120
    private let maxBackoff: TimeInterval = 900

    private var backoffUntil: [String: TimeInterval] = [:]
    private var fetching = false

    private var accountsByKey: [String: Account] = [:]
    private(set) var order: [String] = []
    private var snapshots: [String: UsageSnapshot] = [:]

    private let cacheURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/claudance/usage-cache.json")

    private struct CachedState: Codable {
        var snapshots: [String: UsageSnapshot]
        var backoffUntil: [String: TimeInterval]
    }

    init() {
        loadCache()
    }

    var keys: [String] { order }

    func snapshot(forKey key: String) -> UsageSnapshot? { snapshots[key] }

    func refresh(now: TimeInterval, accounts: [Account]) {
        order = accounts.map { $0.key }
        for account in accounts {
            accountsByKey[account.key] = account
            if snapshots[account.key] == nil {
                snapshots[account.key] = UsageSnapshot(account: account.email)
            } else {
                snapshots[account.key]?.account = account.email
            }
            if Self.mockExtraUsage != nil, var snap = snapshots[account.key] {
                Self.applyExtraUsage(&snap, nil)
                Self.applySpendBalance(&snap, nil)
                snapshots[account.key] = snap
            }
        }

        if fetching { return }
        guard let account = pickStalest(now: now, accounts: accounts) else { return }

        fetching = true
        let key = account.key
        let service = account.keychainService
        let isSubscription = account.isSubscription
        let orgUuid = account.organizationUuid
        let prior = snapshots[key] ?? UsageSnapshot(account: account.email)

        queue.async { [weak self] in
            guard let self else { return }

            guard let creds = Self.readCredentials(service: service) else {
                var snap = prior
                snap.signedIn = false
                snap.fiveHour = nil; snap.sevenDay = nil; snap.sonnet = nil; snap.scopedWeekly = []
                snap.extraUsageEnabled = false; snap.extraUsage = nil; snap.extraUsageUsed = nil; snap.extraUsageLimit = nil
                snap.creditBalance = nil
                snap.fetchedAt = nil
                snap.statusMessage = "Not signed in to Claude Code"
                self.publish(key, snap, backoff: self.errorBackoff)
                return
            }

            let plan = isSubscription ? Self.planName(subscriptionType: creds.subscriptionType, rateLimitTier: creds.rateLimitTier) : nil

            if let exp = creds.expiresAt, exp > 0, exp <= Date().timeIntervalSince1970 * 1000 {
                var snap = prior
                snap.signedIn = true
                snap.planName = plan
                snap.fiveHour = nil; snap.sevenDay = nil; snap.sonnet = nil; snap.scopedWeekly = []
                snap.fetchedAt = nil
                snap.statusMessage = "Session expired — log in to Claude Code"
                self.publish(key, snap, backoff: self.authBackoff)
                return
            }

            URLSession.shared.dataTask(with: Self.makeUsageRequest(token: creds.accessToken)) { [weak self] data, resp, _ in
                guard let self else { return }
                let http = resp as? HTTPURLResponse
                let code = http?.statusCode ?? -1

                var snap = prior
                snap.signedIn = true
                snap.planName = plan

                if code == 401 {
                    snap.fiveHour = nil; snap.sevenDay = nil; snap.sonnet = nil; snap.scopedWeekly = []
                    snap.fetchedAt = nil
                    snap.statusMessage = "Sign in to Claude Code to refresh"
                    self.publish(key, snap, backoff: self.authBackoff)
                    return
                }

                if code == 200, let data,
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    snap.fiveHour = Self.bucket(obj["five_hour"])
                    snap.sevenDay = Self.bucket(obj["seven_day"])
                    snap.sonnet = Self.bucket(obj["seven_day_sonnet"])
                    snap.scopedWeekly = []
                    Self.applyLimits(&snap, obj["limits"])
                    Self.applyExtraUsage(&snap, obj["extra_usage"])
                    Self.applySpendBalance(&snap, obj["spend"])
                    let gotQuota = obj["five_hour"] != nil || obj["seven_day"] != nil
                    if gotQuota || snap.hasExtraUsage || snap.creditBalance != nil {
                        snap.fetchedAt = Date()
                        snap.statusMessage = nil
                        self.publish(key, snap, backoff: 0)
                        return
                    }
                    if !isSubscription {
                        let base = snap
                        Self.fetchPrepaidCredits(token: creds.accessToken, orgUuid: orgUuid) { [weak self] balance in
                            guard let self else { return }
                            var s = base
                            s.creditBalance = balance
                            s.fetchedAt = Date()
                            s.statusMessage = balance == nil ? "Pay-as-you-go (API)" : nil
                            self.publish(key, s, backoff: 0)
                        }
                        return
                    }
                }

                snap.statusMessage = (prior.hasData || prior.hasExtraUsage) ? nil
                    : (code == 429 ? "Rate limited — retrying later" : "Usage temporarily unavailable")
                let retryAfter = http?.value(forHTTPHeaderField: "retry-after").flatMap(Double.init) ?? 0
                let backoff = code == 429 ? max(retryAfter, self.rateLimitBackoff) : self.errorBackoff
                self.publish(key, snap, backoff: backoff)
            }.resume()
        }
    }

    static func applyExtraUsage(_ snap: inout UsageSnapshot, _ raw: Any?) {
        if let mock = mockExtraUsage {
            snap.extraUsageEnabled = true
            snap.extraUsageUsed = mock.used
            snap.extraUsageLimit = mock.limit
            if let limit = mock.limit, limit.minor > 0 {
                snap.extraUsage = percentBucket(Double(mock.used.minor) / Double(limit.minor) * 100)
            } else {
                snap.extraUsage = nil
            }
            return
        }
        guard let d = raw as? [String: Any],
              (d["is_enabled"] as? NSNumber)?.boolValue == true
        else {
            snap.extraUsageEnabled = false
            snap.extraUsage = nil; snap.extraUsageUsed = nil; snap.extraUsageLimit = nil
            return
        }
        let currency = d["currency"] as? String
        snap.extraUsageEnabled = true
        snap.extraUsageUsed = MoneyAmount.cents(d["used_credits"], currency: currency)
        snap.extraUsageLimit = MoneyAmount.cents(d["monthly_limit"], currency: currency)
        if let util = (d["utilization"] as? NSNumber)?.doubleValue, util.isFinite {
            snap.extraUsage = percentBucket(util)
        } else if let used = snap.extraUsageUsed, let limit = snap.extraUsageLimit, limit.minor > 0 {
            snap.extraUsage = percentBucket(Double(used.minor) / Double(limit.minor) * 100)
        } else {
            snap.extraUsage = nil
        }
    }

    static func applySpendBalance(_ snap: inout UsageSnapshot, _ raw: Any?) {
        if let mock = mockExtraUsage {
            snap.creditBalance = mock.balance
            return
        }
        guard let d = raw as? [String: Any] else {
            snap.creditBalance = nil
            return
        }
        snap.creditBalance = MoneyAmount.parse(d["balance"])
    }

    static func fetchPrepaidCredits(token: String, orgUuid: String?, completion: @escaping (MoneyAmount?) -> Void) {
        guard let orgUuid, !orgUuid.isEmpty else {
            completion(nil)
            return
        }
        URLSession.shared.dataTask(with: makeCreditsRequest(token: token, orgUuid: orgUuid)) { data, resp, _ in
            guard (resp as? HTTPURLResponse)?.statusCode == 200, let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let currency = obj["currency"] as? String, !currency.isEmpty,
                  let amount = (obj["amount"] as? NSNumber)?.intValue
            else {
                completion(nil)
                return
            }
            completion(MoneyAmount(minor: amount, currency: currency.uppercased(), exponent: 2))
        }.resume()
    }

    private static func percentBucket(_ value: Double) -> UsageBucket {
        UsageBucket(percent: Int(min(100, max(0, value)).rounded()), resetsAt: nil)
    }

    static func applyLimits(_ snap: inout UsageSnapshot, _ raw: Any?) {
        guard let entries = raw as? [[String: Any]] else { return }
        for entry in entries {
            let severity = entry["severity"] as? String
            switch entry["kind"] as? String {
            case "session":
                snap.fiveHour?.severity = severity
            case "weekly_all":
                snap.sevenDay?.severity = severity
            case "weekly_scoped":
                guard let percent = (entry["percent"] as? NSNumber)?.doubleValue, percent.isFinite else { continue }
                let scope = entry["scope"] as? [String: Any]
                let model = (scope?["model"] as? [String: Any])?["display_name"] as? String
                var reset: Date?
                if let s = entry["resets_at"] as? String { reset = parseDate(s) }
                let bucket = UsageBucket(percent: Int(min(100, max(0, percent)).rounded()),
                                         resetsAt: reset, severity: severity)
                snap.scopedWeekly.append(ScopedBucket(label: model ?? "Model", bucket: bucket))
            default:
                break
            }
        }
    }

    private func pickStalest(now: TimeInterval, accounts: [Account]) -> Account? {
        var best: Account?
        var bestAge = -1.0
        for account in accounts {
            if now < (backoffUntil[account.key] ?? 0) { continue }
            let fetchedAt = snapshots[account.key]?.fetchedAt?.timeIntervalSince1970
            let age = fetchedAt.map { now - $0 } ?? Double.greatestFiniteMagnitude
            if age >= 0 && age < cacheMaxAge { continue }
            if age > bestAge { bestAge = age; best = account }
        }
        return best
    }

    private func publish(_ key: String, _ snap: UsageSnapshot, backoff: TimeInterval) {
        let bounded = min(max(0, backoff), maxBackoff)
        DispatchQueue.main.async {
            self.snapshots[key] = snap
            self.fetching = false
            self.backoffUntil[key] = bounded > 0 ? Date().timeIntervalSince1970 + bounded : 0
            self.queue.async { self.writeCache() }
        }
    }

    static func bucket(_ raw: Any?) -> UsageBucket? {
        guard let d = raw as? [String: Any],
              let util = (d["utilization"] as? NSNumber)?.doubleValue, util.isFinite
        else { return nil }
        var reset: Date?
        if let s = d["resets_at"] as? String { reset = parseDate(s) }
        return UsageBucket(percent: Int(min(100, max(0, util)).rounded()), resetsAt: reset)
    }

    private func writeCache() {
        let state = CachedState(snapshots: snapshots, backoffUntil: backoffUntil)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? fm.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let state = try? JSONDecoder().decode(CachedState.self, from: data)
        else { return }
        snapshots = state.snapshots
        let cap = Date().timeIntervalSince1970 + maxBackoff
        backoffUntil = state.backoffUntil.mapValues { min($0, cap) }
    }

    static func makeUsageRequest(token: String) -> URLRequest {
        var req = URLRequest(url: usageURL)
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return req
    }

    static func makeCreditsRequest(token: String, orgUuid: String) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/organizations/\(orgUuid)/prepaid/credits")!)
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue(orgUuid, forHTTPHeaderField: "x-organization-uuid")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return req
    }

    struct Credentials {
        let accessToken: String
        let subscriptionType: String?
        let rateLimitTier: String?
        let expiresAt: Double?
    }

    static func readCredentials(service: String) -> Credentials? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String
        else { return nil }
        return Credentials(accessToken: token,
                           subscriptionType: oauth["subscriptionType"] as? String,
                           rateLimitTier: oauth["rateLimitTier"] as? String,
                           expiresAt: (oauth["expiresAt"] as? NSNumber)?.doubleValue)
    }

    static func planName(subscriptionType: String?, rateLimitTier: String?) -> String? {
        guard let sub = subscriptionType, !sub.isEmpty else { return nil }
        let base = sub.prefix(1).uppercased() + sub.dropFirst()
        if sub == "max", let tier = rateLimitTier,
           let r = tier.range(of: "[0-9]+x$", options: .regularExpression) {
            return "\(base) \(tier[r])"
        }
        return base
    }

    static func parseDate(_ s: String) -> Date? {
        let cleaned = s.replacingOccurrences(of: "\\.\\d+", with: "", options: .regularExpression)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: cleaned)
    }

    static func printDiagnostic() {
        setvbuf(stdout, nil, _IONBF, 0)
        let accounts = AccountRegistry.discover()
        print("usage for \(accounts.count) account(s):")
        if mockExtraUsage != nil { print("  (CLAUDANCE_MOCK_CREDITS active — extra-usage rows are mocked)") }
        for account in accounts {
            print("• \(account.displayName)  [\(account.keychainService)]")
            guard let creds = readCredentials(service: account.keychainService) else {
                print("    not signed in")
                continue
            }
            print("    plan: \(planName(subscriptionType: creds.subscriptionType, rateLimitTier: creds.rateLimitTier) ?? "nil")")
            if let exp = creds.expiresAt, exp > 0, exp <= Date().timeIntervalSince1970 * 1000 {
                print("    token EXPIRED — would show 'Session expired — log in to Claude Code' (no API call)")
                continue
            }
            let sem = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: makeUsageRequest(token: creds.accessToken)) { data, resp, _ in
                defer { sem.signal() }
                print("    http: \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
                guard let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                for (key, label) in [("five_hour", "5-hour"), ("seven_day", "Weekly"), ("seven_day_sonnet", "Sonnet")] {
                    if let b = bucket(obj[key]) {
                        var line = "    \(label.padding(toLength: 7, withPad: " ", startingAt: 0)) \(b.percent)%"
                        if let r = b.resetsAt { line += "  ·  resets \(r)" }
                        print(line)
                    } else {
                        print("    \(label): null")
                    }
                }
                var snap = UsageSnapshot()
                applyExtraUsage(&snap, obj["extra_usage"])
                applySpendBalance(&snap, obj["spend"])
                print("    spend balance: \(snap.creditBalance?.text ?? "nil")")
                if snap.hasExtraUsage {
                    print("    extra usage: \(snap.extraUsage.map { "\($0.percent)%" } ?? "n/a")  used=\(snap.extraUsageUsed?.text ?? "nil")  limit=\(snap.extraUsageLimit?.text ?? "unlimited")")
                } else {
                    print("    extra usage: off (is_enabled=false) → Extra usage / API rows hidden")
                }
                if let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
                   let s = String(data: pretty, encoding: .utf8) {
                    print("    raw response:\n    " + s.replacingOccurrences(of: "\n", with: "\n    "))
                }
            }.resume()
            sem.wait()
            if !account.isSubscription {
                let creditsSem = DispatchSemaphore(value: 0)
                fetchPrepaidCredits(token: creds.accessToken, orgUuid: account.organizationUuid) { balance in
                    print("    prepaid credits (API): \(balance?.text ?? "none (amount 0 / currency null)")")
                    creditsSem.signal()
                }
                creditsSem.wait()
            }
        }
    }
}
