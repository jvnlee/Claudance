import AppKit

final class PreferencesWindowController: NSObject {

    private let prefs = Preferences.shared
    private var window: NSWindow?

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
            [optionLabel("Show in menu"), usageControl()],
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

    private func usageControl() -> NSView {
        var checks: [NSView] = []
        for (i, row) in UsageRow.allCases.enumerated() {
            let check = NSButton(checkboxWithTitle: row.title, target: self, action: #selector(usageToggled(_:)))
            check.state = prefs.isVisible(row) ? .on : .off
            check.tag = i
            checks.append(check)
        }
        let stack = NSStackView(views: checks)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        return stack
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

    @objc private func usageToggled(_ sender: NSButton) {
        let rows = UsageRow.allCases
        guard sender.tag >= 0, sender.tag < rows.count else { return }
        prefs.setVisible(rows[sender.tag], sender.state == .on)
    }

    @objc private func motionToggled(_ sender: NSSwitch) {
        prefs.motionEnabled = sender.state == .on
    }
}
