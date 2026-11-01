import AppKit

enum PanelDemo {

    static func bench(count: Int, iterations: Int) {
        NSApp.appearance = NSAppearance(named: .aqua)
        let model = makeModel(count: count)

        var viewMs: [Double] = []
        for _ in 0..<iterations {
            let t0 = ProcessInfo.processInfo.systemUptime
            let view = ClusterPanelView(model: model) { _ in }
            _ = view.fittingSize
            viewMs.append((ProcessInfo.processInfo.systemUptime - t0) * 1000)
        }

        func stats(_ xs: [Double]) -> String {
            let s = xs.sorted()
            return String(format: "p50=%.1fms max=%.1fms mean=%.1fms",
                          s[s.count / 2], s.last ?? 0, xs.reduce(0, +) / Double(xs.count))
        }
        print("accounts=\(count) iters=\(iterations)")
        print("  ClusterPanelView(init) : \(stats(viewMs))")
    }

    static func render(count: Int, to dir: String) {
        NSApp.appearance = NSAppearance(named: .aqua)
        let model = makeModel(count: count)
        let view = ClusterPanelView(model: model) { _ in }
        view.layoutSubtreeIfNeeded()
        view.frame = NSRect(origin: .zero, size: view.fittingSize)

        let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = view
        window.displayIfNeeded()

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }

        let url = URL(fileURLWithPath: dir).appendingPathComponent("cluster-panel-\(count).png")
        try? png.write(to: url)
        print("wrote \(url.path)  size=\(Int(view.bounds.width))x\(Int(view.bounds.height))")
    }

    private static func makeModel(count: Int) -> ClusterPanelModel {
        let hues = (0..<count).map { CGFloat($0) / CGFloat(max(count, 1)) }
        let members = (0..<count).map { i -> ClusterPanelModel.Member in
            var chip = i % 3 == 0
                ? Animator.pose(state: .rest, phase: 0, energy: 0)
                : ClawdDrawSpec.standing
            chip.colorMode = .custom
            chip.customColorHex = NSColor(hue: hues[i], saturation: 0.62, brightness: 0.9, alpha: 1).clawdHex
            return ClusterPanelModel.Member(key: "k\(i)", name: "account\(i + 1)@example.com", chip: chip)
        }

        let panel = MenuPanelModel(
            accountName: "account1@example.com",
            stats: [.init(label: "Total", value: "3"), .init(label: "Working", value: "2")],
            planLine: "Subscription (Max)",
            gauges: [.init(label: "5-hour", percent: 42, reset: "resets 3:00 PM"),
                     .init(label: "Weekly", percent: 61, reset: "resets Mon")],
            apiRows: [],
            statusMessage: nil,
            tint: ClawdColors.coral)

        return ClusterPanelModel(members: members, selectedKey: "k0", selectedPanel: panel)
    }
}
