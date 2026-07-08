import AppKit

final class SpeechBubbleView: NSView {

    static let tailHeight: CGFloat = 7
    static let tailWidth: CGFloat = 14
    static let cornerRadius: CGFloat = 9
    static let paddingX: CGFloat = 12
    static let paddingY: CGFloat = 8
    static let textFont = NSFont.systemFont(ofSize: 12, weight: .medium)

    var onClick: (() -> Void)?

    var tint: NSColor {
        didSet {
            label.textColor = Self.contrastColor(for: tint)
            needsDisplay = true
        }
    }

    var tailX: CGFloat {
        didSet { if oldValue != tailX { needsDisplay = true } }
    }

    private let label: NSTextField

    var text: String {
        get { label.stringValue }
        set {
            guard label.stringValue != newValue else { return }
            label.stringValue = newValue
            setFrameSize(Self.bubbleSize(for: newValue))
            needsLayout = true
            needsDisplay = true
        }
    }

    static func bubbleSize(for text: String) -> NSSize {
        let measured = (text as NSString).size(withAttributes: [.font: textFont])
        return NSSize(width: ceil(measured.width) + paddingX * 2,
                      height: ceil(measured.height) + paddingY * 2 + tailHeight)
    }

    init(text: String, tint: NSColor) {
        self.tint = tint
        label = NSTextField(labelWithString: text)
        label.font = Self.textFont
        label.textColor = Self.contrastColor(for: tint)
        let size = Self.bubbleSize(for: text)
        tailX = size.width / 2
        super.init(frame: NSRect(origin: .zero, size: size))
        addSubview(label)
        needsLayout = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        label.sizeToFit()
        let bodyHeight = bounds.height - Self.tailHeight
        label.setFrameOrigin(NSPoint(x: (bounds.width - label.frame.width) / 2,
                                     y: (bodyHeight - label.frame.height) / 2))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = bubblePath()
        tint.setFill()
        path.fill()
    }

    private static func contrastColor(for color: NSColor) -> NSColor {
        let c = color.usingColorSpace(.sRGB) ?? color
        let luminance = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        return luminance > 0.6 ? .black : .white
    }

    private func bubblePath() -> NSBezierPath {
        let inset: CGFloat = 0
        let r = Self.cornerRadius
        let left = inset
        let right = bounds.width - inset
        let bottom = inset
        let top = bounds.height - Self.tailHeight - inset
        let apexY = bounds.height - inset
        let halfTail = Self.tailWidth / 2
        let tx = min(max(tailX, left + r + halfTail), right - r - halfTail)

        let p = NSBezierPath()
        p.move(to: NSPoint(x: tx - halfTail, y: top))
        p.line(to: NSPoint(x: tx, y: apexY))
        p.line(to: NSPoint(x: tx + halfTail, y: top))
        p.line(to: NSPoint(x: right - r, y: top))
        p.appendArc(withCenter: NSPoint(x: right - r, y: top - r), radius: r,
                    startAngle: 90, endAngle: 0, clockwise: true)
        p.line(to: NSPoint(x: right, y: bottom + r))
        p.appendArc(withCenter: NSPoint(x: right - r, y: bottom + r), radius: r,
                    startAngle: 0, endAngle: 270, clockwise: true)
        p.line(to: NSPoint(x: left + r, y: bottom))
        p.appendArc(withCenter: NSPoint(x: left + r, y: bottom + r), radius: r,
                    startAngle: 270, endAngle: 180, clockwise: true)
        p.line(to: NSPoint(x: left, y: top - r))
        p.appendArc(withCenter: NSPoint(x: left + r, y: top - r), radius: r,
                    startAngle: 180, endAngle: 90, clockwise: true)
        p.close()
        return p
    }
}

final class SpeechBubblePanel: NSPanel {

    let bubbleView: SpeechBubbleView
    var shownAt: TimeInterval = 0
    var fadingOut = false
    var isMock = false
    var isAlert = false

