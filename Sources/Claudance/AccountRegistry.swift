import Foundation
import CryptoKit

struct Account: Equatable {
    let configDir: String
    let keychainService: String
    let email: String?
    let accountUuid: String?
    let isDefault: Bool
    let billingType: String?
    let organizationType: String?
    let organizationRateLimitTier: String?
    let organizationUuid: String?
    let subscriptionType: String?
    let rateLimitTier: String?

    var key: String { accountUuid ?? configDir }

    var displayName: String {
        if let email, !email.isEmpty { return email }
        let base = (configDir as NSString).lastPathComponent
        return base
    }

    static let tierBySubscriptionType: [String: String] = [
        "pro": "Pro", "max": "Max", "team": "Team", "enterprise": "Enterprise",
    ]
    static let tierByOrganizationType: [String: String] = [
        "claude_pro": "Pro", "claude_max": "Max", "claude_team": "Team", "claude_enterprise": "Enterprise",
    ]

    var planTier: String? {
        if let s = subscriptionType, let t = Account.tierBySubscriptionType[s] { return t }
        if let o = organizationType, let t = Account.tierByOrganizationType[o] { return t }
        return nil
    }

    var isSubscription: Bool { planTier != nil }

    var planLabel: String? {
        guard let tier = planTier else { return nil }
        return tier == "Max" ? Account.maxPlanLabel(rateLimitTiers: [rateLimitTier, organizationRateLimitTier]) : tier
    }

    static func maxPlanLabel(rateLimitTiers: [String?]) -> String {
        for raw in rateLimitTiers {
            if let raw, let r = raw.range(of: "[0-9]+x", options: .regularExpression) {
                return raw[r] == "20x" ? "Ultra" : "Max"
            }
        }
        return "Max"
    }

    var kindLabel: String {
        isSubscription ? "Subscription\(planLabel.map { " (\($0))" } ?? "")" : "API"
    }
}

enum AccountRegistry {

    private static let fm = FileManager.default

    static var home: String { fm.homeDirectoryForCurrentUser.path }
    static var defaultConfigDir: String { home + "/.claude" }

