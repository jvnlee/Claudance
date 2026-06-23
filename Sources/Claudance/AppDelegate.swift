import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private let monitor = SessionMonitor()
    private var animator = Animator()
    private var timer: Timer?
    private var tick = 0
    private var lastTickTime: TimeInterval = 0
    private var lastRenderedRest = false

    private let imageSize = ClawdSprite.liveSize
    private static let frameInterval = 1.0 / 30.0

    private var statusMenuItem: NSMenuItem!
    private var aboutWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imageScaling = .scaleNone
        buildMenu()

        let now = Date().timeIntervalSince1970
        monitor.refresh(now: now)
        lastTickTime = now
        render(force: true)
        updateStatusText()

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
        }

        render(force: false, dt: dt)

        if tick % 15 == 0 {
            updateStatusText()
        }
    }

    private func render(force: Bool, dt: Double = AppDelegate.frameInterval) {
        let snap = monitor.snapshot
        let spec = animator.update(snap, dt: dt)

        let resting = snap.state == .rest && animator.isResting
        if resting && lastRenderedRest && !force { return }
        lastRenderedRest = resting

        statusItem.button?.image = ClawdSprite.image(spec, size: imageSize)
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        statusMenuItem = NSMenuItem(title: "…", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(.separator())

        let about = NSMenuItem(title: "About Claudance", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        monitor.refresh(now: Date().timeIntervalSince1970)
        updateStatusText()
    }

    private func updateStatusText() {
        let s = monitor.snapshot
        let total = s.presentCount
        let working = s.workingCount
        let waiting = s.waitingCount
        let idle = max(0, total - working - waiting)
        statusMenuItem.title = "Total \(total) · Working \(working) · Waiting \(waiting) · Idle \(idle)"
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
