import AppKit

final class ClawdBar {
    let key: String
    var configDir: String
    var displayName: String
    let statusItem: NSStatusItem
    let menu: NSMenu
    var animator = Animator()
    var lastSpec: ClawdDrawSpec?
    var lastMenuSignature: String?

    init(key: String, configDir: String, displayName: String, menu: NSMenu) {
        self.key = key
        self.configDir = configDir
        self.displayName = displayName
        self.menu = menu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imageScaling = .scaleNone
        statusItem.menu = menu
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private let monitor = SessionMonitor()
    private let usage = UsageMonitor()
    private let prefs = Preferences.shared

    private var bars: [String: ClawdBar] = [:]
    private var barOrder: [String] = []
    private var lastBarSignature: String?
    private var openMenuKey: String?

    private var timer: Timer?
    private var tick = 0
    private var lastTickTime: TimeInterval = 0
    private var colorMode: SpriteColorMode = .coral
    private var motionEnabled = true

    private var aboutWindow: NSWindow?
    private var preferencesController: PreferencesWindowController?

    private let imageSize = ClawdSprite.liveSize
    private static let frameInterval = 1.0 / 30.0
    private static let fallbackKey = "__fallback__"

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.global(qos: .utility).async {
            HookInstaller.ensureInstalled()
        }

        let now = Date().timeIntervalSince1970
        monitor.refresh(now: now)
        usage.refresh(now: now, accounts: monitor.accounts)
        lastTickTime = now
        applyPreferences()
        syncBars()
        renderAll(force: true)

        NotificationCenter.default.addObserver(forName: Preferences.didChange, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.applyPreferences()
            self.syncBars()
            self.renderAll(force: true)
            if let key = self.openMenuKey, let bar = self.bars[key] { self.rebuildMenu(for: bar) }
        }

        let t = Timer(timeInterval: Self.frameInterval, repeats: true) { [weak self] _ in
            self?.onTick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func onTick() {
        tick &+= 1
        let now = Date().timeIntervalSince1970
        let dt = lastTickTime == 0 ? Self.frameInterval : max(0, min(0.1, now - lastTickTime))
        lastTickTime = now

        if tick % 8 == 0 {
            monitor.refresh(now: now)
            usage.refresh(now: now, accounts: monitor.accounts)
        }

        syncBars()
        renderAll(force: false, dt: dt)

        if tick % 15 == 0, let key = openMenuKey, let bar = bars[key] {
            rebuildMenu(for: bar)
        }
    }

    private func applyPreferences() {
        colorMode = prefs.colorMode
        motionEnabled = prefs.motionEnabled
    }

    private func displayedAccounts() -> [(account: Account, snapshot: ActivitySnapshot)] {
        var result: [(account: Account, snapshot: ActivitySnapshot)] = []
        for account in monitor.accounts {
            guard prefs.showsClawd(forAccountKey: account.key) else { continue }
            let snap = monitor.byAccount[account.configDir] ?? ActivitySnapshot()
            result.append((account, snap))
            if result.count >= 3 { break }
        }
        return result
    }

    private func syncBars() {
        let displayed = displayedAccounts()
        var wanted = displayed.map { $0.account.key }
        if wanted.isEmpty { wanted = [Self.fallbackKey] }

        let signature = wanted.joined(separator: ",")
        if signature != lastBarSignature {
            lastBarSignature = signature

            for (key, bar) in bars where !wanted.contains(key) {
                NSStatusBar.system.removeStatusItem(bar.statusItem)
                bars[key] = nil
            }
            for key in wanted where bars[key] == nil {
                bars[key] = makeBar(key: key)
            }
            barOrder = wanted
        }

        for (account, _) in displayed {
            if let bar = bars[account.key] {
                bar.displayName = account.displayName
                bar.configDir = account.configDir
            }
        }
    }

    private func makeBar(key: String) -> ClawdBar {
        let menu = NSMenu()
        menu.delegate = self
        let bar = ClawdBar(key: key, configDir: "", displayName: "Claudance", menu: menu)
        rebuildMenu(for: bar)
        return bar
    }

    private func snapshot(for bar: ClawdBar) -> ActivitySnapshot {
        if bar.key == Self.fallbackKey { return monitor.aggregate }
        return monitor.byAccount[bar.configDir] ?? ActivitySnapshot()
    }

    private func renderAll(force: Bool, dt: Double = AppDelegate.frameInterval) {
        for key in barOrder {
            guard let bar = bars[key] else { continue }
            let snap = snapshot(for: bar)
            var spec = bar.animator.update(snap, dt: dt)
            if !motionEnabled && snap.state != .rest { spec = .standing }
            spec.colorMode = colorMode
            if !force, bar.lastSpec == spec { continue }
            bar.lastSpec = spec
            bar.statusItem.button?.image = ClawdSprite.image(spec, size: imageSize)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard let bar = bars.values.first(where: { $0.menu === menu }) else { return }
        openMenuKey = bar.key
        let now = Date().timeIntervalSince1970
        monitor.refresh(now: now)
        usage.refresh(now: now, accounts: monitor.accounts)
        rebuildMenu(for: bar)
    }

    func menuDidClose(_ menu: NSMenu) {
        openMenuKey = nil
    }

    private func menuSignature(for bar: ClawdBar) -> String {
        let s = snapshot(for: bar)
        var parts = ["\(bar.displayName)|\(s.state)|\(s.presentCount)|\(s.workingCount)|\(s.waitingCount)"]
        if bar.key != Self.fallbackKey, let u = usage.snapshot(forKey: bar.key) {
            let fh = u.fiveHour.map { "\($0.percent)/\($0.resetsAt?.timeIntervalSince1970 ?? 0)" } ?? "-"
            let wk = u.sevenDay.map { "\($0.percent)/\($0.resetsAt?.timeIntervalSince1970 ?? 0)" } ?? "-"
            let so = u.sonnet.map { "\($0.percent)" } ?? "-"
            parts.append("\(u.planName ?? "")|\(fh)|\(wk)|\(so)|\(u.statusMessage ?? "")")
        }
        let rows = SessionRow.allCases.map { prefs.isVisible($0) ? "1" : "0" }.joined()
            + UsageRow.allCases.map { prefs.isVisible($0) ? "1" : "0" }.joined()
        return parts.joined(separator: "#") + "#" + rows
    }

    private func rebuildMenu(for bar: ClawdBar) {
        let signature = menuSignature(for: bar)
        if signature == bar.lastMenuSignature, !bar.menu.items.isEmpty { return }
        bar.lastMenuSignature = signature

        let menu = bar.menu
        menu.removeAllItems()

        let isReal = bar.key != Self.fallbackKey

        if isReal {
            menu.addItem(makeHeaderItem(bar.displayName))
        }

        let hasContent = isReal

        if isReal {
            let sessions = sessionItems(snapshot(for: bar))
            sessions.forEach { menu.addItem($0) }

            if let usageSnap = usage.snapshot(forKey: bar.key) {
                let usageRows = usageItems(usageSnap)
                if !usageRows.isEmpty {
                    if !sessions.isEmpty { menu.addItem(.separator()) }
                    usageRows.forEach { menu.addItem($0) }
                }
            }
        }

        if hasContent { menu.addItem(.separator()) }

        let about = NSMenuItem(title: "About Claudance", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let prefsItem = NSMenuItem(title: "Preferences…", action: #selector(showPreferences), keyEquivalent: "")
        prefsItem.target = self
        menu.addItem(prefsItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
    }

    private func sessionItems(_ s: ActivitySnapshot) -> [NSMenuItem] {
        let total = s.presentCount
        let working = s.workingCount
        let waiting = s.waitingCount
        let idle = max(0, total - working - waiting)

        let raw: [(row: SessionRow, label: String, value: Int)] = [
            (.total, "Total", total), (.working, "Working", working),
            (.waiting, "Waiting", waiting), (.idle, "Idle", idle),
        ]
        let stats = raw.filter { prefs.isVisible($0.row) }.map { (label: $0.label, value: $0.value) }
        guard !stats.isEmpty else { return [] }

        func at(_ i: Int) -> (label: String, value: Int)? { i < stats.count ? stats[i] : nil }
        var items: [NSMenuItem] = [makeHeaderItem("Sessions")]
        if let row = sessionRowItem(left: at(0), right: at(1)) { items.append(row) }
        if let row = sessionRowItem(left: at(2), right: at(3)) { items.append(row) }
        return items
    }

    private func usageItems(_ s: UsageSnapshot) -> [NSMenuItem] {
        var rows: [NSMenuItem] = []
        if s.hasData, prefs.isVisible(UsageRow.plan), let plan = s.planName {
            rows.append(makeInfoItem(plan))
        }
        if prefs.isVisible(UsageRow.fiveHour), let b = s.fiveHour { rows.append(bucketItem("5-hour", b)) }
        if prefs.isVisible(UsageRow.weekly), let b = s.sevenDay { rows.append(bucketItem("Weekly", b)) }
        if prefs.isVisible(UsageRow.sonnet), let b = s.sonnet { rows.append(bucketItem("Sonnet", b)) }
        if let msg = s.statusMessage, !s.hasData { rows.append(makeInfoItem(msg)) }
        if rows.isEmpty { return [] }
        return [makeHeaderItem("Usage")] + rows
    }

    private func makeInfoItem(_ title: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func makeHeaderItem(_ title: String) -> NSMenuItem {
        let item = makeInfoItem()
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize)])
        return item
    }

    private static let gridParagraph: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.tabStops = [
            NSTextTab(textAlignment: .right, location: 137),
            NSTextTab(textAlignment: .left, location: 153),
            NSTextTab(textAlignment: .right, location: 290),
        ]
        return p
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d HH:mm"
        return f
    }()

    private func sessionRowItem(left: (label: String, value: Int)?, right: (label: String, value: Int)?) -> NSMenuItem? {
        guard let left else { return nil }
        var line = "\(left.label)\t\(left.value)"
        if let right { line += "\t\(right.label)\t\(right.value)" }
        let item = makeInfoItem()
        item.attributedTitle = NSAttributedString(string: line, attributes: [
            .font: NSFont.menuFont(ofSize: 0),
            .paragraphStyle: Self.gridParagraph,
        ])
        return item
    }

    private func bucketItem(_ label: String, _ b: UsageBucket) -> NSMenuItem {
        let resetValue = b.resetsAt.map { Self.resetString($0) } ?? "-"
        let line = "\(label)\t\(b.percent)%\tReset\t\(resetValue)"
        let item = makeInfoItem()
        item.attributedTitle = NSAttributedString(string: line, attributes: [
            .font: NSFont.menuFont(ofSize: 0),
            .paragraphStyle: Self.gridParagraph,
        ])
        return item
    }

    private static func resetString(_ date: Date) -> String {
        dateTimeFormatter.string(from: date)
    }

    @objc private func showPreferences() {
        NSApp.activate(ignoringOtherApps: true)
        if preferencesController == nil {
            preferencesController = PreferencesWindowController()
        }
        preferencesController?.show()
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)

        if let win = aboutWindow {
            win.center()
            win.makeKeyAndOrderFront(nil)
            return
        }

        let iconView = NSImageView(image: NSApp.applicationIconImage)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 96).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 96).isActive = true

        let nameLabel = NSTextField(labelWithString: "Claudance")
        nameLabel.font = .systemFont(ofSize: 14)
        nameLabel.alignment = .center

        let descLabel = NSTextField(labelWithString: "Claude Code monitor in your menu bar")
        descLabel.font = .systemFont(ofSize: 10)
        descLabel.textColor = .secondaryLabelColor
        descLabel.alignment = .center

        let stack = NSStackView(views: [iconView, nameLabel, descLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        let hPad: CGFloat = 44, vPad: CGFloat = 28
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: hPad),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -hPad),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: vPad),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -vPad),
        ])

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 220),
                           styleMask: [.titled, .closable],
                           backing: .buffered, defer: false)
        win.title = ""
        win.isReleasedWhenClosed = false
        win.contentView = container
        win.setContentSize(container.fittingSize)
        win.center()
        aboutWindow = win
        win.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