    init(text: String, tint: NSColor, onClick: @escaping () -> Void) {
        bubbleView = SpeechBubbleView(text: text, tint: tint)
        super.init(contentRect: NSRect(origin: .zero, size: bubbleView.frame.size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        bubbleView.onClick = onClick
        contentView = bubbleView
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class SpeechBubbleManager {

    private struct BarState {
        var waitAnnounced = false
        var lastShownAt: TimeInterval = 0
    }

    private let displayDuration: TimeInterval = 5
    private let cooldown: TimeInterval = 30
    private let fadeInDuration: TimeInterval = 0.2
    private let fadeOutDuration: TimeInterval = 0.3

    private let openMenu: (String) -> Void
    private var panels: [String: SpeechBubblePanel] = [:]
    private var states: [String: BarState] = [:]

    init(openMenu: @escaping (String) -> Void) {
        self.openMenu = openMenu
    }

    func update(key: String, button: NSStatusBarButton?, waiting: Int,
                enabled: Bool, menuOpen: Bool, tint: NSColor, now: TimeInterval) {
        if waiting == 0 { states[key, default: BarState()].waitAnnounced = false }

        if let panel = panels[key], panel.isMock {
            if let button, button.window != nil { position(panel, under: button) }
            return
        }

        if let panel = panels[key], panel.isAlert {
            if now - panel.shownAt > displayDuration {
                dismiss(key: key, animated: true)
            } else if let button, button.window != nil, !panel.fadingOut {
                position(panel, under: button)
            }
            return
        }

        guard waiting > 0, enabled, !menuOpen, let button, button.window != nil else {
            dismiss(key: key, animated: true)
            return
        }

        if let panel = panels[key] {
            guard !panel.fadingOut else { return }
            if now - panel.shownAt > displayDuration {
                dismiss(key: key, animated: true)
            } else {
                panel.bubbleView.text = message(for: waiting)
                panel.bubbleView.tint = tint
                position(panel, under: button)
            }
            return
        }

        let state = states[key] ?? BarState()
        guard !state.waitAnnounced, now - state.lastShownAt > cooldown else { return }
        show(key: key, under: button, waiting: waiting, tint: tint, now: now)
    }

    func hide(key: String) {
        guard panels[key]?.isMock != true else { return }
        dismiss(key: key, animated: false)
    }

    func announce(key: String, button: NSStatusBarButton, text: String, tint: NSColor, now: TimeInterval) {
        guard panels[key]?.isMock != true, button.window != nil else { return }
        dismiss(key: key, animated: false)
        for other in panels.keys where other != key {
            dismiss(key: other, animated: true)
        }
        let panel = SpeechBubblePanel(text: text, tint: tint) { [weak self] in
            self?.bubbleClicked(key: key)
        }
        panel.isAlert = true
        panel.shownAt = now
        panels[key] = panel
        position(panel, under: button)
        fadeIn(panel)
    }

    func showMock(key: String, button: NSStatusBarButton, text: String, tint: NSColor) {
        dismiss(key: key, animated: false)
        let panel = SpeechBubblePanel(text: text, tint: tint, onClick: {})
        panel.isMock = true
        panels[key] = panel
        position(panel, under: button)
        fadeIn(panel)
    }

    func prune(activeKeys: [String]) {
        for key in panels.keys where !activeKeys.contains(key) {
            dismiss(key: key, animated: false)
        }
        states = states.filter { activeKeys.contains($0.key) }
    }

    private func message(for waiting: Int) -> String {
        waiting == 1 ? "A session is waiting!" : "\(waiting) sessions are waiting!"
    }

    private func show(key: String, under button: NSStatusBarButton, waiting: Int,
                      tint: NSColor, now: TimeInterval) {
        for other in panels.keys where other != key {
            dismiss(key: other, animated: true)
        }
        let panel = SpeechBubblePanel(text: message(for: waiting), tint: tint) { [weak self] in
            self?.bubbleClicked(key: key)
        }
        panels[key] = panel
        panel.shownAt = now
        var state = states[key] ?? BarState()
        state.lastShownAt = now
        state.waitAnnounced = true
        states[key] = state
        position(panel, under: button)
        fadeIn(panel)
    }

    private func fadeIn(_ panel: SpeechBubblePanel) {
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { [fadeInDuration] ctx in
            ctx.duration = fadeInDuration
            panel.animator().alphaValue = 1
        }
    }

    private func position(_ panel: SpeechBubblePanel, under button: NSStatusBarButton) {
        guard let anchorWindow = button.window else { return }
        let anchor = NSPoint(x: anchorWindow.frame.midX, y: anchorWindow.frame.minY)
        let size = panel.bubbleView.frame.size
        var x = anchor.x - size.width / 2
        if let screen = anchorWindow.screen ?? NSScreen.main {
            x = min(max(x, screen.frame.minX + 6), screen.frame.maxX - size.width - 6)
        }
        let frame = NSRect(x: x, y: anchor.y - size.height - 2,
                           width: size.width, height: size.height)
        if !NSEqualRects(panel.frame, frame) {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
        panel.bubbleView.tailX = anchor.x - x
    }

    private func dismiss(key: String, animated: Bool) {
        guard let panel = panels[key] else { return }
        if !animated {
            panels[key] = nil
            panel.orderOut(nil)
            return
        }
        guard !panel.fadingOut else { return }
        panel.fadingOut = true
        NSAnimationContext.runAnimationGroup({ [fadeOutDuration] ctx in
            ctx.duration = fadeOutDuration
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            panel.orderOut(nil)
            if let self, self.panels[key] === panel {
                self.panels[key] = nil
            }
        })
    }

    private func bubbleClicked(key: String) {
        dismiss(key: key, animated: false)
        let openMenu = openMenu
        DispatchQueue.main.async {
            openMenu(key)
        }
    }
}
