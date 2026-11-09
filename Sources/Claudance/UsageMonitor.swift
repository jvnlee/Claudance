import Foundation
import CryptoKit

struct UsageBucket: Codable {
    var percent: Int
    var resetsAt: Date?

    func rolledOver(at now: Date) -> UsageBucket {
        guard let resetsAt, resetsAt <= now else { return self }
        return UsageBucket(percent: 0, resetsAt: nil)
    }
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
    var authBlocked: Bool?

    static let staleAfter: TimeInterval = 600

    var hasData: Bool { fiveHour != nil || sevenDay != nil }
    var lacksFiveHourLimit: Bool { sevenDay != nil && fiveHour == nil }
    var hasExtraUsage: Bool { extraUsageEnabled && (extraUsage != nil || extraUsageUsed != nil || extraUsageLimit != nil) }

    func isStale(at now: Date) -> Bool {
        guard let fetchedAt else { return false }
        return now.timeIntervalSince(fetchedAt) > Self.staleAfter
    }

    func rolledOver(at now: Date) -> UsageSnapshot {
        var snap = self
        snap.fiveHour = fiveHour?.rolledOver(at: now)
        snap.sevenDay = sevenDay?.rolledOver(at: now)
        snap.sonnet = sonnet?.rolledOver(at: now)
        snap.scopedWeekly = scopedWeekly.map { ScopedBucket(label: $0.label, bucket: $0.bucket.rolledOver(at: now)) }
        return snap
    }
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
    private let authProbeFloor: TimeInterval = 30

    private var backoffUntil: [String: TimeInterval] = [:]
    private var fetching = false

    private struct AuthWatch {
        let service: String
        let credentialFingerprint: String?
    }

    private var authWatch: [String: AuthWatch] = [:]
    private var probingAuth = false
    private var lastAuthProbe: TimeInterval = 0
    private var lastCredentialStamp: String?

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

    func snapshot(forKey key: String) -> UsageSnapshot? { snapshots[key]?.rolledOver(at: Date()) }

