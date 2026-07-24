import Foundation

enum ClaudeActivity {
    case rest
    case idle
    case waiting
    case working
}

struct ActivitySnapshot {
    var state: ClaudeActivity = .rest
    var presentCount: Int = 0
    var workingCount: Int = 0
    var waitingCount: Int = 0
    var activity: Double = 0
}

final class SessionMonitor {

    private let sinkDir: URL
    private let fm = FileManager.default

    private let queue = DispatchQueue(label: "com.hyunjunlee.claudance.monitor", qos: .utility)
    private var refreshing = false

    private var lastProcCheck: TimeInterval = 0
    private var activeCounts: [String: Int] = [:]
    private var lastDiscovery: TimeInterval = 0
    private var discovered: [Account] = []

    private var lastTsBySession: [String: Double] = [:]
    private var rateEMAByDir: [String: Double] = [:]
    private var lastRefresh: TimeInterval = 0

    private let workingStaleWindow: TimeInterval = 900
    private let ttl: TimeInterval = 1800
    private let discoveryInterval: TimeInterval = 15
    private let purgeGrace: TimeInterval = 10
    private var missingSince: [String: TimeInterval] = [:]

    private(set) var byAccount: [String: ActivitySnapshot] = [:]
    private(set) var aggregate = ActivitySnapshot()
    private(set) var accounts: [Account] = []

    init() {
        let home = fm.homeDirectoryForCurrentUser
        sinkDir = home.appendingPathComponent(".claude/claudance/sessions", isDirectory: true)
    }

    func refresh(now: TimeInterval) {
        if refreshing { return }
        refreshing = true
        queue.async { [weak self] in
            guard let self else { return }
            let (byAccount, aggregate) = self.computeSnapshot(now: now)
            let accounts = self.discovered
            DispatchQueue.main.async {
                self.byAccount = byAccount
                self.aggregate = aggregate
                self.accounts = accounts
                self.refreshing = false
            }
        }
    }

    private struct SessionFile {
        let sid: String
        let state: String
        let ts: Double
        let url: URL
    }

    func computeSnapshot(now: TimeInterval) -> ([String: ActivitySnapshot], ActivitySnapshot) {
        if now - lastProcCheck > 2.0 {
            activeCounts = AccountRegistry.activeConfigDirs()
            lastProcCheck = now
        }
        if now - lastDiscovery > discoveryInterval || discovered.isEmpty {
            discovered = AccountRegistry.discover()
            lastDiscovery = now
        }
        let counts = activeCounts

        let files = (try? fm.contentsOfDirectory(at: sinkDir, includingPropertiesForKeys: nil)) ?? []
        let jsonFiles = files.filter { $0.pathExtension == "json" }

        let defaultDir = AccountRegistry.normalize(AccountRegistry.defaultConfigDir)
        var filesByDir: [String: [SessionFile]] = [:]

        for url in jsonFiles {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let sid = url.deletingPathExtension().lastPathComponent
            let state = (obj["state"] as? String) ?? "idle"
            let ts = (obj["ts"] as? Double) ?? (obj["ts"] as? NSNumber)?.doubleValue ?? 0
            let cfg = (obj["cfg"] as? String).map(AccountRegistry.normalize) ?? defaultDir

            if now - ts > ttl {
                try? fm.removeItem(at: url)
                lastTsBySession[sid] = nil
                continue
            }
            filesByDir[cfg, default: []].append(SessionFile(sid: sid, state: state, ts: ts, url: url))
        }

        missingSince = missingSince.filter { counts[$0.key] == nil }
        for (dir, items) in filesByDir where counts[dir] == nil {
            let since = missingSince[dir] ?? now
            missingSince[dir] = since
            guard now - since >= purgeGrace else { continue }
            for it in items {
                try? fm.removeItem(at: it.url)
                lastTsBySession[it.sid] = nil
            }
            rateEMAByDir[dir] = nil
        }

        let dt = lastRefresh == 0 ? 0.25 : max(0.05, now - lastRefresh)
        lastRefresh = now

        var byAccount: [String: ActivitySnapshot] = [:]
        var liveSids = Set<String>()
        for (dir, procCount) in counts {
            let items = filesByDir[dir] ?? []
            byAccount[dir] = snapshot(dir: dir, items: items, procCount: procCount, now: now, dt: dt, live: &liveSids)
        }

        lastTsBySession = lastTsBySession.filter { liveSids.contains($0.key) }
        rateEMAByDir = rateEMAByDir.filter { counts[$0.key] != nil }

        Self.addMockActivity(&byAccount, now: now)

        return (byAccount, combine(byAccount.values))
    }

