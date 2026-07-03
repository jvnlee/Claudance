import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private let monitor = SessionMonitor()
    private let usage = UsageMonitor()
    private let prefs = Preferences.shared
    private var animators: [String: Animator] = [:]
    private var fallbackAnimator = Animator()
    private var timer: Timer?
    private var tick = 0
    private var lastTickTime: TimeInterval = 0
    private var lastSpecs: [ClawdDrawSpec]?
    private var colorMode: SpriteColorMode = .coral
    private var motionEnabled = true

    private let imageSize = ClawdSprite.liveSize
    private static let frameInterval = 1.0 / 30.0

    private var sessionHeaderItem: NSMenuItem!
    private var sessionRow1Item: NSMenuItem!
    private var sessionRow2Item: NSMenuItem!
    private var usageSeparator: NSMenuItem!
    private var commandsSeparator: NSMenuItem!
    private var usageDynamicItems: [NSMenuItem] = []
    private var lastUsageSignature: String?
    private var aboutWindow: NSWindow?
    private var preferencesController: PreferencesWindowController?
    private var menuIsOpen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.global(qos: .utility).async {
            HookInstaller.ensureInstalled()
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imageScaling = .scaleNone
        buildMenu()

        let now = Date().timeIntervalSince1970
        monitor.refresh(now: now)
        usage.refresh(now: now, accounts: monitor.accounts)
        lastTickTime = now
        applyPreferences()
        render(force: true)
        updateStatusText()
        rebuildUsage(force: true)

        NotificationCenter.default.addObserver(forName: Preferences.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.applyPreferences()
            self?.render(force: true)
            self?.updateStatusText()
            self?.rebuildUsage(force: true)
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

        render(force: false, dt: dt)

        if tick % 15 == 0 && menuIsOpen {
            updateStatusText()
            rebuildUsage(force: false)
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
            guard let snap = monitor.byAccount[account.configDir] else { continue }
            result.append((account, snap))
            if result.count >= 3 { break }
        }
        return result
    }

    private func render(force: Bool, dt: Double = AppDelegate.frameInterval) {
        let displayed = displayedAccounts()
        var specs: [ClawdDrawSpec] = []

        if displayed.isEmpty {
            let snap = monitor.aggregate
            var spec = fallbackAnimator.update(snap, dt: dt)
            if !motionEnabled && snap.state != .rest { spec = .standing }
            spec.colorMode = colorMode
            specs = [spec]
        } else {
            for (account, snap) in displayed {
                var anim = animators[account.key] ?? Animator()
                var spec = anim.update(snap, dt: dt)
                animators[account.key] = anim
                if !motionEnabled && snap.state != .rest { spec = .standing }
                spec.colorMode = colorMode
                specs.append(spec)
            }
        }

        if !force, lastSpecs == specs { return }
        lastSpecs = specs

        statusItem.button?.image = ClawdSprite.composite(specs, size: imageSize)
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        sessionHeaderItem = makeHeaderItem("Sessions")
        menu.addItem(sessionHeaderItem)

        sessionRow1Item = makeInfoItem()
        sessionRow2Item = makeInfoItem()
        menu.addItem(sessionRow1Item)
        menu.addItem(sessionRow2Item)

        usageSeparator = .separator()
        menu.addItem(usageSeparator)

        commandsSeparator = .separator()
        menu.addItem(commandsSeparator)

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

        statusItem.menu = menu
    }

    private func makeInfoItem() -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
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

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        let now = Date().timeIntervalSince1970
        monitor.refresh(now: now)
        usage.refresh(now: now, accounts: monitor.accounts)
        updateStatusText()
        rebuildUsage(force: true)
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
    }

    private func updateStatusText() {
        let s = monitor.aggregate
        let total = s.presentCount
        let working = s.workingCount
        let waiting = s.waitingCount
        let idle = max(0, total - working - waiting)

        let stats: [(label: String, value: Int)] =
            [(SessionRow.total, "Total", total),
             (.working, "Working", working),
             (.waiting, "Waiting", waiting),
             (.idle, "Idle", idle)]
            .filter { prefs.isVisible($0.0) }
            .map { (label: $0.1, value: $0.2) }

        func at(_ i: Int) -> (label: String, value: Int)? { i < stats.count ? stats[i] : nil }
        setSessionRow(sessionRow1Item, left: at(0), right: at(1))
        setSessionRow(sessionRow2Item, left: at(2), right: at(3))
        sessionHeaderItem.isHidden = stats.isEmpty
    }

    private func rebuildUsage(force: Bool) {
        guard let menu = statusItem.menu else { return }

        let shownKeys = Array(usage.keys.filter { prefs.showsClawd(forAccountKey: $0) }.prefix(3))
        let signature = usageSignature(shownKeys)
        if !force, signature == lastUsageSignature {
            updateUsageSeparators()
            return
        }
        lastUsageSignature = signature

        for item in usageDynamicItems { menu.removeItem(item) }
        usageDynamicItems.removeAll()

        let items = buildUsageItems(shownKeys: shownKeys)
        var insertAt = menu.index(of: usageSeparator) + 1
        for item in items {
            menu.insertItem(item, at: insertAt)
            insertAt += 1
        }
        usageDynamicItems = items
        updateUsageSeparators()
    }

    private func updateUsageSeparators() {
        let usageVisible = !usageDynamicItems.isEmpty
        let sessionsVisible = !sessionHeaderItem.isHidden
        usageSeparator.isHidden = !(usageVisible && sessionsVisible)
        commandsSeparator.isHidden = !(usageVisible || sessionsVisible)
    }

    private func usageSignature(_ keys: [String]) -> String {
        var parts: [String] = []
        for key in keys {
            guard let s = usage.snapshot(forKey: key) else { continue }
            let fh = s.fiveHour.map { "\($0.percent)/\($0.resetsAt?.timeIntervalSince1970 ?? 0)" } ?? "-"
            let wk = s.sevenDay.map { "\($0.percent)/\($0.resetsAt?.timeIntervalSince1970 ?? 0)" } ?? "-"
            let so = s.sonnet.map { "\($0.percent)" } ?? "-"
            parts.append("\(key):\(s.account ?? ""):\(s.planName ?? ""):\(fh):\(wk):\(so):\(s.statusMessage ?? "")")
        }
        let rows = UsageRow.allCases.map { prefs.isVisible($0) ? "1" : "0" }.joined()
        return parts.joined(separator: "|") + "#" + rows
    }

    private func buildUsageItems(shownKeys: [String]) -> [NSMenuItem] {
        var blocks: [[NSMenuItem]] = []
        let multi = shownKeys.count > 1
        for key in shownKeys {
            guard let snap = usage.snapshot(forKey: key) else { continue }
            let block = usageBlock(snap, multi: multi)
            if !block.isEmpty { blocks.append(block) }
        }
        guard !blocks.isEmpty else { return [] }

        var items: [NSMenuItem] = [makeHeaderItem("Usage")]
        for (i, block) in blocks.enumerated() {
            if i > 0 { items.append(.separator()) }
            items.append(contentsOf: block)
        }
        return items
    }

    private func usageBlock(_ s: UsageSnapshot, multi: Bool) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let identityVisible = s.signedIn || s.hasData

        if identityVisible, let account = s.account, multi || prefs.isVisible(UsageRow.account) {
            let item = makeInfoItem()
            if multi {
                item.attributedTitle = NSAttributedString(string: account, attributes: [
                    .font: NSFont.boldSystemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize)])
            } else {
                item.title = account
            }
            items.append(item)
        }
        if identityVisible, prefs.isVisible(UsageRow.plan), let plan = s.planName {
            let item = makeInfoItem()
            item.title = plan
            items.append(item)
        }
        if prefs.isVisible(UsageRow.fiveHour), let b = s.fiveHour { items.append(bucketItem("5-hour", b)) }
        if prefs.isVisible(UsageRow.weekly), let b = s.sevenDay { items.append(bucketItem("Weekly", b)) }
        if prefs.isVisible(UsageRow.sonnet), let b = s.sonnet { items.append(bucketItem("Sonnet", b)) }
        if let msg = s.statusMessage, !s.hasData {
            let item = makeInfoItem()
            item.title = msg
            items.append(item)
        }
        return items
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

    private func setSessionRow(_ item: NSMenuItem, left: (label: String, value: Int)?, right: (label: String, value: Int)?) {
        guard let left else { item.isHidden = true; return }
        item.isHidden = false
        var line = "\(left.label)\t\(left.value)"
        if let right { line += "\t\(right.label)\t\(right.value)" }
        item.attributedTitle = NSAttributedString(string: line, attributes: [
            .font: NSFont.menuFont(ofSize: 0),
            .paragraphStyle: Self.gridParagraph,
        ])
    }

    private func bucketItem(_ label: String, _ b: UsageBucket) -> NSMenuItem {
        let item = makeInfoItem()
        let resetValue = b.resetsAt.map { Self.resetString($0) } ?? "-"
        let line = "\(label)\t\(b.percent)%\tReset\t\(resetValue)"
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
