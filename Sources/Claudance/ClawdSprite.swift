import AppKit

enum ClawdFrame {
    static let cols = 18
    static let rows = 10

    static let apart: [String] = [
        "...CCCCCCCCCCCC...",
        "...CCCCCCCCCCCC...",
        "...CCECCCCCCECC...",
        "...CCECCCCCCECC...",
        ".CCCCCCCCCCCCCCCC.",
        ".CCCCCCCCCCCCCCCC.",
        "...CCCCCCCCCCCC...",
        "...CCCCCCCCCCCC...",
        "....C.C....C.C....",
        "....C.C....C.C....",
    ]

    static let together: [String] = [
        "...CCCCCCCCCCCC...",
        "...CCCCCCCCCCCC...",
        "...CCECCCCCCECC...",
        "...CCECCCCCCECC...",
        ".CCCCCCCCCCCCCCCC.",
        ".CCCCCCCCCCCCCCCC.",
        "...CCCCCCCCCCCC...",
        "...CCCCCCCCCCCC...",
        "....C.C....C.C....",
        "..................",
    ]
}

struct ClawdColors {
    static let coral = NSColor(srgbRed: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0, alpha: 1)
    static let eye = NSColor(srgbRed: 0x2A / 255.0, green: 0x15 / 255.0, blue: 0x10 / 255.0, alpha: 1)
}

struct ClawdDrawSpec: Equatable {
    var frame: [String] = ClawdFrame.apart
    var bob: CGFloat = 0
    var leanRadians: CGFloat = 0
    var scaleX: CGFloat = 1
    var scaleY: CGFloat = 1
    var colorMode: SpriteColorMode = .coral
    var customColorHex: String? = nil
    var alpha: CGFloat = 1
    var closedEyes: Bool = false

    static let standing = ClawdDrawSpec(bob: 1.6)
}

enum ClawdSprite {

    static let liveSize = NSSize(width: 29, height: 22)
    static let verticalMargin: CGFloat = 7

    static func image(_ spec: ClawdDrawSpec, size: NSSize) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(spec, into: ctx, size: size)
            return true
        }
        image.isTemplate = spec.colorMode == .adaptive
        return image
    }

    static func centeredImage(_ spec: ClawdDrawSpec, size: NSSize) -> NSImage {
        let rows = spec.frame.count
        let cols = spec.frame.first?.count ?? ClawdFrame.cols
        let px = min((size.height - verticalMargin) / CGFloat(rows), size.width / CGFloat(cols))
        let shift = (size.height - px * CGFloat(rows)) / 2
        let base = image(spec, size: size)
        let out = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect.offsetBy(dx: 0, dy: shift))
            return true
        }
        out.isTemplate = base.isTemplate
        return out
    }

    static func composite(_ specs: [ClawdDrawSpec], size: NSSize) -> NSImage {
        guard specs.count > 1 else {
            return image(specs.first ?? ClawdDrawSpec(), size: size)
        }
        let total = NSSize(width: size.width * CGFloat(specs.count), height: size.height)
        let image = NSImage(size: total, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            for (i, spec) in specs.enumerated() {
                ctx.saveGState()
                ctx.translateBy(x: size.width * CGFloat(i), y: 0)
                draw(spec, into: ctx, size: size)
                ctx.restoreGState()
            }
            return true
        }
        image.isTemplate = specs.allSatisfy { $0.colorMode == .adaptive }
        return image
    }

    static func draw(_ spec: ClawdDrawSpec, into ctx: CGContext, size: NSSize) {
        let rows = spec.frame.count
        let cols = spec.frame.first?.count ?? ClawdFrame.cols

        let horizontalMargin: CGFloat = 0
        let px = min((size.height - verticalMargin) / CGFloat(rows),
                     (size.width - horizontalMargin) / CGFloat(cols))
        let crabW = px * CGFloat(cols)
        let floorY: CGFloat = 0

        ctx.saveGState()
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .none
        ctx.setAlpha(spec.alpha)

        ctx.translateBy(x: size.width / 2, y: floorY + spec.bob)
        ctx.rotate(by: spec.leanRadians)
        ctx.scaleBy(x: spec.scaleX, y: spec.scaleY)

        let bodyPath = CGMutablePath()
        let darkPath = CGMutablePath()
        let originX = -crabW / 2

        for r in 0..<rows {
            let chars = Array(spec.frame[r])
            for c in 0..<min(cols, chars.count) {
                let ch = chars[c]
                if ch == "." { continue }
                let x = originX + CGFloat(c) * px
                let y = CGFloat(rows - 1 - r) * px
                let cell = CGRect(x: x, y: y, width: px, height: px)
                switch ch {
                case "E":
                    if spec.closedEyes {
                        bodyPath.addRect(cell.insetBy(dx: -0.25, dy: -0.25))
                        let isUpper = r + 1 < rows && c < spec.frame[r + 1].count
                            && Array(spec.frame[r + 1])[c] == "E"
                        if isUpper {
                            darkPath.addRect(CGRect(x: x - px, y: y, width: px, height: px))
                            darkPath.addRect(CGRect(x: x + px, y: y, width: px, height: px))
                        } else {
                            darkPath.addRect(cell)
                        }
                    } else {
                        darkPath.addRect(cell)
                    }
                default:
                    bodyPath.addRect(cell.insetBy(dx: -0.25, dy: -0.25))
                }
            }
        }

        let bodyColor: NSColor
        switch spec.colorMode {
        case .adaptive: bodyColor = .black
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
