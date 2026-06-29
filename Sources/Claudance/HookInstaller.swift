import Foundation

enum HookInstaller {

    private struct HookEvent {
        let name: String
        let state: String
        let needsMatcher: Bool
    }

    private static let events: [HookEvent] = [
        HookEvent(name: "SessionStart", state: "idle", needsMatcher: false),
        HookEvent(name: "UserPromptSubmit", state: "working", needsMatcher: false),
        HookEvent(name: "PostToolUse", state: "working", needsMatcher: true),
        HookEvent(name: "Notification", state: "waiting", needsMatcher: false),
        HookEvent(name: "Stop", state: "idle", needsMatcher: false),
        HookEvent(name: "SessionEnd", state: "end", needsMatcher: false),
    ]

    private static let hookScript = #"""
#!/bin/sh

dir="$HOME/.claude/claudance/sessions"
ev="$1"

payload=$(cat 2>/dev/null)

sid=$(printf '%s' "$payload" | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 | sed -n 's/.*"\([^"]*\)"$/\1/p')

sid=$(printf '%s' "$sid" | tr -cd 'A-Za-z0-9._-')
[ -z "$sid" ] && sid="default"

f="$dir/$sid.json"

case "$ev" in
  end)
    rm -f "$f" 2>/dev/null
    ;;
  working|idle|waiting)
    [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null
    tmp="$f.$$.tmp"
    printf '{"state":"%s","ts":%s}\n' "$ev" "$(date +%s)" > "$tmp" 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null
    ;;
  *)
    :
    ;;
esac

exit 0

"""#

    static func ensureInstalled(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let fm = FileManager.default
        let supportDir = home.appendingPathComponent(".claude/claudance", isDirectory: true)
        let sessionsDir = supportDir.appendingPathComponent("sessions", isDirectory: true)
        let hookURL = supportDir.appendingPathComponent("clawd-hook.sh")
        let settingsURL = home.appendingPathComponent(".claude/settings.json")

        try? fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        installHookScript(at: hookURL)
        installSettings(at: settingsURL, hookPath: hookURL.path)
    }

    private static func installHookScript(at url: URL) {
        let fm = FileManager.default
        let existing = try? String(contentsOf: url, encoding: .utf8)
        if existing != hookScript {
            try? hookScript.write(to: url, atomically: true, encoding: .utf8)
        }
        try? fm.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: url.path)
    }

    private static func installSettings(at url: URL, hookPath: String) {
        let fm = FileManager.default

        var settings: [String: Any] = [:]
        let fileExists = fm.fileExists(atPath: url.path)
        if fileExists {
            guard let data = try? Data(contentsOf: url),
                  let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                return
            }
            settings = parsed
        }

        if hooksAlreadyCurrent(settings, hookPath: hookPath) {
            return
        }

        var hooks = (settings["hooks"] as? [String: Any]) ?? [:]

        for (event, value) in hooks {
            guard var groups = value as? [[String: Any]] else { continue }
            groups.removeAll { isClawdGroup($0) }
            if groups.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = groups
            }
        }

        for event in events {
            var groups = (hooks[event.name] as? [[String: Any]]) ?? []
            var group: [String: Any] = [
                "hooks": [["type": "command", "command": expectedCommand(hookPath, event.state)]]
            ]
            if event.needsMatcher { group["matcher"] = "" }
            groups.append(group)
            hooks[event.name] = groups
        }

        settings["hooks"] = hooks

        guard JSONSerialization.isValidJSONObject(settings),
              let out = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        else { return }

        if fileExists {
            backup(url)
        } else {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try? out.write(to: url, options: .atomic)
    }

    private static func hooksAlreadyCurrent(_ settings: [String: Any], hookPath: String) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        for event in events {
            guard let groups = hooks[event.name] as? [[String: Any]] else { return false }
            let want = expectedCommand(hookPath, event.state)
            let found = groups.contains { group in
                guard let inner = group["hooks"] as? [[String: Any]] else { return false }
                return inner.contains { ($0["command"] as? String) == want }
            }
            if !found { return false }
        }
        return true
    }

    private static func isClawdGroup(_ group: [String: Any]) -> Bool {
        guard let inner = group["hooks"] as? [[String: Any]] else { return false }
        return inner.contains { ($0["command"] as? String)?.contains("clawd-hook.sh") == true }
    }

    private static func expectedCommand(_ hookPath: String, _ state: String) -> String {
        "\"\(hookPath)\" \(state)"
    }

    private static func backup(_ url: URL) {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = fmt.string(from: Date())
        let backupURL = URL(fileURLWithPath: url.path + ".clawd-backup-\(stamp)")
        try? FileManager.default.copyItem(at: url, to: backupURL)
    }
}
