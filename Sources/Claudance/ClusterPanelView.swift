import AppKit

struct ClusterPanelModel {
    struct Member {
        var key: String
        var name: String
        var chip: ClawdDrawSpec
        var panel: MenuPanelModel
    }

    var members: [Member]
    var selectedKey: String
    var summary: String
}

final class ClusterPanelView: NSView {

    fileprivate static let chipSize = NSSize(width: 30, height: 26)
    private static let chipImageSize = NSSize(width: 26, height: 22)

    init(model: ClusterPanelModel, onSelect: @escaping (String) -> Void) {
        super.init(frame: .zero)

        let panels = model.members.map { MenuPanelView(model: $0.panel) }
        let bodyHeight = panels.map(\.frame.height).max() ?? 0
        let selectedIndex = model.members.firstIndex { $0.key == model.selectedKey } ?? 0

        let chips = model.members.enumerated().map { index, member in
            ChipView(image: ClawdSprite.centeredImage(member.chip, size: Self.chipImageSize),
                     selected: index == selectedIndex,
                     name: member.name) { onSelect(member.key) }
        }
        let chipRow = NSStackView(views: chips)
        chipRow.orientation = .horizontal
        chipRow.spacing = 2

        let summary = NSTextField(labelWithString: model.summary)
        summary.font = .systemFont(ofSize: 11)
        summary.textColor = .secondaryLabelColor

        let header = NSStackView(views: [chipRow, summary])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 5
        header.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false

        let selected = panels[min(selectedIndex, panels.count - 1)]
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
    private let selected: Bool
    private let onClick: () -> Void

    init(image: NSImage, selected: Bool, name: String, onClick: @escaping () -> Void) {
        self.image = image
        self.selected = selected
        self.onClick = onClick
        super.init(frame: NSRect(origin: .zero, size: ClusterPanelView.chipSize))
        toolTip = name
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize { ClusterPanelView.chipSize }

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
