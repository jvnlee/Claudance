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

    private var preferencesController: PreferencesWindowController?
    private lazy var bubbles = SpeechBubbleManager { [weak self] key in
        self?.bars[key]?.statusItem.button?.performClick(nil)
    }
    private let usageAlerts = UsageAlertTracker()

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
        syncBars()
        renderAll(force: true)

        NotificationCenter.default.addObserver(forName: Preferences.didChange, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.syncBars()
            self.renderAll(force: true)
            if let key = self.openMenuKey, let bar = self.bars[key] { self.rebuildMenu(for: bar) }
        }

        let t = Timer(timeInterval: Self.frameInterval, repeats: true) { [weak self] _ in
            self?.onTick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        if let mockText = ProcessInfo.processInfo.environment["CLAUDANCE_MOCK_BUBBLE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, let key = self.barOrder.first,
                      let button = self.bars[key]?.statusItem.button else { return }
                let text = mockText == "1" ? "A session is waiting!" : mockText
                self.bubbles.showMock(key: key, button: button, text: text,
                                      tint: self.tint(forAccountKey: key))
            }
        }
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
        updateBubbles(now: now)

        if tick % 15 == 0, let key = openMenuKey, let bar = bars[key] {
            rebuildMenu(for: bar)
        }
    }

    private func updateBubbles(now: TimeInterval) {
        bubbles.prune(activeKeys: barOrder)
        for key in barOrder {
            guard let bar = bars[key] else { continue }
            let snap = snapshot(for: bar)
            bubbles.update(key: key,
                           button: bar.statusItem.button,
                           waiting: snap.waitingCount,
                           enabled: prefs.isVisible(BubbleRow.waiting, forAccountKey: key),
                           menuOpen: openMenuKey == key,
                           tint: tint(forAccountKey: key),
                           now: now)

            guard key != Self.fallbackKey, openMenuKey != key,
                  let usageSnap = usage.snapshot(forKey: key) else { continue }
            let enabledThresholds = BubbleRow.thresholds
                .filter { prefs.isVisible($0, forAccountKey: key) }
                .map { $0.thresholdValue }
            let crossings = usageAlerts.evaluate(key: key, snapshot: usageSnap, enabled: enabledThresholds)
            if let top = crossings.max(by: { $0.threshold < $1.threshold }),
               let button = bar.statusItem.button {
                bubbles.announce(key: key, button: button, text: top.message,
                                 tint: tint(forAccountKey: key), now: now)
            }
        }
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
        menu.autoenablesItems = false
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
            if !prefs.motionEnabled(forAccountKey: bar.key) && snap.state != .rest { spec = .standing }
            let mode = prefs.colorMode(forAccountKey: bar.key)
            spec.colorMode = mode
            spec.customColorHex = mode == .custom ? prefs.customColorHex(forAccountKey: bar.key) : nil
            if !force, bar.lastSpec == spec { continue }
            bar.lastSpec = spec
            bar.statusItem.button?.image = ClawdSprite.image(spec, size: imageSize)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard let bar = bars.values.first(where: { $0.menu === menu }) else { return }
        openMenuKey = bar.key
        bubbles.hide(key: bar.key)
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
            let fh = u.fiveHour.map { "\($0.percent)/\($0.resetsAt?.timeIntervalSince1970 ?? 0)/\($0.severity ?? "")" } ?? "-"
            let wk = u.sevenDay.map { "\($0.percent)/\($0.resetsAt?.timeIntervalSince1970 ?? 0)/\($0.severity ?? "")" } ?? "-"
            let so = (u.scopedWeekly.map { "\($0.label):\($0.bucket.percent):\($0.bucket.severity ?? "")" }
                + [u.sonnet.map { "\($0.percent)" } ?? "-"]).joined(separator: ",")
            let cr = (u.hasExtraUsage || u.creditBalance != nil)
                ? "\(u.creditBalance?.minor ?? -1)/\(u.extraUsage?.percent ?? -1)/\(u.extraUsageUsed?.minor ?? -1)/\(u.extraUsageLimit?.minor ?? -1)"
                : "-"
            parts.append("\(u.planName ?? "")|\(fh)|\(wk)|\(so)|\(cr)|\(u.statusMessage ?? "")")
        }
        let rows = SessionRow.allCases.map { prefs.isVisible($0, forAccountKey: bar.key) ? "1" : "0" }.joined()
            + UsageRow.allCases.map { prefs.isVisible($0, forAccountKey: bar.key) ? "1" : "0" }.joined()
        let mode = prefs.colorMode(forAccountKey: bar.key)
        let color = mode == .custom ? "custom:\(prefs.customColorHex(forAccountKey: bar.key) ?? "")" : mode.rawValue
        return parts.joined(separator: "#") + "#" + rows + "#" + color
    }

    private func rebuildMenu(for bar: ClawdBar) {
        let signature = menuSignature(for: bar)
        if signature == bar.lastMenuSignature, !bar.menu.items.isEmpty { return }
        bar.lastMenuSignature = signature

        let menu = bar.menu
        menu.removeAllItems()

        if bar.key != Self.fallbackKey {
            let panel = NSMenuItem()
            panel.view = MenuPanelView(model: menuPanelModel(for: bar))
            menu.addItem(panel)
            menu.addItem(.separator())
        }

        let prefsItem = NSMenuItem(title: "Preferences…", action: #selector(showPreferences(_:)), keyEquivalent: "")
        prefsItem.target = self
        prefsItem.representedObject = bar.key
        menu.addItem(prefsItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
    }

    private func menuPanelModel(for bar: ClawdBar) -> MenuPanelModel {
        let s = snapshot(for: bar)
        let idle = max(0, s.presentCount - s.workingCount - s.waitingCount)
        let raw: [(row: SessionRow, label: String, value: Int)] = [
            (.total, "Total", s.presentCount), (.working, "Working", s.workingCount),
            (.waiting, "Waiting", s.waitingCount), (.idle, "Idle", idle),
        ]
        let stats = raw.filter { prefs.isVisible($0.row, forAccountKey: bar.key) }
            .map { MenuPanelModel.Stat(label: $0.label, value: "\($0.value)") }

        var planLine: String?
        var gauges: [MenuPanelModel.Gauge] = []
        var apiRows: [MenuPanelModel.Amount] = []
        var statusMessage: String?

        if let u = usage.snapshot(forKey: bar.key) {
            let account = monitor.accounts.first { $0.key == bar.key }
            if u.hasData {
                planLine = (account?.isSubscription ?? false) ? account?.planLabel : u.planName
            }
            func gauge(_ label: String, _ b: UsageBucket) -> MenuPanelModel.Gauge {
                MenuPanelModel.Gauge(label: label, percent: b.percent,
                                     reset: b.resetsAt.map(Self.resetString), severity: b.severity)
            }
            if prefs.isVisible(UsageRow.fiveHour, forAccountKey: bar.key), let b = u.fiveHour { gauges.append(gauge("5-hour", b)) }
            if prefs.isVisible(UsageRow.weekly, forAccountKey: bar.key), let b = u.sevenDay { gauges.append(gauge("Weekly", b)) }
            if prefs.isVisible(UsageRow.sonnet, forAccountKey: bar.key) {
                if !u.scopedWeekly.isEmpty {
                    for scoped in u.scopedWeekly { gauges.append(gauge(scoped.label, scoped.bucket)) }
                } else if let b = u.sonnet {
                    gauges.append(gauge("Sonnet", b))
                }
            }
            if u.hasExtraUsage, prefs.isVisible(UsageRow.extraUsage, forAccountKey: bar.key), let b = u.extraUsage {
                gauges.append(gauge("Extra usage", b))
            }
            if let m = u.creditBalance, prefs.isVisible(UsageRow.balance, forAccountKey: bar.key) {
                apiRows.append(MenuPanelModel.Amount(label: "Balance", value: m.text))
            }
            if let m = u.extraUsageUsed, prefs.isVisible(UsageRow.used, forAccountKey: bar.key) {
                apiRows.append(MenuPanelModel.Amount(label: "Used", value: m.text))
            }
            if u.hasExtraUsage, prefs.isVisible(UsageRow.monthlyCap, forAccountKey: bar.key) {
                apiRows.append(MenuPanelModel.Amount(label: "Monthly Cap", value: u.extraUsageLimit?.text ?? "Unlimited"))
            }
            if let msg = u.statusMessage, !u.hasData, !u.hasExtraUsage { statusMessage = msg }
        }

        return MenuPanelModel(accountName: bar.displayName, stats: stats, planLine: planLine,
                              gauges: gauges, apiRows: apiRows, statusMessage: statusMessage,
                              tint: tint(forAccountKey: bar.key))
    }

    private func tint(forAccountKey key: String) -> NSColor {
        switch prefs.colorMode(forAccountKey: key) {
        case .coral: return ClawdColors.coral
        case .adaptive: return .controlAccentColor
        case .custom: return NSColor(clawdHex: prefs.customColorHex(forAccountKey: key)) ?? ClawdColors.coral
        }
    }

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d HH:mm"
        return f
    }()

    private static func resetString(_ date: Date) -> String {
        dateTimeFormatter.string(from: date)
    }

    @objc private func showPreferences(_ sender: NSMenuItem) {
        NSApp.activate(ignoringOtherApps: true)
        if preferencesController == nil {
            preferencesController = PreferencesWindowController(usage: usage)
        }
        let key = sender.representedObject as? String
        preferencesController?.show(focusAccountKey: key == Self.fallbackKey ? nil : key)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
