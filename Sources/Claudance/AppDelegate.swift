import AppKit

final class ClawdBar {
    let key: String
    let isCluster: Bool
    let statusItem: NSStatusItem
    let menu: NSMenu

    var roster: [String] = []
    var members: [String] = []
    var animators: [String: Animator] = [:]
    var lastPlacements: [ClawdPlacement] = []
    var lastOverflow = -1
    var lastMenuSignature: String?
    var selectedMember: String?
    var pendingSelection: String?

    init(key: String, isCluster: Bool, menu: NSMenu) {
        self.key = key
        self.isCluster = isCluster
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

    private var clusterOrder = ClusterOrder()
    private var configDirByKey: [String: String] = [:]
    private var displayNameByKey: [String: String] = [:]
    private var cachedAdaptiveHex: (name: NSAppearance.Name, hex: String)?

    private var timer: Timer?
    private var tick = 0
    private var lastTickTime: TimeInterval = 0

    private var preferencesController: PreferencesWindowController?
    private lazy var bubbles = SpeechBubbleManager { [weak self] key in
        self?.openMenu(forAccountKey: key)
    }
    private let usageAlerts = UsageAlertTracker()

    private let imageSize = ClawdSprite.liveSize
    private static let frameInterval = 1.0 / 30.0
    private static let fallbackKey = "__fallback__"
    private static let clusterKey = "__cluster__"

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.global(qos: .utility).async {
            HookInstaller.ensureInstalled()
        }

        let now = Date().timeIntervalSince1970
        monitor.refresh(now: now)
        usage.refresh(now: now, accounts: monitor.accounts)
        lastTickTime = now
        syncBars(now: now, dt: Self.frameInterval)
        renderAll(force: true)

        NotificationCenter.default.addObserver(forName: Preferences.didChange, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            let now = Date().timeIntervalSince1970
            self.syncBars(now: now, dt: Self.frameInterval)
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
                guard let self, let key = self.rosterKeys().first,
                      let bar = self.bar(forAccountKey: key),
                      let anchor = self.anchor(forAccountKey: key, in: bar) else { return }
                let text = mockText == "1" ? "5-hour limit at 90%!" : mockText
                self.bubbles.showMock(key: key, anchor: anchor, text: text,
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

        syncBars(now: now, dt: dt)
        renderAll(force: false, dt: dt)
        updateBubbles(now: now)

        if tick % 15 == 0, let key = openMenuKey, let bar = bars[key] {
            rebuildMenu(for: bar)
        }
    }

    // MARK: - Bars

    private func syncBars(now: TimeInterval, dt: Double) {
        configDirByKey = Dictionary(monitor.accounts.map { ($0.key, $0.configDir) }, uniquingKeysWith: { a, _ in a })
        displayNameByKey = Dictionary(monitor.accounts.map { ($0.key, $0.displayName) }, uniquingKeysWith: { a, _ in a })

        let shown = monitor.accounts.filter { prefs.showsClawd(forAccountKey: $0.key) }
        let clustered = prefs.clusterMode && shown.count > 1

        let roster: [String]
        if clustered {
            clusterOrder.update(shown.map { ($0.key, snapshot(accountKey: $0.key)) }, now: now, dt: dt)
            roster = clusterOrder.order
        } else {
            roster = shown.prefix(Preferences.individualLimit).map(\.key)
        }

        let wanted: [String]
        if roster.isEmpty { wanted = [Self.fallbackKey] }
        else if clustered { wanted = [Self.clusterKey] }
        else { wanted = roster }

        let signature = wanted.joined(separator: ",")
        if signature != lastBarSignature {
            lastBarSignature = signature

            for (key, bar) in bars where !wanted.contains(key) {
                NSStatusBar.system.removeStatusItem(bar.statusItem)
                bars[key] = nil
            }
            for key in wanted where bars[key] == nil {
                bars[key] = makeBar(key: key, isCluster: key == Self.clusterKey)
            }
            barOrder = wanted
        }

        if clustered, let bar = bars[Self.clusterKey] {
            bar.roster = roster
            bar.members = Array(roster.prefix(Preferences.clusterLimit))
            bar.animators = bar.animators.filter { roster.contains($0.key) }
        } else {
            for key in wanted {
                guard let bar = bars[key] else { continue }
                bar.roster = key == Self.fallbackKey ? [] : [key]
                bar.members = bar.roster
            }
        }

        for key in wanted where bars[key]?.lastMenuSignature == nil {
            if let bar = bars[key] { rebuildMenu(for: bar) }
        }
    }

    private func makeBar(key: String, isCluster: Bool) -> ClawdBar {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        return ClawdBar(key: key, isCluster: isCluster, menu: menu)
    }

    private func rosterKeys() -> [String] {
        barOrder.compactMap { bars[$0] }.flatMap(\.roster)
    }

    private func bar(forAccountKey key: String) -> ClawdBar? {
        bars.values.first { $0.roster.contains(key) }
    }

    private func snapshot(accountKey: String) -> ActivitySnapshot {
        guard let dir = configDirByKey[accountKey] else { return ActivitySnapshot() }
        return monitor.byAccount[dir] ?? ActivitySnapshot()
    }

    private func displayName(accountKey: String) -> String {
        displayNameByKey[accountKey] ?? "Claudance"
    }

    // MARK: - Rendering

    private func renderAll(force: Bool, dt: Double = AppDelegate.frameInterval) {
        for key in barOrder {
            guard let bar = bars[key] else { continue }
            if bar.isCluster {
                renderCluster(bar, force: force, dt: dt)
            } else {
                renderSingle(bar, force: force, dt: dt)
            }
        }
    }

    private func renderSingle(_ bar: ClawdBar, force: Bool, dt: Double) {
        let key = bar.key
        let snap = key == Self.fallbackKey ? monitor.aggregate : snapshot(accountKey: key)
        let spec = pose(forAccountKey: key, snapshot: snap, bar: bar, dt: dt, adaptiveHex: nil)
        let placements = [ClawdPlacement(spec: spec, slot: 0)]

        guard force || placements != bar.lastPlacements || bar.lastOverflow != 0 else { return }
        bar.lastPlacements = placements
        bar.lastOverflow = 0

        let button = bar.statusItem.button
        button?.image = ClawdSprite.image(spec, size: imageSize)
        button?.title = ""
        button?.imagePosition = .imageOnly
    }

    private func adaptiveHex(for appearance: NSAppearance?) -> String {
        let target = appearance ?? NSApp.effectiveAppearance
        if let cached = cachedAdaptiveHex, cached.name == target.name { return cached.hex }
        let hex = ClawdTint.adaptiveHex(target)
        cachedAdaptiveHex = (target.name, hex)
        return hex
    }

    private func renderCluster(_ bar: ClawdBar, force: Bool, dt: Double) {
        let modes = bar.members.map { prefs.colorMode(forAccountKey: $0) }
        let mixed = modes.contains(.adaptive) && !modes.allSatisfy { $0 == .adaptive }
        let adaptiveHex = mixed ? adaptiveHex(for: bar.statusItem.button?.effectiveAppearance) : nil

        var placements: [ClawdPlacement] = []
        for key in bar.members {
            let slot = clusterOrder.slot(key)
            var spec = pose(forAccountKey: key, snapshot: snapshot(accountKey: key),
                            bar: bar, dt: dt, adaptiveHex: adaptiveHex)
            spec.dim = ClawdSprite.dim(forSlot: slot)
            placements.append(ClawdPlacement(spec: spec, slot: slot))
        }
        let overflow = bar.roster.count - bar.members.count

        guard force || placements != bar.lastPlacements || overflow != bar.lastOverflow else { return }
        bar.lastPlacements = placements
        bar.lastOverflow = overflow

        let button = bar.statusItem.button
        button?.image = ClawdSprite.clusterImage(placements, unit: imageSize)
        button?.title = overflow > 0 ? "+\(overflow)" : ""
        button?.imagePosition = overflow > 0 ? .imageLeading : .imageOnly
    }

    private func pose(forAccountKey key: String, snapshot snap: ActivitySnapshot,
                      bar: ClawdBar, dt: Double, adaptiveHex: String?) -> ClawdDrawSpec {
        var animator = bar.animators[key] ?? Animator()
        var spec = animator.update(snap, dt: dt)
        bar.animators[key] = animator

        if !prefs.motionEnabled(forAccountKey: key) && snap.state != .rest { spec = .standing }

        let mode = prefs.colorMode(forAccountKey: key)
        spec.colorMode = mode
        spec.customColorHex = mode == .custom ? prefs.customColorHex(forAccountKey: key) : nil
        spec.adaptiveColorHex = mode == .adaptive ? adaptiveHex : nil
        return spec
    }

    // MARK: - Geometry

    private func imageOriginX(_ button: NSStatusBarButton) -> CGFloat {
        let width = button.image?.size.width ?? 0
        if let cell = button.cell as? NSButtonCell {
            let rect = cell.imageRect(forBounds: button.bounds)
            if abs(rect.width - width) < 2 { return rect.minX }
        }
        return max(0, (button.bounds.width - width) / 2)
    }

    private func anchor(forAccountKey key: String, in bar: ClawdBar) -> BubbleAnchor? {
        guard let button = bar.statusItem.button, button.window != nil else { return nil }
        guard bar.isCluster, let index = bar.members.firstIndex(of: key) else {
            return BubbleAnchor(button: button, x: button.bounds.midX)
        }
        let x = imageOriginX(button) + CGFloat(index) * ClawdSprite.clusterStep + imageSize.width / 2
        return BubbleAnchor(button: button, x: x)
    }

    private func hitTestMember(_ bar: ClawdBar) -> String? {
        guard bar.members.count > 1,
              let button = bar.statusItem.button,
              let window = button.window else { return nil }
        let point = button.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        guard button.bounds.contains(point) else { return nil }
        let x = point.x - imageOriginX(button)
        let raw = Int(ceil((x - imageSize.width) / ClawdSprite.clusterStep))
        return bar.members[min(max(raw, 0), bar.members.count - 1)]
    }

    // MARK: - Bubbles

    private func openMenu(forAccountKey key: String) {
        guard let bar = bar(forAccountKey: key) else { return }
        if bar.isCluster { bar.pendingSelection = key }
        bar.statusItem.button?.performClick(nil)
    }

    private func updateBubbles(now: TimeInterval) {
        let keys = rosterKeys()
        bubbles.prune(activeKeys: keys)

        for key in keys {
            guard let bar = bar(forAccountKey: key) else { continue }
            let target = anchor(forAccountKey: key, in: bar)
            bubbles.update(key: key, anchor: target, now: now)

            guard openMenuKey != bar.key, let target,
                  let usageSnap = usage.snapshot(forKey: key) else { continue }
            var enabledThresholds = BubbleRow.thresholds
                .filter { prefs.isVisible($0, forAccountKey: key) }
                .map { $0.thresholdValue }
            if prefs.isVisible(BubbleRow.custom, forAccountKey: key) {
                enabledThresholds.append(prefs.customBubbleThreshold(forAccountKey: key))
            }
            let crossings = usageAlerts.evaluate(key: key, snapshot: usageSnap, enabled: enabledThresholds)
            if let top = crossings.max(by: { $0.threshold < $1.threshold }) {
                bubbles.announce(key: key, anchor: target, text: top.message,
                                 tint: tint(forAccountKey: key), now: now)
            }
        }
    }

    // MARK: - Menu

    func menuWillOpen(_ menu: NSMenu) {
        guard let bar = bars.values.first(where: { $0.menu === menu }) else { return }
        openMenuKey = bar.key
        for key in bar.roster { bubbles.hide(key: key) }
        if bar.isCluster {
            bar.selectedMember = bar.pendingSelection ?? hitTestMember(bar) ?? bar.roster.first
            bar.pendingSelection = nil
        }
        let now = Date().timeIntervalSince1970
        monitor.refresh(now: now)
        usage.refresh(now: now, accounts: monitor.accounts)
        rebuildMenu(for: bar)
    }

    func menuDidClose(_ menu: NSMenu) {
        openMenuKey = nil
    }

    private func accountSignature(_ key: String) -> String {
        let s = snapshot(accountKey: key)
        var parts = ["\(displayName(accountKey: key))|\(s.state)|\(s.presentCount)|\(s.workingCount)|\(s.waitingCount)"]
        if let u = usage.snapshot(forKey: key) {
            let fh = u.fiveHour.map { "\($0.percent)/\($0.resetsAt?.timeIntervalSince1970 ?? 0)" } ?? "-"
            let wk = u.sevenDay.map { "\($0.percent)/\($0.resetsAt?.timeIntervalSince1970 ?? 0)" } ?? "-"
            let so = (u.scopedWeekly.map { "\($0.label):\($0.bucket.percent)" }
                + [u.sonnet.map { "\($0.percent)" } ?? "-"]).joined(separator: ",")
            let cr = (u.hasExtraUsage || u.creditBalance != nil)
                ? "\(u.creditBalance?.minor ?? -1)/\(u.extraUsage?.percent ?? -1)/\(u.extraUsageUsed?.minor ?? -1)/\(u.extraUsageLimit?.minor ?? -1)"
                : "-"
            parts.append("\(u.planName ?? "")|\(fh)|\(wk)|\(so)|\(cr)|\(u.statusMessage ?? "")")
        }
        let rows = SessionRow.allCases.map { prefs.isVisible($0, forAccountKey: key) ? "1" : "0" }.joined()
            + UsageRow.allCases.map { prefs.isVisible($0, forAccountKey: key) ? "1" : "0" }.joined()
        let mode = prefs.colorMode(forAccountKey: key)
        let color = mode == .custom ? "custom:\(prefs.customColorHex(forAccountKey: key) ?? "")" : mode.rawValue
        return parts.joined(separator: "#") + "#" + rows + "#" + color
    }

    private func menuSignature(for bar: ClawdBar) -> String {
        if bar.isCluster {
            let members = bar.members.count
            let bodies = bar.roster.map(accountSignature).joined(separator: "@")
            return "cluster|\(members)|\(bar.selectedMember ?? "")|\(bodies)"
        }
        if bar.key == Self.fallbackKey {
            let s = monitor.aggregate
            return "fallback|\(s.state)|\(s.presentCount)|\(s.workingCount)|\(s.waitingCount)"
        }
        return accountSignature(bar.key)
    }

    private func rebuildMenu(for bar: ClawdBar) {
        let signature = menuSignature(for: bar)
        if signature == bar.lastMenuSignature, !bar.menu.items.isEmpty { return }
        bar.lastMenuSignature = signature

        let menu = bar.menu
        menu.removeAllItems()

        if bar.isCluster, !bar.roster.isEmpty {
            let item = NSMenuItem()
            item.view = ClusterPanelView(model: clusterPanelModel(for: bar)) { [weak self, weak bar] key in
                guard let self, let bar else { return }
                DispatchQueue.main.async {
                    bar.selectedMember = key
                    self.rebuildMenu(for: bar)
                }
            }
            menu.addItem(item)
            menu.addItem(.separator())
        } else if bar.key != Self.fallbackKey {
            let panel = NSMenuItem()
            panel.view = MenuPanelView(model: menuPanelModel(forAccountKey: bar.key))
            menu.addItem(panel)
            menu.addItem(.separator())
        }

        let prefsItem = NSMenuItem(title: "Preferences…", action: #selector(showPreferences(_:)), keyEquivalent: "")
        prefsItem.target = self
        prefsItem.representedObject = bar.isCluster ? bar.selectedMember : bar.key
        menu.addItem(prefsItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
    }

    private func clusterPanelModel(for bar: ClawdBar) -> ClusterPanelModel {
        let adaptiveHex = ClawdTint.adaptiveHex(NSApp.effectiveAppearance)
        let members = bar.roster.map { key -> ClusterPanelModel.Member in
            var chip = ClawdDrawSpec.standing
            let mode = prefs.colorMode(forAccountKey: key)
            chip.colorMode = mode
            chip.customColorHex = mode == .custom ? prefs.customColorHex(forAccountKey: key) : nil
            chip.adaptiveColorHex = mode == .adaptive ? adaptiveHex : nil
            return ClusterPanelModel.Member(key: key, name: displayName(accountKey: key),
                                            chip: chip, panel: menuPanelModel(forAccountKey: key))
        }
        return ClusterPanelModel(members: members,
                                 selectedKey: bar.selectedMember ?? bar.roster.first ?? "",
                                 summary: clusterSummary(bar))
    }

    private func clusterSummary(_ bar: ClawdBar) -> String {
        var working = 0
        var waiting = 0
        for key in bar.roster {
            let s = snapshot(accountKey: key)
            working += s.workingCount
            waiting += s.waitingCount
        }
        var parts = ["\(bar.roster.count) accounts"]
        if working > 0 { parts.append("\(working) working") }
        if waiting > 0 { parts.append("\(waiting) waiting") }
        if working == 0, waiting == 0 { parts.append("all idle") }
        return parts.joined(separator: " · ")
    }

    private func menuPanelModel(forAccountKey key: String) -> MenuPanelModel {
        let s = snapshot(accountKey: key)
        let idle = max(0, s.presentCount - s.workingCount - s.waitingCount)
        let raw: [(row: SessionRow, label: String, value: Int)] = [
            (.total, "Total", s.presentCount), (.working, "Working", s.workingCount),
            (.waiting, "Waiting", s.waitingCount), (.idle, "Idle", idle),
        ]
        let stats = raw.filter { prefs.isVisible($0.row, forAccountKey: key) }
            .map { MenuPanelModel.Stat(label: $0.label, value: "\($0.value)") }

        var planLine: String?
        var gauges: [MenuPanelModel.Gauge] = []
        var apiRows: [MenuPanelModel.Amount] = []
        var statusMessage: String?

        if let u = usage.snapshot(forKey: key) {
            let account = monitor.accounts.first { $0.key == key }
            if u.hasData {
                planLine = (account?.isSubscription ?? false) ? account?.planLabel : u.planName
            }
            func gauge(_ label: String, _ b: UsageBucket) -> MenuPanelModel.Gauge {
                MenuPanelModel.Gauge(label: label, percent: b.percent,
                                     reset: b.resetsAt.map(Self.resetString))
            }
            if prefs.isVisible(UsageRow.fiveHour, forAccountKey: key), let b = u.fiveHour { gauges.append(gauge("5-hour", b)) }
            if prefs.isVisible(UsageRow.weekly, forAccountKey: key), let b = u.sevenDay { gauges.append(gauge("Weekly", b)) }
            if prefs.isVisible(UsageRow.sonnet, forAccountKey: key) {
                if !u.scopedWeekly.isEmpty {
                    for scoped in u.scopedWeekly { gauges.append(gauge(scoped.label, scoped.bucket)) }
                } else if let b = u.sonnet {
                    gauges.append(gauge("Sonnet", b))
                }
            }
            if u.hasExtraUsage, prefs.isVisible(UsageRow.extraUsage, forAccountKey: key), let b = u.extraUsage {
                gauges.append(gauge("Extra usage", b))
            }
            if let m = u.creditBalance, prefs.isVisible(UsageRow.balance, forAccountKey: key) {
                apiRows.append(MenuPanelModel.Amount(label: "Balance", value: m.text))
            }
            if let m = u.extraUsageUsed, prefs.isVisible(UsageRow.used, forAccountKey: key) {
                apiRows.append(MenuPanelModel.Amount(label: "Used", value: m.text))
            }
            if u.hasExtraUsage, prefs.isVisible(UsageRow.monthlyCap, forAccountKey: key) {
                apiRows.append(MenuPanelModel.Amount(label: "Monthly Cap", value: u.extraUsageLimit?.text ?? "Unlimited"))
            }
            if let msg = u.statusMessage, !u.hasData, !u.hasExtraUsage { statusMessage = msg }
        }

        return MenuPanelModel(accountName: displayName(accountKey: key), stats: stats, planLine: planLine,
                              gauges: gauges, apiRows: apiRows, statusMessage: statusMessage,
                              tint: tint(forAccountKey: key))
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
