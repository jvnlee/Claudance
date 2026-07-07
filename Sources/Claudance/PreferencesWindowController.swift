import AppKit

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class FillingTableView: NSTableView {
    override func layout() {
        super.layout()
        guard let clip = enclosingScrollView?.contentView, clip.bounds.width > 0 else { return }
        let w = clip.bounds.width
        if let col = tableColumns.first, abs(col.width - w) > 0.5 { col.width = w }
        if abs(frame.width - w) > 0.5 { setFrameSize(NSSize(width: w, height: frame.height)) }
    }
}

final class PreferencesWindowController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {

    private enum SidebarRow {
        case account(Account)
        case separator
        case about
    }

    private enum RowKind { case sessions, usage }

    private let prefs = Preferences.shared
    private var window: NSWindow?
    private let detailContainer = NSView()
    private var sidebarTable: NSTableView?

    private var accounts: [Account] = []
    private var sidebarRows: [SidebarRow] = []
    private var suppressSelectionCallback = false

    private var currentAccountKey: String?
    private var showSwitch: NSSwitch?
    private var capNotice: NSTextField?
    private var previewImageView: NSImageView?
    private var sessionMaster: NSButton?
    private var usageMaster: NSButton?
    private var sessionChecks: [NSButton] = []
    private var usageChecks: [NSButton] = []

    func show(focusAccountKey: String? = nil) {
        accounts = AccountRegistry.discover()
        rebuildSidebarRows()
        let firstBuild = window == nil
        if firstBuild { buildWindow() }
        reloadSidebar()
        selectInitialRow(focusAccountKey: focusAccountKey)
        if firstBuild {
            fitWindowToContent()
            window?.center()
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func fitWindowToContent() {
        guard let win = window else { return }
        win.contentView?.layoutSubtreeIfNeeded()
        guard let content = detailContainer.subviews.first else { return }
        let height: CGFloat
        if let scroll = content as? NSScrollView, let doc = scroll.documentView {
            height = doc.fittingSize.height
        } else {
            height = content.fittingSize.height
        }
        win.setContentSize(NSSize(width: 640, height: ceil(height)))
    }

    private func buildWindow() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 550),
                           styleMask: [.titled, .closable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.title = "Preferences"
        win.isReleasedWhenClosed = false
        win.delegate = self

        let sidebarVC = NSViewController()
        sidebarVC.view = buildSidebar()

        let detailVC = NSViewController()
        detailVC.view = detailContainer

        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = 210
        sidebarItem.maximumThickness = 210
        sidebarItem.canCollapse = false
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: detailVC))

