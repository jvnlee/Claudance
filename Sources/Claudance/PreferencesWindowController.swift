import AppKit

final class PreferencesWindowController: NSObject {

    private let prefs = Preferences.shared
    private var window: NSWindow?

    private var sessionMaster: NSButton!
    private var usageMaster: NSButton!
    private var sessionChecks: [NSButton] = []
    private var usageChecks: [NSButton] = []

    func show() {
        if window == nil { window = buildWindow() }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildWindow() -> NSWindow {
        let content = buildContent()

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                           styleMask: [.titled, .closable],
                           backing: .buffered, defer: false)
        win.title = "Preferences"
        win.isReleasedWhenClosed = false
        win.contentView = content
        win.setContentSize(content.fittingSize)
        return win
    }

    private func buildContent() -> NSView {
        let grid = NSGridView(views: [
            [optionLabel("Clawd Color"), colorControl()],
            [optionLabel("Show in menu"), menuVisibilityControl()],
            [optionLabel("Motion"), motionControl()],
        ])
        grid.rowSpacing = 14
        grid.columnSpacing = 12
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        grid.row(at: 2).rowAlignment = .none
        grid.row(at: 2).yPlacement = .center

        let stack = NSStackView(views: [grid])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])
        return container
    }

    private func optionLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        return label
    }

    private func colorControl() -> NSView {
        let seg = NSSegmentedControl(labels: ["Coral", "System"],
                                     trackingMode: .selectOne,
                                     target: self, action: #selector(colorChanged(_:)))
        seg.selectedSegment = prefs.colorMode == .adaptive ? 1 : 0
        return seg
    }

    private func menuVisibilityControl() -> NSView {
        sessionMaster = masterCheckbox("Sessions", action: #selector(sessionMasterToggled(_:)))
        sessionChecks = SessionRow.allCases.enumerated().map { i, row in
            childCheckbox(row.title, on: prefs.isVisible(row), tag: i, action: #selector(sessionChildToggled(_:)))
        }
        refreshMaster(SessionRow.allCases, sessionMaster)

        usageMaster = masterCheckbox("Usage", action: #selector(usageMasterToggled(_:)))
        usageChecks = UsageRow.allCases.enumerated().map { i, row in
            childCheckbox(row.title, on: prefs.isVisible(row), tag: i, action: #selector(usageChildToggled(_:)))
        }
        refreshMaster(UsageRow.allCases, usageMaster)

        let stack = NSStackView(views: [
            sectionGroup(master: sessionMaster, children: sessionChecks),
            sectionGroup(master: usageMaster, children: usageChecks),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        return stack
    }

    private func masterCheckbox(_ title: String, action: Selector) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: self, action: action)
        b.allowsMixedState = true
        b.font = .boldSystemFont(ofSize: 13)
        return b
    }

    private func childCheckbox(_ title: String, on: Bool, tag: Int, action: Selector) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: self, action: action)
        b.state = on ? .on : .off
        b.tag = tag
        return b
    }

    private func sectionGroup(master: NSButton, children: [NSButton]) -> NSView {
        let childStack = NSStackView(views: children)
        childStack.orientation = .vertical
        childStack.alignment = .leading
        childStack.spacing = 6
        childStack.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 0, right: 0)

        let group = NSStackView(views: [master, childStack])
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 6
        return group
    }

    private func refreshMaster<R: MenuRow>(_ rows: [R], _ master: NSButton) {
        master.state = masterState(rows.map { prefs.isVisible($0) })
    }

    private func masterState(_ states: [Bool]) -> NSControl.StateValue {
        if states.allSatisfy({ $0 }) { return .on }
        if states.allSatisfy({ !$0 }) { return .off }
        return .mixed
    }

    private func motionControl() -> NSView {
        let toggle = NSSwitch()
        toggle.state = prefs.motionEnabled ? .on : .off
        toggle.target = self
        toggle.action = #selector(motionToggled(_:))
        return toggle
    }

    @objc private func colorChanged(_ sender: NSSegmentedControl) {
        prefs.colorMode = sender.selectedSegment == 1 ? .adaptive : .coral
    }

    @objc private func sessionMasterToggled(_ sender: NSButton) {
        toggleAll(SessionRow.allCases, checks: sessionChecks, master: sessionMaster)
    }

    @objc private func usageMasterToggled(_ sender: NSButton) {
        toggleAll(UsageRow.allCases, checks: usageChecks, master: usageMaster)
    }

    @objc private func sessionChildToggled(_ sender: NSButton) {
        toggleChild(SessionRow.allCases, tag: sender.tag, on: sender.state == .on, master: sessionMaster)
    }

    @objc private func usageChildToggled(_ sender: NSButton) {
        toggleChild(UsageRow.allCases, tag: sender.tag, on: sender.state == .on, master: usageMaster)
    }

    private func toggleAll<R: MenuRow>(_ rows: [R], checks: [NSButton], master: NSButton) {
        let turnOn = checks.contains { $0.state != .on }
        prefs.setVisible(rows, turnOn)
        for c in checks { c.state = turnOn ? .on : .off }
        master.state = turnOn ? .on : .off
    }

    private func toggleChild<R: MenuRow>(_ rows: [R], tag: Int, on: Bool, master: NSButton) {
        guard tag >= 0, tag < rows.count else { return }
        prefs.setVisible(rows[tag], on)
        refreshMaster(rows, master)
    }

    @objc private func motionToggled(_ sender: NSSwitch) {
        prefs.motionEnabled = sender.state == .on
    }
}
