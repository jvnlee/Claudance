import Foundation

struct UsageBucket: Codable {
    var percent: Int
    var resetsAt: Date?
}

struct UsageSnapshot: Codable {
    var signedIn = false
    var account: String?
    var planName: String?
    var fiveHour: UsageBucket?
    var sevenDay: UsageBucket?
    var sonnet: UsageBucket?
    var opus: UsageBucket?
    var fetchedAt: Date?
    var statusMessage: String?

    var hasData: Bool { fiveHour != nil || sevenDay != nil }
}

final class UsageMonitor {

    private let fm = FileManager.default
    private let queue = DispatchQueue(label: "com.hyunjunlee.claudance.usage", qos: .utility)

    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let userAgent = "Claudance/1.0"

    private let cacheMaxAge: TimeInterval = 180
    private let rateLimitBackoff: TimeInterval = 300
    private let errorBackoff: TimeInterval = 30
    private let authBackoff: TimeInterval = 120
    private let maxBackoff: TimeInterval = 900

    private var backoffUntil: TimeInterval = 0
    private var fetching = false

    private let cacheURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/claudance/usage-cache.json")

    private(set) var snapshot = UsageSnapshot()

    private struct CachedState: Codable {
        var snapshot: UsageSnapshot
        var backoffUntil: TimeInterval
    }

    init() {
        loadCache()
        if snapshot.account == nil { snapshot.account = Self.readAccountEmail() }
    }

    func refresh(now: TimeInterval) {
        if fetching { return }
        if now < backoffUntil { return }
        if let fetched = snapshot.fetchedAt?.timeIntervalSince1970 {
            let age = now - fetched
            if age >= 0 && age < cacheMaxAge { return }
        }
        fetching = true
        let prior = snapshot

        queue.async { [weak self] in
            guard let self else { return }
            let account = prior.account ?? Self.readAccountEmail()

            guard let creds = Self.readCredentials() else {
                var snap = prior
                snap.account = account
                snap.signedIn = false
                snap.fiveHour = nil; snap.sevenDay = nil; snap.sonnet = nil; snap.opus = nil
                snap.fetchedAt = nil
                snap.statusMessage = "Not signed in to Claude Code"
                self.publish(snap, backoff: self.errorBackoff)
                return
            }

            let plan = Self.planName(subscriptionType: creds.subscriptionType, rateLimitTier: creds.rateLimitTier)

            URLSession.shared.dataTask(with: Self.makeUsageRequest(token: creds.accessToken)) { [weak self] data, resp, _ in
                guard let self else { return }
                let http = resp as? HTTPURLResponse
                let code = http?.statusCode ?? -1

                var snap = prior
                snap.signedIn = true
                snap.account = account
                snap.planName = plan

                if code == 401 {
                    snap.fiveHour = nil; snap.sevenDay = nil; snap.sonnet = nil; snap.opus = nil
                    snap.fetchedAt = nil
                    snap.statusMessage = "Sign in to Claude Code to refresh"
                    self.publish(snap, backoff: self.authBackoff)
                    return
                }

                if code == 200, let data,
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   obj["five_hour"] != nil || obj["seven_day"] != nil {
                    snap.fiveHour = Self.bucket(obj["five_hour"])
                    snap.sevenDay = Self.bucket(obj["seven_day"])
                    snap.sonnet = Self.bucket(obj["seven_day_sonnet"])
                    snap.opus = Self.bucket(obj["seven_day_opus"])
                    snap.fetchedAt = Date()
                    snap.statusMessage = nil
                    self.publish(snap, backoff: 0)
                    return
                }

                snap.statusMessage = prior.hasData ? nil
                    : (code == 429 ? "Rate limited — retrying later" : "Usage temporarily unavailable")
                let retryAfter = http?.value(forHTTPHeaderField: "retry-after").flatMap(Double.init) ?? 0
                let backoff = code == 429 ? max(retryAfter, self.rateLimitBackoff) : self.errorBackoff
                self.publish(snap, backoff: backoff)
            }.resume()
        }
    }

    private func publish(_ snap: UsageSnapshot, backoff: TimeInterval) {
        let bounded = min(max(0, backoff), maxBackoff)
        DispatchQueue.main.async {
            self.snapshot = snap
            self.fetching = false
            self.backoffUntil = bounded > 0 ? Date().timeIntervalSince1970 + bounded : 0
            let until = self.backoffUntil
            self.queue.async { self.writeCache(snap, backoffUntil: until) }
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

    private func writeCache(_ snap: UsageSnapshot, backoffUntil: TimeInterval) {
        let state = CachedState(snapshot: snap, backoffUntil: backoffUntil)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? fm.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let state = try? JSONDecoder().decode(CachedState.self, from: data)
        else { return }
        snapshot = state.snapshot
        backoffUntil = min(state.backoffUntil, Date().timeIntervalSince1970 + maxBackoff)
    }

    static func makeUsageRequest(token: String) -> URLRequest {
        var req = URLRequest(url: usageURL)
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return req
    }

    struct Credentials {
        let accessToken: String
        let subscriptionType: String?
        let rateLimitTier: String?
    }

    static func readCredentials() -> Credentials? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
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
                           rateLimitTier: oauth["rateLimitTier"] as? String)
    }

    static func readAccountEmail() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["oauthAccount"] as? [String: Any]
        else { return nil }
        return (oauth["emailAddress"] as? String) ?? (oauth["displayName"] as? String)
    }

    static func planName(subscriptionType: String?, rateLimitTier: String?) -> String? {
        guard let sub = subscriptionType, !sub.isEmpty else { return nil }
        let base = sub.prefix(1).uppercased() + sub.dropFirst()
        if let tier = rateLimitTier,
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
        let creds = readCredentials()
        print("signed in:", creds != nil)
        print("account:", readAccountEmail() ?? "nil")
        print("plan:", planName(subscriptionType: creds?.subscriptionType, rateLimitTier: creds?.rateLimitTier) ?? "nil")

        guard let creds else { return }
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: makeUsageRequest(token: creds.accessToken)) { data, resp, _ in
            defer { sem.signal() }
            print("http:", (resp as? HTTPURLResponse)?.statusCode ?? -1)
            guard let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            for (key, label) in [("five_hour", "5-hour"), ("seven_day", "Weekly"),
                                 ("seven_day_sonnet", "Sonnet"), ("seven_day_opus", "Opus")] {
                if let b = bucket(obj[key]) {
                    var line = "\(label.padding(toLength: 7, withPad: " ", startingAt: 0)) \(b.percent)%"
                    if let r = b.resetsAt { line += "  ·  resets \(r)" }
                    print(line)
                } else {
                    print("\(label): null")
                }
            }
        }.resume()
        sem.wait()
    }
}
