import AppKit

enum ArmPose: Hashable {
    case rest
    case up
    case down
}

enum EyePose: Hashable {
    case open
    case droopy
    case hidden
}

enum LegPose: Hashable {
    case apart
    case together
    case kickLeft
    case kickRight
    case slide(Int)
}

struct ClawdFrame: Hashable {
    static let width = 18
    static let height = 10

    var leftArm: ArmPose = .rest
    var rightArm: ArmPose = .rest
    var legs: LegPose = .apart
    var eyes: EyePose = .open

    static let apart = ClawdFrame()
    static let together = ClawdFrame(legs: .together)

    static func arms(_ pose: ArmPose, legs: LegPose = .apart) -> ClawdFrame {
        ClawdFrame(leftArm: pose, rightArm: pose, legs: legs)
    }

    var lines: [String] {
        var grid = [[Character]](repeating: [Character](repeating: ".", count: Self.width), count: Self.height)
        func ink(_ row: Int, _ cols: [Int]) {
            for col in cols { grid[row][col] = "C" }
        }
        for row in 0...7 { ink(row, Array(3...14)) }
        switch eyes {
        case .open:
            for row in 2...3 {
                grid[row][5] = "E"
                grid[row][12] = "E"
            }
        case .droopy:
            grid[3][5] = "E"
            grid[3][12] = "E"
        case .hidden:
            break
        }
        Self.drawArm(leftArm, outer: 1, inner: 2, ink: ink)
        Self.drawArm(rightArm, outer: 16, inner: 15, ink: ink)
        switch legs {
        case .apart:
            ink(8, [4, 6, 11, 13])
            ink(9, [4, 6, 11, 13])
        case .together:
            ink(8, [4, 6, 11, 13])
        case .kickLeft:
            ink(8, [1, 3, 11, 13])
            ink(9, [11, 13])
        case .kickRight:
            ink(8, [4, 6, 14, 16])
            ink(9, [4, 6])
        case .slide(let cells):
            let step = max(-4, min(4, cells))
            let cols = [4, 6, 11, 13].map { $0 + step }
            ink(8, cols)
            ink(9, cols)
        }
        return grid.map { String($0) }
    }

    private static func drawArm(_ pose: ArmPose, outer: Int, inner: Int, ink: (Int, [Int]) -> Void) {
        switch pose {
        case .rest:
            ink(4, [outer, inner])
            ink(5, [outer, inner])
        case .up:
            ink(1, [outer])
            ink(2, [outer, inner])
        case .down:
            ink(6, [outer, inner])
            ink(7, [outer])
        }
    }
}

struct ClawdColors {
    static let coral = NSColor(srgbRed: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0, alpha: 1)
    static let eye = NSColor(srgbRed: 0x2A / 255.0, green: 0x15 / 255.0, blue: 0x10 / 255.0, alpha: 1)
}

struct ClawdDrawSpec: Equatable {
    var frame: ClawdFrame = .apart
    var bob: CGFloat = 0
    var shift: CGFloat = 0
    var leanRadians: CGFloat = 0
    var scaleX: CGFloat = 1
    var scaleY: CGFloat = 1
    var colorMode: SpriteColorMode = .coral
    var customColorHex: String? = nil
    var adaptiveColorHex: String? = nil
    var alpha: CGFloat = 1
    var dim: CGFloat = 1
    var closedEyes: Bool = false

    static let groundLevel: CGFloat = 1.6
    static let standing = ClawdDrawSpec(bob: groundLevel)

    var isTemplateEligible: Bool { colorMode == .adaptive && adaptiveColorHex == nil }
}

struct ClawdPlacement: Equatable {
    var spec: ClawdDrawSpec
    var slot: CGFloat
}

enum ClawdTint {
    static func adaptiveHex(_ appearance: NSAppearance?) -> String {
        var resolved = NSColor.labelColor
        (appearance ?? NSApp.effectiveAppearance).performAsCurrentDrawingAppearance {
            resolved = NSColor.labelColor.usingColorSpace(.sRGB) ?? NSColor.labelColor
        }
        return resolved.clawdHex
    }
}

enum ClawdSprite {

    static let liveSize = NSSize(width: 29, height: 22)
    static let verticalMargin: CGFloat = 7
    static let clusterStep: CGFloat = 12
    private static let seamBleed: CGFloat = 0.25
    private static let haloWidth: CGFloat = 0.6
    private static let dimFalloff = 0.8
    private static let dimFloor: CGFloat = 0.4

