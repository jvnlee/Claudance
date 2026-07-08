import AppKit

struct MenuPanelModel {
    struct Stat {
        var label: String
        var value: String
    }

    struct Gauge {
        var label: String
        var percent: Int
        var reset: String?
    }

    struct Amount {
        var label: String
        var value: String
    }

    var accountName: String
    var stats: [Stat]
    var planLine: String?
    var gauges: [Gauge]
    var apiRows: [Amount]
    var statusMessage: String?
    var tint: NSColor
}

final class MenuPanelView: NSView {

    private static let contentWidth: CGFloat = 280
    private static let sideInset: CGFloat = 14

    private let stack = NSStackView()

    init(model: MenuPanelModel) {
        super.init(frame: .zero)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.sideInset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.sideInset),
            widthAnchor.constraint(equalToConstant: Self.contentWidth + Self.sideInset * 2),
        ])
        build(model)
        layoutSubtreeIfNeeded()
        frame = NSRect(origin: .zero, size: fittingSize)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func build(_ model: MenuPanelModel) {
        add(Self.header("Account"))
        add(Self.label(model.accountName))

        if !model.stats.isEmpty {
            addSeparator()
            add(Self.header("Sessions"))
            var i = 0
            while i < model.stats.count {
                let left = Self.statPair(model.stats[i])
                let right = i + 1 < model.stats.count ? Self.statPair(model.stats[i + 1]) : nil
                add(Self.twoColumn(left, right))
                i += 2
            }
        }

        if model.planLine != nil || !model.gauges.isEmpty {
            addSeparator()
            add(Self.header("Subscription Usage"))
            if let plan = model.planLine { add(Self.label(plan)) }
            for gauge in model.gauges {
                add(Self.gaugeBlock(gauge, tint: model.tint))
                if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(10, after: last) }
            }
        }
        if !model.apiRows.isEmpty {
            addSeparator()
            add(Self.header("API Usage"))
            for row in model.apiRows { add(Self.splitRow(Self.label(row.label), Self.value(row.value))) }
        }
        if let msg = model.statusMessage {
            addSeparator()
            add(Self.header("Usage"))
            add(Self.label(msg, color: .secondaryLabelColor))
        }
    }

    private func add(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func addSeparator() {
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(9, after: last) }
        let box = NSBox()
        box.boxType = .separator
        add(box)
        stack.setCustomSpacing(9, after: box)
    }

    private static func header(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text.uppercased())
        field.font = .systemFont(ofSize: 11, weight: .semibold)
        field.textColor = .secondaryLabelColor
        return field
    }

    private static func label(_ text: String, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .menuFont(ofSize: 0)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    private static func value(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .regular)
        field.textColor = .labelColor
        return field
    }

    private static func statPair(_ stat: MenuPanelModel.Stat) -> NSView {
        splitRow(label(stat.label), value(stat.value))
    }

    private static func splitRow(_ left: NSTextField, _ right: NSTextField) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        for field in [left, right] {
            field.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(field)
        }
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            left.topAnchor.constraint(equalTo: row.topAnchor),
            left.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            right.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            right.firstBaselineAnchor.constraint(equalTo: left.firstBaselineAnchor),
            right.leadingAnchor.constraint(greaterThanOrEqualTo: left.trailingAnchor, constant: 8),
        ])
        return row
    }

    private static func twoColumn(_ left: NSView, _ right: NSView?) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        left.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(left)
        var constraints = [
            left.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            left.topAnchor.constraint(equalTo: row.topAnchor),
            left.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            left.widthAnchor.constraint(equalTo: row.widthAnchor, multiplier: 0.5, constant: -8),
        ]
        if let right {
            right.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(right)
            constraints += [
                right.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                right.topAnchor.constraint(equalTo: row.topAnchor),
                right.widthAnchor.constraint(equalTo: row.widthAnchor, multiplier: 0.5, constant: -8),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        return row
    }

    private static func gaugeBlock(_ gauge: MenuPanelModel.Gauge, tint: NSColor) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let title = label(gauge.label)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let percent = value("\(gauge.percent)%")
        percent.alignment = .right
        let bar = GaugeBarView(percent: gauge.percent, tint: tint)
        let reset = gauge.reset.map(resetLabel)
        var views: [NSView] = [title, percent, bar]
        if let reset { views.append(reset) }
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        let percentWidth = ceil(("100%" as NSString).size(withAttributes: [.font: percent.font as Any]).width)
        var constraints = [
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            title.topAnchor.constraint(equalTo: container.topAnchor),
            percent.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            percent.widthAnchor.constraint(equalToConstant: percentWidth),
            percent.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            bar.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 4),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ]
        if let reset {
            constraints += [
                reset.trailingAnchor.constraint(equalTo: percent.leadingAnchor, constant: -4),
                reset.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
                reset.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),
            ]
        } else {
            constraints.append(percent.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8))
        }
        NSLayoutConstraint.activate(constraints)
        return container
    }

    private static func resetLabel(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: "(\(text))")
        field.font = .systemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize - 2)
        field.textColor = .secondaryLabelColor
        field.alignment = .right
        return field
    }
}

final class GaugeBarView: NSView {

    private let percent: Int
    private let tint: NSColor

    init(percent: Int, tint: NSColor) {
        self.percent = percent
        self.tint = tint
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        guard percent > 0 else { return }
        let width = max(bounds.width * CGFloat(percent) / 100, bounds.height)
        tint.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: bounds.height),
                     xRadius: radius, yRadius: radius).fill()
    }
}
