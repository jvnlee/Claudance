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

struct ClawdDrawSpec {
    var frame: [String] = ClawdFrame.apart
    var bob: CGFloat = 0
    var leanRadians: CGFloat = 0
    var scaleX: CGFloat = 1
    var scaleY: CGFloat = 1
    var bodyColor: NSColor = ClawdColors.coral
    var alpha: CGFloat = 1
    var closedEyes: Bool = false
}

enum ClawdSprite {

    static let liveSize = NSSize(width: 32, height: 22)

    static func image(_ spec: ClawdDrawSpec, size: NSSize) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(spec, into: ctx, size: size)
            return true
        }
        image.isTemplate = false
        return image
    }

    static func draw(_ spec: ClawdDrawSpec, into ctx: CGContext, size: NSSize) {
        let rows = spec.frame.count
        let cols = spec.frame.first?.count ?? ClawdFrame.cols

        let verticalMargin: CGFloat = 7
        let horizontalMargin: CGFloat = 4
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
                        darkPath.addRect(CGRect(x: x, y: y, width: px, height: px * 0.32))
                    } else {
                        darkPath.addRect(cell)
                    }
                default:
                    bodyPath.addRect(cell.insetBy(dx: -0.25, dy: -0.25))
                }
            }
        }

        ctx.addPath(bodyPath)
        ctx.setFillColor(spec.bodyColor.cgColor)
        ctx.fillPath()

        ctx.addPath(darkPath)
        ctx.setFillColor(ClawdColors.eye.cgColor)
        ctx.fillPath()

        ctx.restoreGState()
    }
}
