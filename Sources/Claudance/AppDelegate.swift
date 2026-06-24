import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private let monitor = SessionMonitor()
    private let usage = UsageMonitor()
    private let prefs = Preferences.shared
    private var animator = Animator()
    private var timer: Timer?
    private var tick = 0
    private var lastTickTime: TimeInterval = 0
    private var lastSpec: ClawdDrawSpec?
    private var colorMode: SpriteColorMode = .coral
    private var motionEnabled = true

    private let imageSize = ClawdSprite.liveSize
    private static let frameInterval = 1.0 / 30.0

    private var statusMenuItem: NSMenuItem!
    private var usageHeaderItem: NSMenuItem!
    private var accountItem: NSMenuItem!
    private var planItem: NSMenuItem!
    private var fiveHourItem: NSMenuItem!
    private var weekItem: NSMenuItem!
    private var sonnetItem: NSMenuItem!
    private var usageNoteItem: NSMenuItem!
    private var usageSeparator: NSMenuItem!
    private var aboutWindow: NSWindow?
    private var preferencesController: PreferencesWindowController?
    private var menuIsOpen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imageScaling = .scaleNone
        buildMenu()

        let now = Date().timeIntervalSince1970
        monitor.refresh(now: now)
        usage.refresh(now: now)
        lastTickTime = now
        applyPreferences()
        render(force: true)
        updateStatusText()
        updateUsageText()

        NotificationCenter.default.addObserver(forName: Preferences.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.applyPreferences()
            self?.render(force: true)
            self?.updateUsageText()
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
            usage.refresh(now: now)
        }

        render(force: false, dt: dt)

        if tick % 15 == 0 && menuIsOpen {
            updateStatusText()
            updateUsageText()
        }
    }

    private func applyPreferences() {
        colorMode = prefs.colorMode
        motionEnabled = prefs.motionEnabled
    }

    private func render(force: Bool, dt: Double = AppDelegate.frameInterval) {
        let snap = monitor.snapshot
        var spec = animator.update(snap, dt: dt)

        if !motionEnabled && snap.state != .rest {
            spec = .standing
        }
        spec.colorMode = colorMode

        if !force, lastSpec == spec { return }
        lastSpec = spec

        statusItem.button?.image = ClawdSprite.image(spec, size: imageSize)
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        statusMenuItem = NSMenuItem(title: "…", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        usageSeparator = .separator()
        menu.addItem(usageSeparator)

        usageHeaderItem = makeInfoItem()
        usageHeaderItem.attributedTitle = NSAttributedString(
            string: "Usage",
            attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize)])
        menu.addItem(usageHeaderItem)

        accountItem = makeInfoItem()
        planItem = makeInfoItem()
        fiveHourItem = makeInfoItem()
        weekItem = makeInfoItem()
        sonnetItem = makeInfoItem()
        usageNoteItem = makeInfoItem()
        for item in [accountItem, planItem, fiveHourItem, weekItem, sonnetItem, usageNoteItem] {
            menu.addItem(item!)
        }

        menu.addItem(.separator())

        let about = NSMenuItem(title: "About Claudance", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let prefsItem = NSMenuItem(title: "Preferences…", action: #selector(showPreferences), keyEquivalent: ",")
        prefsItem.keyEquivalentModifierMask = .command
        prefsItem.target = self
        menu.addItem(prefsItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func makeInfoItem() -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        let now = Date().timeIntervalSince1970
        monitor.refresh(now: now)
        usage.refresh(now: now)
        updateStatusText()
        updateUsageText()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
    }

    private func updateStatusText() {
        let s = monitor.snapshot
        let total = s.presentCount
        let working = s.workingCount
        let waiting = s.waitingCount
        let idle = max(0, total - working - waiting)
        statusMenuItem.title = "Total \(total) · Working \(working) · Waiting \(waiting) · Idle \(idle)"
    }

    private func updateUsageText() {
        let s = usage.snapshot
        let identityVisible = s.signedIn || s.hasData

        accountItem.isHidden = !prefs.isVisible(.account) || !identityVisible || s.account == nil
        accountItem.title = s.account ?? ""
        planItem.isHidden = !prefs.isVisible(.plan) || !identityVisible || s.planName == nil
        planItem.title = s.planName ?? ""

        setBucket(fiveHourItem, label: "5-hour", bucket: s.fiveHour, visible: prefs.isVisible(.fiveHour))
        setBucket(weekItem, label: "Weekly", bucket: s.sevenDay, visible: prefs.isVisible(.weekly))
        setBucket(sonnetItem, label: "Sonnet", bucket: s.sonnet, visible: prefs.isVisible(.sonnet))

        let noteVisible = s.statusMessage != nil && !s.hasData
        usageNoteItem.isHidden = !noteVisible
        usageNoteItem.title = s.statusMessage ?? ""

        let rows = [accountItem, planItem, fiveHourItem, weekItem, sonnetItem]
        let anyRowVisible = rows.contains { !($0?.isHidden ?? true) }
        let usageVisible = anyRowVisible || noteVisible
        usageHeaderItem.isHidden = !usageVisible
        usageSeparator.isHidden = !usageVisible
    }

    private static let bucketParagraph: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.tabStops = [
            NSTextTab(textAlignment: .right, location: 92),
            NSTextTab(textAlignment: .left, location: 108),
        ]
        return p
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d HH:mm"
        return f
    }()

    private func setBucket(_ item: NSMenuItem, label: String, bucket: UsageBucket?, visible: Bool) {
        guard visible, let b = bucket else { item.isHidden = true; return }
        item.isHidden = false

        var line = "\(label)\t\(b.percent)%"
        if let r = b.resetsAt { line += "\tReset: \(Self.resetString(r))" }

        item.attributedTitle = NSAttributedString(string: line, attributes: [
            .font: NSFont.menuFont(ofSize: 0),
            .paragraphStyle: Self.bucketParagraph,
        ])
    }

    private static func resetString(_ date: Date) -> String {
        let f = Calendar.current.isDateInToday(date) ? timeFormatter : dateTimeFormatter
        return f.string(from: date)
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