    static func normalize(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if p == "~" {
            p = home
        } else if p.hasPrefix("~/") {
            p = home + String(p.dropFirst(1))
        }
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    static func keychainService(forConfigDir dir: String) -> String {
        let norm = normalize(dir)
        if norm == normalize(defaultConfigDir) {
            return "Claude Code-credentials"
        }
        let digest = SHA256.hash(data: Data(norm.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-" + hex.prefix(8)
    }

    static func claudeJSONURL(configDir: String, isDefault: Bool) -> URL {
        if isDefault {
            return URL(fileURLWithPath: home + "/.claude.json")
        }
        return URL(fileURLWithPath: normalize(configDir) + "/.claude.json")
    }

    struct Identity {
        var email: String?
        var uuid: String?
        var billingType: String?
        var organizationType: String?
        var organizationRateLimitTier: String?
        var organizationUuid: String?
    }

    static func readIdentity(configDir: String, isDefault: Bool) -> Identity {
        let url = claudeJSONURL(configDir: configDir, isDefault: isDefault)
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["oauthAccount"] as? [String: Any]
        else { return Identity() }
        let email = (oauth["emailAddress"] as? String) ?? (oauth["displayName"] as? String)
        return Identity(email: email,
                        uuid: oauth["accountUuid"] as? String,
                        billingType: oauth["billingType"] as? String,
                        organizationType: oauth["organizationType"] as? String,
                        organizationRateLimitTier: oauth["organizationRateLimitTier"] as? String,
                        organizationUuid: oauth["organizationUuid"] as? String)
    }

    static let credentialStoreURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Keychains/login.keychain-db")

    static func credentialStoreStamp() -> String {
        guard let attrs = try? fm.attributesOfItem(atPath: credentialStoreURL.path),
              let modified = attrs[.modificationDate] as? Date
        else { return "" }
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        return "\(modified.timeIntervalSince1970)/\(size)"
    }

    static func credentialExists(service: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    static func discover() -> [Account] {
        var dirs: [String] = [normalize(defaultConfigDir)]
        if let entries = try? fm.contentsOfDirectory(atPath: home) {
            for name in entries.sorted() where name.hasPrefix(".claude") {
                let full = home + "/" + name
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue {
                    dirs.append(normalize(full))
                }
            }
        }

        var seen = Set<String>()
        var accounts: [Account] = []
        let defaultNorm = normalize(defaultConfigDir)

        for dir in dirs {
            if seen.contains(dir) { continue }
            seen.insert(dir)
            let service = keychainService(forConfigDir: dir)
            let creds = UsageMonitor.readCredentials(service: service)
            guard creds != nil || credentialExists(service: service) else { continue }
            let isDefault = (dir == defaultNorm)
            let identity = readIdentity(configDir: dir, isDefault: isDefault)
            accounts.append(Account(configDir: dir,
                                    keychainService: service,
                                    email: identity.email,
                                    accountUuid: identity.uuid,
                                    isDefault: isDefault,
                                    billingType: identity.billingType,
                                    organizationType: identity.organizationType,
                                    organizationRateLimitTier: identity.organizationRateLimitTier,
                                    organizationUuid: identity.organizationUuid,
                                    subscriptionType: creds?.subscriptionType,
                                    rateLimitTier: creds?.rateLimitTier))
        }
        return padWithMockAccounts(accounts)
    }

    private static func padWithMockAccounts(_ accounts: [Account]) -> [Account] {
        guard let raw = ProcessInfo.processInfo.environment["CLAUDANCE_MOCK_ACCOUNTS"],
              let target = Int(raw), target > accounts.count else { return accounts }
        var padded = accounts
        for i in accounts.count..<target {
            padded.append(Account(configDir: "/mock/.claude-mock\(i + 1)",
                                  keychainService: "Claudance-mock-\(i + 1)",
                                  email: "account\(i + 1)@example.com",
                                  accountUuid: "mock-\(i + 1)",
                                  isDefault: false,
                                  billingType: nil,
                                  organizationType: "claude_max",
                                  organizationRateLimitTier: nil,
                                  organizationUuid: nil,
                                  subscriptionType: "max",
                                  rateLimitTier: "default_claude_max_20x"))
        }
        return padded
    }

    static func runningProcessCommands() -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["axeww", "-o", "command="]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }

    static func parseConfigDir(fromPSCommand text: String) -> String? {
        for token in text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            if token.hasPrefix("CLAUDE_CONFIG_DIR=") {
                return normalize(String(token.dropFirst("CLAUDE_CONFIG_DIR=".count)))
            }
        }
        return nil
    }

    static func isSessionCommand(_ text: String) -> Bool {
        let tokens = text.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let binary = tokens.first, (binary.split(separator: "/").last ?? binary) == "claude" else { return false }
        guard tokens.count > 1 else { return true }
        switch tokens[1] {
        case "daemon", "bg-pty-host", "bg-spare": return false
        default: return !tokens.contains { $0 == "--bg-pty-host" || $0 == "--bg-spare" }
        }
    }

    static func activeConfigDirs() -> [String: Int] {
        let defaultNorm = normalize(defaultConfigDir)
        var counts: [String: Int] = [:]
        for command in runningProcessCommands() where isSessionCommand(command) {
            let dir = parseConfigDir(fromPSCommand: command) ?? defaultNorm
            counts[dir, default: 0] += 1
        }
        return counts
    }

    static func selfTest() -> Bool {
        var ok = true
        func check(_ label: String, _ got: String?, _ want: String?) {
            let pass = got == want
            if !pass { ok = false }
            print("  [\(pass ? "PASS" : "FAIL")] \(label): got=\(got ?? "nil") want=\(want ?? "nil")")
        }

        let home = self.home
        check("keychain: default dir",
              keychainService(forConfigDir: home + "/.claude"),
              "Claude Code-credentials")
        check("keychain: default dir trailing slash",
              keychainService(forConfigDir: home + "/.claude/"),
              "Claude Code-credentials")
        check("keychain: baeswi (verified on-machine)",
              keychainService(forConfigDir: "/Users/hyunjunlee/.claude-baeswi"),
              "Claude Code-credentials-9f86b64c")
        check("normalize: tilde",
              normalize("~/.claude-work"),
              home + "/.claude-work")
        check("normalize: trailing slash",
              normalize("/Users/x/.claude-work/"),
              "/Users/x/.claude-work")
        check("ps parse: CLAUDE_CONFIG_DIR present",
              parseConfigDir(fromPSCommand: "claude --dangerously-skip-permissions PATH=/usr/bin CLAUDE_CONFIG_DIR=/Users/hyunjunlee/.claude-baeswi TERM=xterm-256color"),
              "/Users/hyunjunlee/.claude-baeswi")
        check("ps parse: unset -> nil",
              parseConfigDir(fromPSCommand: "claude --resume PATH=/usr/bin TERM=xterm"),
              nil)
        check("ps parse: tilde value normalized",
              parseConfigDir(fromPSCommand: "claude CLAUDE_CONFIG_DIR=~/.claude-work X=1"),
              home + "/.claude-work")

        func kind(_ command: String) -> String { isSessionCommand(command) ? "session" : "skip" }
        check("session cmd: interactive",
              kind("claude --dangerously-skip-permissions PATH=/usr/bin TERM=xterm-256color"),
              "session")
        check("session cmd: bare",
              kind("claude"),
              "session")
        check("session cmd: full path binary",
              kind("/Users/x/.local/share/claude/ClaudeCode.app/Contents/MacOS/claude --resume abc"),
              "session")
        check("session cmd: daemon",
              kind("/Users/x/.local/bin/claude daemon run --json-path /Users/x/.claude/daemon.json --origin transient"),
              "skip")
        check("session cmd: bg pty host",
              kind("/Users/x/ClaudeCode.app/Contents/MacOS/claude --bg-pty-host /tmp/cc-daemon-501/a/pty/b.sock 215 57 -- /Users/x/versions/2.1.197 --session-id b --resume s.jsonl"),
              "skip")
        check("session cmd: retitled bg spare",
              kind("claude bg-spare --bg-spare /tmp/cc-daemon-501/a/spare/c.claim.sock"),
              "skip")
        check("session cmd: versioned bg session binary",
              kind("/Users/x/.local/share/claude/versions/2.1.197 --session-id b --fork-session --resume s.jsonl"),
              "skip")
        check("session cmd: unrelated process with claude in path",
              kind("/Users/x/.hermes/node/bin/node /Users/x/Dev/claude-code-mastery/node_modules/astro/bin/astro.mjs dev"),
              "skip")

        func account(sub: String? = nil, org: String? = nil, billing: String? = nil,
                     rateLimitTier: String? = nil, orgRateLimitTier: String? = nil) -> Account {
            Account(configDir: "/x", keychainService: "s", email: nil, accountUuid: nil, isDefault: false,
                    billingType: billing, organizationType: org, organizationRateLimitTier: orgRateLimitTier,
                    organizationUuid: nil, subscriptionType: sub, rateLimitTier: rateLimitTier)
        }
        check("kind: pro",
              account(sub: "pro", org: "claude_pro").kindLabel, "Subscription (Pro)")
        check("kind: max (5x rate tier)",
              account(sub: "max", org: "claude_max", rateLimitTier: "default_claude_max_5x").kindLabel, "Subscription (Max)")
        check("kind: ultra (20x rate tier)",
              account(sub: "max", org: "claude_max", rateLimitTier: "default_claude_max_20x").kindLabel, "Subscription (Ultra)")
        check("kind: ultra via org rate tier (no keychain rate tier)",
              account(sub: "max", org: "claude_max", orgRateLimitTier: "default_claude_max_20x").kindLabel, "Subscription (Ultra)")
        check("kind: max without any rate tier",
              account(sub: "max", org: "claude_max").kindLabel, "Subscription (Max)")
        check("kind: team (no multiplier despite max_5x rate tier)",
              account(sub: "team", org: "claude_team", rateLimitTier: "default_claude_max_5x").kindLabel, "Subscription (Team)")
        check("kind: enterprise via subscriptionType",
              account(sub: "enterprise").kindLabel, "Subscription (Enterprise)")
        check("kind: enterprise via org rescue (aws_marketplace billing, stale keychain)",
              account(sub: nil, org: "claude_enterprise", billing: "aws_marketplace").kindLabel, "Subscription (Enterprise)")
        check("kind: pro via org rescue (null subscriptionType)",
              account(sub: nil, org: "claude_pro").kindLabel, "Subscription (Pro)")
        check("kind: console API (no sub, non-claude org)",
              account(sub: nil, org: "api", billing: "usage_based").kindLabel, "API")
        check("kind: bare account (no signals)",
              account().kindLabel, "API")

        print(ok ? "SELFTEST: all passed" : "SELFTEST: FAILURES present")
        return ok
    }

    static func printDiagnostic() {
        let accounts = discover()
        print("discovered accounts: \(accounts.count)")
        for a in accounts {
            print("  • \(a.displayName)\(a.isDefault ? "  [default]" : "")")
            print("      configDir: \(a.configDir)")
            print("      keychain:  \(a.keychainService)")
            print("      uuid:      \(a.accountUuid ?? "nil")")
            print("      kind:      \(a.kindLabel)  (sub=\(a.subscriptionType ?? "nil"), org=\(a.organizationType ?? "nil"), billing=\(a.billingType ?? "nil"))")
        }
        let active = activeConfigDirs()
        print("running claude processes by config dir: \(active.values.reduce(0, +))")
        for (dir, n) in active.sorted(by: { $0.key < $1.key }) {
            let who = accounts.first { $0.configDir == dir }?.displayName ?? "(not a logged-in account)"
            print("  • \(dir)  ×\(n)  → \(who)")
        }
    }
}