    func forget(_ key: String) {
        snapshots[key] = nil
        backoffUntil[key] = nil
        authWatch[key] = nil
        writeCache()
    }

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
            if snapshots[account.key]?.authBlocked == true, authWatch[account.key] == nil {
                authWatch[account.key] = AuthWatch(service: account.keychainService, credentialFingerprint: nil)
            }
        }

        if !authWatch.isEmpty {
            let live = Set(order)
            authWatch = authWatch.filter { live.contains($0.key) }
            probeAuthRecovery(now: now)
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
                snap.authBlocked = true
                self.publish(key, snap, backoff: self.errorBackoff,
                             watch: AuthWatch(service: service, credentialFingerprint: nil))
                return
            }

            let plan = isSubscription ? Self.planName(subscriptionType: creds.subscriptionType, rateLimitTier: creds.rateLimitTier) : nil

            if Self.isExpired(creds) {
                self.publish(key, Self.pausedForAuth(prior, plan: plan, message: "Session expired. Log in to Claude Code."),
                             backoff: self.authBackoff,
                             watch: AuthWatch(service: service, credentialFingerprint: creds.fingerprint))
                return
            }

            URLSession.shared.dataTask(with: Self.makeUsageRequest(token: creds.accessToken)) { [weak self] data, resp, _ in
                guard let self else { return }
                let http = resp as? HTTPURLResponse
                let code = http?.statusCode ?? -1

                var snap = prior
                snap.signedIn = true
                snap.planName = plan
                snap.authBlocked = false

                if code == 401 {
                    self.publish(key, Self.pausedForAuth(prior, plan: plan, message: "Sign in to Claude Code to refresh"),
                                 backoff: self.authBackoff,
                                 watch: AuthWatch(service: service, credentialFingerprint: creds.fingerprint))
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
                    : (code == 429 ? "Rate limited. Retrying later." : "Usage temporarily unavailable")
                let retryAfter = http?.value(forHTTPHeaderField: "retry-after").flatMap(Double.init) ?? 0
                let backoff = code == 429 ? max(retryAfter, self.rateLimitBackoff) : self.errorBackoff
                self.publish(key, snap, backoff: backoff)
            }.resume()
        }
    }

    static func pausedForAuth(_ prior: UsageSnapshot, plan: String?, message: String) -> UsageSnapshot {
        var snap = prior
        snap.signedIn = true
        snap.planName = plan
        snap.statusMessage = message
        snap.authBlocked = true
        return snap
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
            guard entry["kind"] as? String == "weekly_scoped",
                  let percent = (entry["percent"] as? NSNumber)?.doubleValue, percent.isFinite
            else { continue }
            let scope = entry["scope"] as? [String: Any]
            let model = (scope?["model"] as? [String: Any])?["display_name"] as? String
            var reset: Date?
            if let s = entry["resets_at"] as? String { reset = parseDate(s) }
            let bucket = UsageBucket(percent: Int(min(100, max(0, percent)).rounded()), resetsAt: reset)
            snap.scopedWeekly.append(ScopedBucket(label: model ?? "Model", bucket: bucket))
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

    private func publish(_ key: String, _ snap: UsageSnapshot, backoff: TimeInterval, watch: AuthWatch? = nil) {
        let bounded = min(max(0, backoff), maxBackoff)
        DispatchQueue.main.async {
            self.snapshots[key] = snap
            self.fetching = false
            self.authWatch[key] = watch
            self.backoffUntil[key] = bounded > 0 ? Date().timeIntervalSince1970 + bounded : 0
            self.queue.async { self.writeCache() }
        }
    }

    private func probeAuthRecovery(now: TimeInterval) {
        guard !authWatch.isEmpty, !probingAuth else { return }
        let stamp = AccountRegistry.credentialStoreStamp()
        guard stamp != lastCredentialStamp || now - lastAuthProbe >= authProbeFloor else { return }
        lastCredentialStamp = stamp
        lastAuthProbe = now
        probingAuth = true

        let watches = authWatch
        queue.async { [weak self] in
            guard let self else { return }
            let restored = watches.compactMap { key, watch -> String? in
                let creds = Self.readCredentials(service: watch.service)
                return Self.credentialsRestored(from: watch.credentialFingerprint, to: creds) ? key : nil
            }
            DispatchQueue.main.async {
                self.probingAuth = false
                guard !restored.isEmpty else { return }
                for key in restored {
                    self.authWatch[key] = nil
                    self.backoffUntil[key] = 0
                }
                self.refresh(now: Date().timeIntervalSince1970,
                             accounts: self.order.compactMap { self.accountsByKey[$0] })
            }
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

        var fingerprint: String {
            let hex = SHA256.hash(data: Data(accessToken.utf8))
                .prefix(8).map { String(format: "%02x", $0) }.joined()
            return "\(hex)/\(Int(expiresAt ?? 0))"
        }
    }

    static func isExpired(_ creds: Credentials, now: Date = Date()) -> Bool {
        guard let exp = creds.expiresAt, exp > 0 else { return false }
        return exp <= now.timeIntervalSince1970 * 1000
    }

    static func credentialsRestored(from previous: String?, to creds: Credentials?, now: Date = Date()) -> Bool {
        guard let creds, !isExpired(creds, now: now) else { return false }
        return creds.fingerprint != previous
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
        if sub == "max" { return Account.maxPlanLabel(rateLimitTiers: [rateLimitTier]) }
        return sub.prefix(1).uppercased() + sub.dropFirst()
    }

    static func parseDate(_ s: String) -> Date? {
        let cleaned = s.replacingOccurrences(of: "\\.\\d+", with: "", options: .regularExpression)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: cleaned)
    }

    static func selfTest() -> Bool {
        var ok = true
        func check(_ label: String, _ got: Bool, _ want: Bool) {
            let pass = got == want
            if !pass { ok = false }
            print("  [\(pass ? "PASS" : "FAIL")] \(label): got=\(got) want=\(want)")
        }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func creds(_ token: String, expiresIn: Double?) -> Credentials {
            Credentials(accessToken: token, subscriptionType: "max", rateLimitTier: nil,
                        expiresAt: expiresIn.map { (now.timeIntervalSince1970 + $0) * 1000 })
        }
        let expired = creds("old-token", expiresIn: -60)
        let renewed = creds("new-token", expiresIn: 3600)

        check("auth: expired token reads as expired", isExpired(expired, now: now), true)
        check("auth: live token reads as live", isExpired(renewed, now: now), false)
        check("auth: token without expiry reads as live", isExpired(creds("t", expiresIn: nil), now: now), false)
        check("auth: fingerprint tracks the token",
              creds("a", expiresIn: 60).fingerprint != creds("b", expiresIn: 60).fingerprint, true)
        check("auth: fingerprint tracks the expiry",
              creds("a", expiresIn: 60).fingerprint != creds("a", expiresIn: 120).fingerprint, true)
        check("auth: re-login after expiry refetches",
              credentialsRestored(from: expired.fingerprint, to: renewed, now: now), true)
        check("auth: first login with no prior credentials refetches",
              credentialsRestored(from: nil, to: renewed, now: now), true)
        check("auth: untouched expired token stays backed off",
              credentialsRestored(from: expired.fingerprint, to: expired, now: now), false)
        check("auth: same live token after a 401 stays backed off",
              credentialsRestored(from: renewed.fingerprint, to: renewed, now: now), false)
        check("auth: still-missing credentials stay backed off",
              credentialsRestored(from: nil, to: nil, now: now), false)
        check("auth: logout during backoff does not refetch",
              credentialsRestored(from: renewed.fingerprint, to: nil, now: now), false)
        check("auth: relaunch re-arms and refetches once logged back in",
              credentialsRestored(from: nil, to: renewed, now: now), true)
        check("auth: relaunch with the same expired token stays quiet",
              credentialsRestored(from: nil, to: expired, now: now), false)

        func usage(fiveHour: Any?, sevenDay: Any?) -> UsageSnapshot {
            var snap = UsageSnapshot()
            snap.fiveHour = bucket(fiveHour)
            snap.sevenDay = bucket(sevenDay)
            return snap
        }
        let weekly: [String: Any] = ["utilization": 12, "resets_at": "2026-11-05T01:00:00.000000+00:00"]
        check("limits: null five_hour beside a weekly window means no five-hour limit",
              usage(fiveHour: NSNull(), sevenDay: weekly).lacksFiveHourLimit, true)
        check("limits: missing five_hour beside a weekly window means no five-hour limit",
              usage(fiveHour: nil, sevenDay: weekly).lacksFiveHourLimit, true)
        check("limits: idle five-hour window still counts as a five-hour limit",
              usage(fiveHour: ["utilization": 0, "resets_at": NSNull()], sevenDay: weekly).lacksFiveHourLimit, false)
        check("limits: active five-hour window counts as a five-hour limit",
              usage(fiveHour: ["utilization": 42, "resets_at": "2026-11-01T12:00:00+00:00"], sevenDay: weekly).lacksFiveHourLimit, false)
        check("limits: usage not loaded yet keeps the five-hour option",
              UsageSnapshot().lacksFiveHourLimit, false)

        check("plan: 20x rate tier reads as Ultra",
              planName(subscriptionType: "max", rateLimitTier: "default_claude_max_20x") == "Ultra", true)
        check("plan: 5x rate tier reads as Max",
              planName(subscriptionType: "max", rateLimitTier: "default_claude_max_5x") == "Max", true)
        check("plan: max without a rate tier reads as Max",
              planName(subscriptionType: "max", rateLimitTier: nil) == "Max", true)
        check("plan: pro stays Pro",
              planName(subscriptionType: "pro", rateLimitTier: "default_claude_pro") == "Pro", true)

        let resetPassed = now.addingTimeInterval(-60)
        let resetAhead = now.addingTimeInterval(3600)
        var lastFetched = UsageSnapshot()
        lastFetched.fiveHour = UsageBucket(percent: 80, resetsAt: resetPassed)
        lastFetched.sevenDay = UsageBucket(percent: 94, resetsAt: resetAhead)
        lastFetched.scopedWeekly = [ScopedBucket(label: "Opus", bucket: UsageBucket(percent: 30, resetsAt: resetPassed))]
        lastFetched.fetchedAt = now.addingTimeInterval(-3 * 3600)

        let rolled = lastFetched.rolledOver(at: now)
        check("reset: a window past its reset time reads 0% with no reset time",
              rolled.fiveHour?.percent == 0 && rolled.fiveHour?.resetsAt == nil, true)
        check("reset: a window before its reset time keeps its usage",
              rolled.sevenDay?.percent == 94 && rolled.sevenDay?.resetsAt == resetAhead, true)
        check("reset: model weekly windows roll over too",
              rolled.scopedWeekly.first?.bucket.percent == 0, true)
        check("reset: a window without a reset time keeps its usage",
              UsageBucket(percent: 12, resetsAt: nil).rolledOver(at: now).percent == 12, true)
        check("reset: a rolled-over five-hour window still counts as a five-hour limit",
              rolled.lacksFiveHourLimit, false)

        let paused = pausedForAuth(lastFetched, plan: "Ultra", message: "Session expired. Log in to Claude Code.")
        check("auth: an expired token keeps the last usage on screen",
              paused.hasData && paused.sevenDay?.percent == 94, true)
        check("auth: an expired token keeps the last update time",
              paused.fetchedAt == lastFetched.fetchedAt, true)
        check("auth: an expired token marks the account auth-blocked", paused.authBlocked == true, true)

        func fetched(secondsAgo: TimeInterval) -> UsageSnapshot {
            var snap = UsageSnapshot()
            snap.fetchedAt = now.addingTimeInterval(-secondsAgo)
            return snap
        }
        check("freshness: usage fetched 3 minutes ago reads as live", fetched(secondsAgo: 180).isStale(at: now), false)
        check("freshness: usage fetched 3 hours ago reads as stale", fetched(secondsAgo: 3 * 3600).isStale(at: now), true)
        check("freshness: usage never fetched is not stale", UsageSnapshot().isStale(at: now), false)

        print(ok ? "SELFTEST(usage): all passed" : "SELFTEST(usage): FAILURES present")
        return ok
    }

    static func probeAuthRecoveryDiagnostic() {
        setvbuf(stdout, nil, _IONBF, 0)

        let dir = NSTemporaryDirectory() + "claudance-auth-probe"
        let service = AccountRegistry.keychainService(forConfigDir: dir)
        let account = Account(configDir: dir, keychainService: service, email: "auth-probe@example.com",
                              accountUuid: "auth-probe", isDefault: false, billingType: nil,
                              organizationType: "claude_max", organizationRateLimitTier: nil,
                              organizationUuid: nil, subscriptionType: "max", rateLimitTier: nil)

        func security(_ arguments: [String]) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            p.arguments = arguments
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
        func signIn(token: String, expiresIn: Double) {
            let expiresAt = Int((Date().timeIntervalSince1970 + expiresIn) * 1000)
            security(["add-generic-password", "-U", "-s", service, "-a", "claudance-probe", "-w",
                      "{\"claudeAiOauth\":{\"accessToken\":\"\(token)\",\"expiresAt\":\(expiresAt),\"subscriptionType\":\"max\"}}"])
        }

        print("simulating an expired session for \(service)")
        signIn(token: "probe-expired-token", expiresIn: -3600)
        defer { security(["delete-generic-password", "-s", service]) }

        let monitor = UsageMonitor()
        defer { monitor.forget(account.key) }
        let expiredMessage = "Session expired. Log in to Claude Code."
        let idleHold: TimeInterval = 6
        var expiredAt: TimeInterval?
        var loginAt: TimeInterval?
        var refetchedAt: TimeInterval?
        var refetchesWhileUntouched = 0

        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            let now = Date().timeIntervalSince1970
            monitor.refresh(now: now, accounts: [account])
            let message = monitor.snapshot(forKey: account.key)?.statusMessage

            guard let reachedAt = expiredAt else {
                guard message == expiredMessage else { return }
                expiredAt = now
                print("  expired: \"\(expiredMessage)\" — the 120s auth backoff starts here")
                print(String(format: "  holding %.0fs with the keychain untouched, expecting no API calls", idleHold))
                return
            }
            guard let loginAt else {
                if message != expiredMessage { refetchesWhileUntouched += 1 }
                guard now - reachedAt >= idleHold else { return }
                print("  untouched-credential refetches: \(refetchesWhileUntouched) (want 0)")
                print("  writing fresh credentials to the keychain, as a Claude Code login does")
                signIn(token: "probe-live-token", expiresIn: 3600)
                loginAt = now
                return
            }
            if message != expiredMessage, refetchedAt == nil {
                refetchedAt = now
                print(String(format: "  refetched %.2fs after login → \"%@\"", now - loginAt, message ?? "usage loaded"))
            }
        }
        RunLoop.current.add(timer, forMode: .default)
        let deadline = Date().addingTimeInterval(40)
        while refetchedAt == nil, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        timer.invalidate()

        let recovered = refetchedAt != nil && refetchesWhileUntouched == 0
        print(recovered ? "PROBE: recovered on login, quiet while expired"
                        : "PROBE: FAILED — refetch=\(refetchedAt != nil), stray calls=\(refetchesWhileUntouched)")
    }

    static func printDiagnostic() {
        setvbuf(stdout, nil, _IONBF, 0)
        let accounts = AccountRegistry.discover()
        print("usage for \(accounts.count) account(s):")
        if mockExtraUsage != nil { print("  (CLAUDANCE_MOCK_CREDITS active — usage-credit rows are mocked)") }
        for account in accounts {
            print("• \(account.displayName)  [\(account.keychainService)]")
            guard let creds = readCredentials(service: account.keychainService) else {
                print("    not signed in")
                continue
            }
            print("    plan: \(planName(subscriptionType: creds.subscriptionType, rateLimitTier: creds.rateLimitTier) ?? "nil")")
            if isExpired(creds) {
                print("    token EXPIRED: no API call; the menu keeps the last fetched usage until Claude Code refreshes the token")
                print("    watching \(AccountRegistry.credentialStoreURL.lastPathComponent) — a re-login refetches within a tick")
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
                    print("    usage credits: \(snap.extraUsage.map { "\($0.percent)%" } ?? "n/a")  used=\(snap.extraUsageUsed?.text ?? "nil")  limit=\(snap.extraUsageLimit?.text ?? "unlimited")")
                } else {
                    print("    usage credits: off (extra_usage.is_enabled=false) → Usage credits / API rows hidden")
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
