import AppKit

struct ClusterPanelModel {
    struct Member {
        var key: String
        var name: String
        var chip: ClawdDrawSpec
    }

    var members: [Member]
    var selectedKey: String
    var selectedPanel: MenuPanelModel
}

final class ClusterPanelView: NSView {

    private static let chipSize = NSSize(width: 30, height: 26)
    private static let chipSpacing: CGFloat = 2

    private static var chipsPerRow: Int {
        let available = MenuPanelView.panelWidth - MenuPanelView.sideInset * 2
        return max(1, Int((available + chipSpacing) / (chipSize.width + chipSpacing)))
    }

    init(model: ClusterPanelModel, onSelect: @escaping (String) -> Void) {
        super.init(frame: .zero)

        let selected = MenuPanelView(model: model.selectedPanel)
        let bodyHeight = selected.frame.height
        let selectedIndex = model.members.firstIndex { $0.key == model.selectedKey } ?? 0

        let chipImageSize = NSSize(width: Self.chipSize.width - 4, height: 22)
        let chips = model.members.enumerated().map { index, member in
            ChipView(image: ClawdSprite.centeredImage(member.chip, size: chipImageSize),
                     size: Self.chipSize,
                     selected: index == selectedIndex,
                     name: member.name) { onSelect(member.key) }
        }

        let perRow = Self.chipsPerRow
        let chipRows = stride(from: 0, to: chips.count, by: perRow).map { start -> NSView in
            let row = NSStackView(views: Array(chips[start..<min(start + perRow, chips.count)]))
            row.orientation = .horizontal
            row.spacing = Self.chipSpacing
            return row
        }

        let header = NSStackView(views: chipRows)
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = Self.chipSpacing
        header.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false

        selected.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(selected)

        addSubview(header)
        addSubview(divider)
        addSubview(body)

        let inset = MenuPanelView.sideInset
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: MenuPanelView.panelWidth),

            header.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            header.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset),

            divider.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 9),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),

            body.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 3),
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.bottomAnchor.constraint(equalTo: bottomAnchor),
            body.heightAnchor.constraint(equalToConstant: bodyHeight),

            selected.topAnchor.constraint(equalTo: body.topAnchor),
            selected.leadingAnchor.constraint(equalTo: body.leadingAnchor),
        ])

        layoutSubtreeIfNeeded()
        frame = NSRect(origin: .zero, size: fittingSize)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class ChipView: NSView {

    private let image: NSImage
    private let size: NSSize
    private let selected: Bool
    private let onClick: () -> Void

    init(image: NSImage, size: NSSize, selected: Bool, name: String, onClick: @escaping () -> Void) {
        self.image = image
        self.size = size
        self.selected = selected
        self.onClick = onClick
        super.init(frame: NSRect(origin: .zero, size: size))
        toolTip = name
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize { size }

    override func draw(_ dirtyRect: NSRect) {
        if selected {
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        let origin = NSPoint(x: (bounds.width - image.size.width) / 2,
                             y: (bounds.height - image.size.height) / 2)
        image.draw(at: origin, from: .zero, operation: .sourceOver,
                   fraction: selected ? 1 : 0.5)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { onClick() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