    static func dim(forSlot slot: CGFloat) -> CGFloat {
        max(dimFloor, CGFloat(pow(dimFalloff, Double(max(0, slot)))))
    }

    static func image(_ spec: ClawdDrawSpec, size: NSSize) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(spec, into: ctx, size: size)
            return true
        }
        image.isTemplate = spec.isTemplateEligible
        return image
    }

    static func liftedImage(_ spec: ClawdDrawSpec, size: NSSize, lift: CGFloat) -> NSImage {
        let base = image(spec, size: size)
        let out = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect.offsetBy(dx: 0, dy: lift))
            return true
        }
        out.isTemplate = base.isTemplate
        return out
    }

    static func centeredImage(_ spec: ClawdDrawSpec, size: NSSize) -> NSImage {
        liftedImage(spec, size: size, lift: verticalShift(for: spec, size: size))
    }

    static func clusterImage(_ placements: [ClawdPlacement], unit: NSSize,
                             step: CGFloat = clusterStep, centered: Bool = false) -> NSImage {
        guard !placements.isEmpty else { return NSImage(size: unit) }
        let maxSlot = CGFloat(placements.count - 1)
        let total = NSSize(width: unit.width + maxSlot * step, height: unit.height)
        let ordered = placements.sorted { $0.slot > $1.slot }
        let overlapped = placements.count > 1
        let shift = centered ? verticalShift(for: placements[0].spec, size: unit) : 0

        let image = NSImage(size: total, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            for placement in ordered {
                ctx.saveGState()
                ctx.translateBy(x: min(max(placement.slot, 0), maxSlot) * step, y: shift)
                draw(placement.spec, into: ctx, size: unit, knockout: overlapped)
                ctx.restoreGState()
            }
            return true
        }
        image.isTemplate = placements.allSatisfy { $0.spec.isTemplateEligible }
        return image
    }

    static func verticalShift(for spec: ClawdDrawSpec, size: NSSize) -> CGFloat {
        let px = pixel(for: size)
        return (size.height - px * CGFloat(ClawdFrame.height)) / 2 - spec.bob
    }

    static func inkBounds(_ spec: ClawdDrawSpec, size: NSSize) -> CGRect {
        let px = pixel(for: size)
        let originX = -px * CGFloat(ClawdFrame.width) / 2
        let transform = CGAffineTransform(translationX: size.width / 2 + spec.shift, y: spec.bob)
            .rotated(by: spec.leanRadians)
            .scaledBy(x: spec.scaleX, y: spec.scaleY)
        var bounds = CGRect.null
        for block in parsed(spec.frame, closedEyes: spec.closedEyes).silhouette {
            let rect = CGRect(x: originX + CGFloat(block.left) * px,
                              y: CGFloat(ClawdFrame.height - 1 - block.bottom) * px,
                              width: CGFloat(block.right - block.left + 1) * px,
                              height: CGFloat(block.bottom - block.top + 1) * px)
            bounds = bounds.union(rect.applying(transform))
        }
        return bounds
    }

    private static func pixel(for size: NSSize) -> CGFloat {
        min((size.height - verticalMargin) / CGFloat(ClawdFrame.height),
            size.width / CGFloat(ClawdFrame.width))
    }

    private struct CellBlock {
        var top: Int
        var bottom: Int
        var left: Int
        var right: Int
    }

    private struct SpriteKey: Hashable {
        let frame: ClawdFrame
        let closedEyes: Bool
    }

    private struct ParsedSprite {
        var body: [CellBlock]
        var silhouette: [CellBlock]
        var dark: [(col: Int, row: Int)]
    }

    private static var parseCache: [SpriteKey: ParsedSprite] = [:]

    private static func parsed(_ frame: ClawdFrame, closedEyes: Bool) -> ParsedSprite {
        let key = SpriteKey(frame: frame, closedEyes: closedEyes)
        if let hit = parseCache[key] { return hit }

        let lines = frame.lines
        var dark: [(col: Int, row: Int)] = []
        let rows = lines.count
        let cols = ClawdFrame.width
        for r in 0..<rows {
            let chars = Array(lines[r])
            for c in 0..<min(cols, chars.count) where chars[c] == "E" {
                guard closedEyes else {
                    dark.append((c, r))
                    continue
                }
                let isUpper = r + 1 < rows && c < lines[r + 1].count
                    && Array(lines[r + 1])[c] == "E"
                if isUpper {
                    dark.append((c - 1, r))
                    dark.append((c + 1, r))
                } else {
                    dark.append((c, r))
                }
            }
        }

        let sprite = ParsedSprite(body: blocks(lines, includingEyes: closedEyes),
                                  silhouette: blocks(lines, includingEyes: true),
                                  dark: dark)
        parseCache[key] = sprite
        return sprite
    }

    private static func blocks(_ lines: [String], includingEyes: Bool) -> [CellBlock] {
        var closed: [CellBlock] = []
        var open: [CellBlock] = []
        var openRuns: [ClosedRange<Int>] = []

        for (row, line) in lines.enumerated() {
            let chars = Array(line)
            var runs: [ClosedRange<Int>] = []
            var start: Int?
            for c in 0...chars.count {
                let ink = c < chars.count && chars[c] != "." && (includingEyes || chars[c] != "E")
                if ink, start == nil { start = c }
                if !ink, let s = start {
                    runs.append(s...(c - 1))
                    start = nil
                }
            }
            if runs == openRuns {
                for i in open.indices { open[i].bottom = row }
            } else {
                closed.append(contentsOf: open)
                open = runs.map { CellBlock(top: row, bottom: row, left: $0.lowerBound, right: $0.upperBound) }
                openRuns = runs
            }
        }
        return closed + open
    }

    static func draw(_ spec: ClawdDrawSpec, into ctx: CGContext, size: NSSize, knockout: Bool = false) {
        let rows = ClawdFrame.height
        let px = pixel(for: size)
        let crabW = px * CGFloat(ClawdFrame.width)
        let floorY: CGFloat = 0

        ctx.saveGState()
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .none

        ctx.translateBy(x: size.width / 2 + spec.shift, y: floorY + spec.bob)
        ctx.rotate(by: spec.leanRadians)
        ctx.scaleBy(x: spec.scaleX, y: spec.scaleY)

        let originX = -crabW / 2

        func rect(_ block: CellBlock, outset: CGFloat) -> CGRect {
            CGRect(x: originX + CGFloat(block.left) * px,
                   y: CGFloat(rows - 1 - block.bottom) * px,
                   width: CGFloat(block.right - block.left + 1) * px,
                   height: CGFloat(block.bottom - block.top + 1) * px)
                .insetBy(dx: -outset, dy: -outset)
        }

        let sprite = Self.parsed(spec.frame, closedEyes: spec.closedEyes)

        if knockout {
            let silhouette = CGMutablePath()
            for block in sprite.silhouette {
                silhouette.addRect(rect(block, outset: seamBleed + haloWidth))
            }
            ctx.saveGState()
            ctx.setAlpha(1)
            ctx.setBlendMode(.clear)
            ctx.addPath(silhouette)
            ctx.fillPath()
            ctx.restoreGState()
        }

        let bodyPath = CGMutablePath()
        for block in sprite.body {
            bodyPath.addRect(rect(block, outset: seamBleed))
        }

        let darkPath = CGMutablePath()
        for cell in sprite.dark {
            darkPath.addRect(CGRect(x: originX + CGFloat(cell.col) * px,
                                    y: CGFloat(rows - 1 - cell.row) * px,
                                    width: px, height: px))
        }

        ctx.setAlpha(spec.alpha * spec.dim)

        let bodyColor: NSColor
        switch spec.colorMode {
        case .adaptive: bodyColor = NSColor(clawdHex: spec.adaptiveColorHex) ?? .black
        case .coral: bodyColor = ClawdColors.coral
        case .custom: bodyColor = NSColor(clawdHex: spec.customColorHex) ?? ClawdColors.coral
        }
        ctx.addPath(bodyPath)
        ctx.setFillColor(bodyColor.cgColor)
        ctx.fillPath()

        ctx.addPath(darkPath)
        if spec.colorMode == .adaptive {
            ctx.setAlpha(1)
            ctx.setBlendMode(.clear)
            ctx.fillPath()
        } else {
            ctx.setFillColor(ClawdColors.eye.cgColor)
            ctx.fillPath()
        }

        ctx.restoreGState()
    }
}

extension NSColor {
    convenience init?(clawdHex hex: String?) {
        guard var s = hex?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = Int(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255.0,
                  green: CGFloat((value >> 8) & 0xFF) / 255.0,
                  blue: CGFloat(value & 0xFF) / 255.0,
                  alpha: 1)
    }

    var clawdHex: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X",
                      Int(round(c.redComponent * 255)),
                      Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }
}