    private static func addMockActivity(_ byAccount: inout [String: ActivitySnapshot], now: TimeInterval) {
        guard let raw = ProcessInfo.processInfo.environment["CLAUDANCE_MOCK_ACCOUNTS"],
              let target = Int(raw), target > 0 else { return }
        for i in 1...target {
            let dir = "/mock/.claude-mock\(i)"
            let phase = (now / 7.0 + Double(i) * 0.37).truncatingRemainder(dividingBy: 4.0)
            let state: ClaudeActivity
            switch Int(phase) {
            case 0: state = .working
            case 1: state = .waiting
            case 2: state = .idle
            default: state = .rest
            }
            let activity = state == .working ? 0.35 + 0.65 * abs(sin(now * 0.8 + Double(i))) : 0
            byAccount[dir] = ActivitySnapshot(state: state,
                                              presentCount: state == .rest ? 0 : 3,
                                              workingCount: state == .working ? 2 : 0,
                                              waitingCount: state == .waiting ? 1 : 0,
                                              activity: activity)
        }
    }

    private func snapshot(dir: String, items: [SessionFile], procCount: Int, now: TimeInterval,
                          dt: TimeInterval, live: inout Set<String>) -> ActivitySnapshot {
        var working = 0
        var waiting = 0
        var present = 0
        var updates = 0

        for it in items {
            let age = now - it.ts
            live.insert(it.sid)
            present += 1

            if let prev = lastTsBySession[it.sid] {
                if it.ts > prev { updates += 1 }
            } else if it.state == "working" {
                updates += 1
            }
            lastTsBySession[it.sid] = it.ts

            switch it.state {
            case "working": if age < workingStaleWindow { working += 1 }
            case "waiting": waiting += 1
            default: break
            }
        }

        let instRate = Double(updates) / dt
        let normInst = min(1.0, instRate / 3.0)
        var ema = rateEMAByDir[dir] ?? 0
        ema = ema * 0.6 + normInst * 0.4
        rateEMAByDir[dir] = ema

        let state: ClaudeActivity
        if working > 0 { state = .working }
        else if waiting > 0 { state = .waiting }
        else { state = .idle }

        let countBoost = min(1.0, Double(working) / 3.0)
        let activity = state == .working ? max(0.45, 0.55 * ema + 0.45 * countBoost) : 0

        return ActivitySnapshot(state: state,
                                presentCount: max(procCount, present),
                                workingCount: working,
                                waitingCount: waiting,
                                activity: activity)
    }

    static func printDiagnostic() {
        let m = SessionMonitor()
        let now = Date().timeIntervalSince1970
        let (byAccount, aggregate) = m.computeSnapshot(now: now)
        let accounts = m.discovered
        let prefs = Preferences.shared

        print("accounts discovered: \(accounts.count), active dirs: \(byAccount.count)")
        for (dir, s) in byAccount.sorted(by: { $0.key < $1.key }) {
            let who = accounts.first { $0.configDir == dir }?.displayName ?? dir
            print("  • \(who): state=\(s.state) present=\(s.presentCount) working=\(s.workingCount) waiting=\(s.waitingCount) activity=\(String(format: "%.2f", s.activity))")
        }
        print("aggregate: state=\(aggregate.state) present=\(aggregate.presentCount) working=\(aggregate.workingCount) waiting=\(aggregate.waitingCount)")

        let limit = prefs.clusterMode ? prefs.clusterLimit : Int.max
        var displayed: [String] = []
        for a in accounts {
            guard prefs.showsClawd(forAccountKey: a.key) else { continue }
            let active = byAccount[a.configDir] != nil
            displayed.append("\(a.displayName)\(active ? "" : " (resting)")")
            if displayed.count >= limit { break }
        }
        let mode = prefs.clusterMode ? "cluster" : "individual"
        print("menu bar (\(mode)) would draw \(displayed.isEmpty ? 1 : displayed.count) clawd(s): \(displayed.isEmpty ? "[resting fallback]" : displayed.joined(separator: ", "))")
    }

    private func combine(_ snaps: Dictionary<String, ActivitySnapshot>.Values) -> ActivitySnapshot {
        var present = 0
        var working = 0
        var waiting = 0
        var maxActivity = 0.0
        for s in snaps {
            present += s.presentCount
            working += s.workingCount
            waiting += s.waitingCount
            maxActivity = max(maxActivity, s.activity)
        }
        let state: ClaudeActivity
        if working > 0 { state = .working }
        else if waiting > 0 { state = .waiting }
        else if present > 0 { state = .idle }
        else { state = .rest }
        return ActivitySnapshot(state: state,
                                presentCount: present,
                                workingCount: working,
                                waitingCount: waiting,
                                activity: maxActivity)
    }
}