        win.contentViewController = split
        window = win
    }

    private func buildSidebar() -> NSView {
        let table = FillingTableView()
        table.style = .sourceList
        table.headerView = nil
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        col.minWidth = 40
        table.addTableColumn(col)
        table.dataSource = self
        table.delegate = self
        sidebarTable = table

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 220, height: 460))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]
        scroll.documentView = table
        table.frame = scroll.contentView.bounds
        table.autoresizingMask = [.width]
        return scroll
    }

    private func rebuildSidebarRows() {
        var rows: [SidebarRow] = accounts.map { .account($0) }
        if !rows.isEmpty { rows.append(.separator) }
        rows.append(.about)
        sidebarRows = rows
    }

    private func reloadSidebar() {
        suppressSelectionCallback = true
        sidebarTable?.reloadData()
        suppressSelectionCallback = false
    }

    private func selectInitialRow(focusAccountKey: String?) {
        guard let table = sidebarTable else { return }
        let idx: Int
        if let key = focusAccountKey,
           let found = sidebarRows.firstIndex(where: { if case .account(let a) = $0 { return a.key == key } else { return false } }) {
            idx = found
        } else {
            idx = sidebarRows.firstIndex { if case .account(let a) = $0 { return a.isDefault } else { return false } }
                ?? sidebarRows.firstIndex { if case .account = $0 { return true } else { return false } }
                ?? sidebarRows.firstIndex { if case .about = $0 { return true } else { return false } }
                ?? 0
        }
        suppressSelectionCallback = true
        table.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        suppressSelectionCallback = false
        showDetail(for: sidebarRows[idx])
    }

    // MARK: - Table data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int { sidebarRows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .separator = sidebarRows[row] { return 13 }
        return 28
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .separator = sidebarRows[row] { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch sidebarRows[row] {
        case .account(let a): return accountCell(a)
        case .separator: return separatorCell()
        case .about: return iconTextCell(symbol: "info.circle", title: "About")
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if suppressSelectionCallback { return }
        guard let table = sidebarTable else { return }
        let row = table.selectedRow
        guard row >= 0, row < sidebarRows.count else { return }
        showDetail(for: sidebarRows[row])
    }

    private func accountCell(_ a: Account) -> NSView {
        let enabled = prefs.showsClawd(forAccountKey: a.key)
        let swatch = NSImageView(image: swatchImage(forKey: a.key, enabled: enabled))
        swatch.translatesAutoresizingMaskIntoConstraints = false
        swatch.widthAnchor.constraint(equalToConstant: 13).isActive = true
        swatch.heightAnchor.constraint(equalToConstant: 13).isActive = true

        let label = NSTextField(labelWithString: a.displayName)
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.textColor = enabled ? .labelColor : .tertiaryLabelColor
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        return sidebarStack([swatch, label])
    }

    private func iconTextCell(symbol: String, title: String) -> NSView {
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        let iv = NSImageView(image: img ?? NSImage())
        iv.contentTintColor = .secondaryLabelColor
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.widthAnchor.constraint(equalToConstant: 15).isActive = true

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        return sidebarStack([iv, label])
    }

    private func sidebarStack(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 7
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false

        let cell = NSTableCellView()
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func separatorCell() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        let cell = NSView()
        cell.addSubview(box)
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            box.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            box.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func swatchImage(forKey key: String, enabled: Bool) -> NSImage {
        let color: NSColor
        switch prefs.colorMode(forAccountKey: key) {
        case .coral: color = ClawdColors.coral
        case .custom: color = NSColor(clawdHex: prefs.customColorHex(forAccountKey: key)) ?? ClawdColors.coral
        case .adaptive: color = .labelColor
        }
        let diameter: CGFloat = 13
        return NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            if enabled {
                color.setFill(); path.fill()
            } else {
                color.setStroke(); path.lineWidth = 1.5; path.stroke()
            }
            return true
        }
    }

    // MARK: - Detail panes

    private func showDetail(for row: SidebarRow) {
        closeColorPanel()
        let content: NSView
        switch row {
        case .account(let a): content = buildAccountPane(a)
        case .about: content = buildAboutPane()
        case .separator: return
        }
        detailContainer.subviews.forEach { $0.removeFromSuperview() }
        content.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),
            content.topAnchor.constraint(equalTo: detailContainer.topAnchor),
            content.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),
        ])
    }

    private func buildAccountPane(_ a: Account) -> NSView {
        currentAccountKey = a.key
        sessionChecks = []
        usageChecks = []

        let title = NSTextField(labelWithString: a.displayName)
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let subtitle = NSTextField(labelWithString: a.kindLabel)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let header = NSStackView(views: [title, subtitle])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 2

        let show = NSSwitch()
        show.state = prefs.showsClawd(forAccountKey: a.key) ? .on : .off
        show.target = self
        show.action = #selector(showToggled(_:))
        showSwitch = show

        let notice = NSTextField(wrappingLabelWithString: "")
        notice.font = .systemFont(ofSize: 11)
        notice.textColor = .systemOrange
        notice.isHidden = true
        capNotice = notice

        let seg = NSSegmentedControl(labels: ["Coral", "System", "Custom"],
                                     trackingMode: .selectOne,
                                     target: self, action: #selector(colorModeChanged(_:)))
        seg.selectedSegment = segmentIndex(for: prefs.colorMode(forAccountKey: a.key))

        let preview = NSImageView()
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.widthAnchor.constraint(equalToConstant: 46).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 34).isActive = true
        previewImageView = preview

        seg.translatesAutoresizingMaskIntoConstraints = false

        let colorControl = NSView()
        colorControl.translatesAutoresizingMaskIntoConstraints = false
        colorControl.addSubview(seg)
        colorControl.addSubview(preview)
        NSLayoutConstraint.activate([
            seg.topAnchor.constraint(equalTo: colorControl.topAnchor),
            seg.leadingAnchor.constraint(equalTo: colorControl.leadingAnchor),
            seg.trailingAnchor.constraint(equalTo: colorControl.trailingAnchor),
            preview.topAnchor.constraint(equalTo: seg.bottomAnchor, constant: 8),
            preview.trailingAnchor.constraint(equalTo: colorControl.trailingAnchor),
            preview.leadingAnchor.constraint(greaterThanOrEqualTo: colorControl.leadingAnchor),
            preview.bottomAnchor.constraint(equalTo: colorControl.bottomAnchor),
        ])

        let motion = NSSwitch()
        motion.state = prefs.motionEnabled(forAccountKey: a.key) ? .on : .off
        motion.target = self
        motion.action = #selector(motionToggled(_:))

        let menuControl = NSStackView(views: [
            buildRowGroup(title: "Sessions", rows: SessionRow.allCases, kind: .sessions),
            buildRowGroup(title: "Usage", rows: UsageRow.allCases, kind: .usage),
        ])
        menuControl.orientation = .vertical
        menuControl.alignment = .leading
        menuControl.spacing = 10

        let showRow = formRow("Show in menu bar", show)
        let colorRow = formRow("Color", colorControl, alignTo: seg)
        let motionRow = formRow("Motion", motion)
        let menuRow = formRow("Show in menu", menuControl, alignTo: sessionMaster)
        let sep1 = formSeparator()
        let sep2 = formSeparator()
        let sep3 = formSeparator()

        let stack = NSStackView(views: [header, showRow, notice, sep1, colorRow, sep2, motionRow, sep3, menuRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        let doc = FlippedView()
        doc.addSubview(stack)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = doc
        doc.translatesAutoresizingMaskIntoConstraints = false

        var constraints: [NSLayoutConstraint] = [
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 22),
            doc.bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: 22),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            title.widthAnchor.constraint(lessThanOrEqualTo: header.widthAnchor),
            subtitle.widthAnchor.constraint(lessThanOrEqualTo: header.widthAnchor),
        ]
        for row in [header, showRow, notice, sep1, colorRow, sep2, motionRow, sep3, menuRow] {
            constraints.append(row.widthAnchor.constraint(equalTo: stack.widthAnchor))
        }
        NSLayoutConstraint.activate(constraints)

        refreshPreview()
        updateCapNotice()
        return scroll
    }

    private func buildRowGroup<R: MenuRow>(title: String, rows: [R], kind: RowKind) -> NSView {
        let masterAction = kind == .sessions ? #selector(sessionMasterToggled(_:)) : #selector(usageMasterToggled(_:))
        let master = NSButton(checkboxWithTitle: title, target: self, action: masterAction)
        master.allowsMixedState = true
        master.font = .systemFont(ofSize: 13, weight: .medium)

        let childAction = kind == .sessions ? #selector(sessionChildToggled(_:)) : #selector(usageChildToggled(_:))
        let children: [NSButton] = rows.enumerated().map { i, row in
            let b = NSButton(checkboxWithTitle: row.title, target: self, action: childAction)
            b.state = prefs.isVisible(row, forAccountKey: currentAccountKey ?? "") ? .on : .off
            b.tag = i
            return b
        }

        if kind == .sessions { sessionMaster = master; sessionChecks = children }
        else { usageMaster = master; usageChecks = children }
        refreshMaster(rows, master)

        let childStack = NSStackView(views: children)
        childStack.orientation = .vertical
        childStack.alignment = .leading
        childStack.spacing = 5
        childStack.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)

        let group = NSStackView(views: [master, childStack])
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 5
        return group
    }

    private func buildAboutPane() -> NSView {
        currentAccountKey = nil

        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 88).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 88).isActive = true

        let name = NSTextField(labelWithString: "Claudance")
        name.font = .systemFont(ofSize: 16, weight: .semibold)

        let desc = NSTextField(labelWithString: "Claude Code monitor in your menu bar")
        desc.font = .systemFont(ofSize: 12)
        desc.textColor = .secondaryLabelColor
        desc.alignment = .center

        var views: [NSView] = [icon, name]
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            let version = NSTextField(labelWithString: "Version \(v)")
            version.font = .systemFont(ofSize: 11)
            version.textColor = .secondaryLabelColor
            views.append(version)
        }
        views.append(desc)

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
        ])
        return container
    }

    // MARK: - Actions

    @objc private func showToggled(_ sender: NSSwitch) {
        guard let key = currentAccountKey else { return }
        prefs.setShowsClawd(sender.state == .on, forAccountKey: key)
        updateCapNotice()
        reloadSidebar()
    }

    @objc private func colorModeChanged(_ sender: NSSegmentedControl) {
        guard let key = currentAccountKey else { return }
        let mode = colorMode(forSegment: sender.selectedSegment)
        if mode == .custom {
            if prefs.customColorHex(forAccountKey: key) == nil {
                prefs.setCustomColorHex(randomColorHex(), forAccountKey: key)
            }
            prefs.setColorMode(mode, forAccountKey: key)
            openColorPanel(for: key)
        } else {
            prefs.setColorMode(mode, forAccountKey: key)
            closeColorPanel()
        }
        refreshPreview()
        reloadSidebar()
    }

    @objc private func customColorChanged(_ sender: NSColorPanel) {
        guard let key = currentAccountKey else { return }
        prefs.setCustomColorHex(sender.color.clawdHex, forAccountKey: key)
        refreshPreview()
        reloadSidebar()
    }

    private func openColorPanel(for key: String) {
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = NSColor(clawdHex: prefs.customColorHex(forAccountKey: key)) ?? ClawdColors.coral
        panel.setTarget(self)
        panel.setAction(#selector(customColorChanged(_:)))
        panel.orderFront(nil)
    }

    private func closeColorPanel() {
        guard NSColorPanel.sharedColorPanelExists else { return }
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        closeColorPanel()
    }

    @objc private func motionToggled(_ sender: NSSwitch) {
        guard let key = currentAccountKey else { return }
        prefs.setMotionEnabled(sender.state == .on, forAccountKey: key)
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

    // MARK: - Helpers

    private func toggleAll<R: MenuRow>(_ rows: [R], checks: [NSButton], master: NSButton?) {
        guard let key = currentAccountKey else { return }
        let turnOn = checks.contains { $0.state != .on }
        prefs.setVisible(rows, turnOn, forAccountKey: key)
        for c in checks { c.state = turnOn ? .on : .off }
        master?.state = turnOn ? .on : .off
    }

    private func toggleChild<R: MenuRow>(_ rows: [R], tag: Int, on: Bool, master: NSButton?) {
        guard let key = currentAccountKey, tag >= 0, tag < rows.count else { return }
        prefs.setVisible(rows[tag], on, forAccountKey: key)
        if let master { refreshMaster(rows, master) }
    }

    private func refreshMaster<R: MenuRow>(_ rows: [R], _ master: NSButton) {
        guard let key = currentAccountKey else { return }
        let states = rows.map { prefs.isVisible($0, forAccountKey: key) }
        if states.allSatisfy({ $0 }) { master.state = .on }
        else if states.allSatisfy({ !$0 }) { master.state = .off }
        else { master.state = .mixed }
    }

    private func randomColorHex() -> String {
        NSColor(hue: .random(in: 0...1), saturation: 0.62, brightness: 0.9, alpha: 1).clawdHex
    }

    private func refreshPreview() {
        guard let key = currentAccountKey, let iv = previewImageView else { return }
        let mode = prefs.colorMode(forAccountKey: key)
        var spec = ClawdDrawSpec.standing
        spec.colorMode = mode
        if mode == .custom { spec.customColorHex = prefs.customColorHex(forAccountKey: key) }
        iv.image = ClawdSprite.centeredImage(spec, size: NSSize(width: 58, height: 44))
        iv.contentTintColor = mode == .adaptive ? .labelColor : nil
    }

    private func updateCapNotice() {
        guard let key = currentAccountKey, let notice = capNotice else { return }
        if prefs.showsClawd(forAccountKey: key), !liveKeys().contains(key) {
            notice.stringValue = "Only 3 Clawds fit in the menu bar — this account is currently hidden."
            notice.isHidden = false
        } else {
            notice.isHidden = true
        }
    }

    private func liveKeys() -> [String] {
        var out: [String] = []
        for a in accounts where prefs.showsClawd(forAccountKey: a.key) {
            out.append(a.key)
            if out.count >= 3 { break }
        }
        return out
    }

    private func segmentIndex(for mode: SpriteColorMode) -> Int {
        switch mode {
        case .coral: return 0
        case .adaptive: return 1
        case .custom: return 2
        }
    }

    private func colorMode(forSegment index: Int) -> SpriteColorMode {
        switch index {
        case 1: return .adaptive
        case 2: return .custom
        default: return .coral
        }
    }

    private func formRow(_ title: String, _ control: NSView, alignTo: NSView? = nil) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false

        let row = NSView()
        row.addSubview(label)
        row.addSubview(control)

        let anchor = alignTo ?? control
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.centerYAnchor.constraint(equalTo: anchor.centerYAnchor),
            control.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 12),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            control.topAnchor.constraint(equalTo: row.topAnchor),
            control.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])
        return row
    }

    private func formSeparator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}
