import Foundation
import CryptoKit

struct Account: Equatable {
    let configDir: String
    let keychainService: String
    let email: String?
    let accountUuid: String?
    let isDefault: Bool

    var key: String { accountUuid ?? configDir }

    var displayName: String {
        if let email, !email.isEmpty { return email }
        let base = (configDir as NSString).lastPathComponent
        return base
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
    }

    static func readIdentity(configDir: String, isDefault: Bool) -> Identity {
        let url = claudeJSONURL(configDir: configDir, isDefault: isDefault)
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["oauthAccount"] as? [String: Any]
        else { return Identity() }
        let email = (oauth["emailAddress"] as? String) ?? (oauth["displayName"] as? String)
        return Identity(email: email, uuid: oauth["accountUuid"] as? String)
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
            guard credentialExists(service: service) else { continue }
            let isDefault = (dir == defaultNorm)
            let identity = readIdentity(configDir: dir, isDefault: isDefault)
            accounts.append(Account(configDir: dir,
                                    keychainService: service,
                                    email: identity.email,
                                    accountUuid: identity.uuid,
                                    isDefault: isDefault))
        }
        return accounts
    }

    static func runningClaudePIDs() -> [Int] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-x", "claude"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    static func configDir(forPID pid: Int) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["eww", "-o", "command=", "-p", String(pid)]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return parseConfigDir(fromPSCommand: String(decoding: data, as: UTF8.self))
    }

    static func parseConfigDir(fromPSCommand text: String) -> String? {
        for token in text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            if token.hasPrefix("CLAUDE_CONFIG_DIR=") {
                return normalize(String(token.dropFirst("CLAUDE_CONFIG_DIR=".count)))
            }
        }
        return nil
    }

    static func activeConfigDirs() -> [String: Int] {
        let defaultNorm = normalize(defaultConfigDir)
        var counts: [String: Int] = [:]
        for pid in runningClaudePIDs() {
            let dir = configDir(forPID: pid) ?? defaultNorm
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
        }
        let active = activeConfigDirs()
        print("running claude processes by config dir: \(active.values.reduce(0, +))")
        for (dir, n) in active.sorted(by: { $0.key < $1.key }) {
            let who = accounts.first { $0.configDir == dir }?.displayName ?? "(not a logged-in account)"
            print("  • \(dir)  ×\(n)  → \(who)")
        }
    }
}
