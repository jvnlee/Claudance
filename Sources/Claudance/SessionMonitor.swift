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

    private let stateDir: URL
    private let fm = FileManager.default

    private let queue = DispatchQueue(label: "com.hyunjunlee.claudance.monitor", qos: .utility)
    private var refreshing = false

    private var lastProcCheck: TimeInterval = 0
    private var cachedProcCount = 0
    private var lastTsBySession: [String: Double] = [:]
    private var lastRefresh: TimeInterval = 0
    private var rateEMA: Double = 0

    private let workingStaleWindow: TimeInterval = 900
    private let ttl: TimeInterval = 1800

    private(set) var snapshot = ActivitySnapshot()

    init() {
        let home = fm.homeDirectoryForCurrentUser
        stateDir = home.appendingPathComponent(".claude/claudance/sessions", isDirectory: true)
    }

    func refresh(now: TimeInterval) {
        if refreshing { return }
        refreshing = true
        queue.async { [weak self] in
            guard let self else { return }
            let snap = self.computeSnapshot(now: now)
            DispatchQueue.main.async {
                self.snapshot = snap
                self.refreshing = false
            }
        }
    }

    private func computeSnapshot(now: TimeInterval) -> ActivitySnapshot {
        if now - lastProcCheck > 0.9 {
            if let c = Self.claudeProcessCount() { cachedProcCount = c }
            lastProcCheck = now
        }
        let procCount = cachedProcCount

        let files = (try? fm.contentsOfDirectory(at: stateDir, includingPropertiesForKeys: nil)) ?? []
        let jsonFiles = files.filter { $0.pathExtension == "json" }

        if procCount == 0 {
            for url in jsonFiles { try? fm.removeItem(at: url) }
            lastTsBySession.removeAll()
            rateEMA = 0
            lastRefresh = now
            return ActivitySnapshot(state: .rest, presentCount: 0, workingCount: 0, activity: 0)
        }

        var working = 0
        var waiting = 0
        var present = 0
        var updates = 0
        var liveSessions = Set<String>()

        for url in jsonFiles {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let sid = url.deletingPathExtension().lastPathComponent
            let state = (obj["state"] as? String) ?? "idle"
            let ts = (obj["ts"] as? Double) ?? (obj["ts"] as? NSNumber)?.doubleValue ?? 0
            let age = now - ts

            if age > ttl {
                try? fm.removeItem(at: url)
                lastTsBySession[sid] = nil
                continue
            }

            liveSessions.insert(sid)
            present += 1

            if let prev = lastTsBySession[sid] {
                if ts > prev { updates += 1 }
            } else if state == "working" {
                updates += 1
            }
            lastTsBySession[sid] = ts

            switch state {
            case "working": if age < workingStaleWindow { working += 1 }
            case "waiting": waiting += 1
            default: break
            }
        }

        lastTsBySession = lastTsBySession.filter { liveSessions.contains($0.key) }

        let dt = lastRefresh == 0 ? 0.25 : max(0.05, now - lastRefresh)
        let instRate = Double(updates) / dt
        let normInst = min(1.0, instRate / 3.0)
        rateEMA = rateEMA * 0.6 + normInst * 0.4
        lastRefresh = now

        let state: ClaudeActivity
        if working > 0 { state = .working }
        else if waiting > 0 { state = .waiting }
        else { state = .idle }

        let countBoost = min(1.0, Double(working) / 3.0)
        let activity = state == .working ? max(0.45, 0.55 * rateEMA + 0.45 * countBoost) : 0

        return ActivitySnapshot(state: state,
                                presentCount: max(procCount, present),
                                workingCount: working,
                                waitingCount: waiting,
                                activity: activity)
    }

    static func claudeProcessCount() -> Int? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-x", "claude"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let s = String(data: data, encoding: .utf8) else { return 0 }
        return s.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }
}
