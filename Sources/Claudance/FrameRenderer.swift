import AppKit
import ImageIO
import UniformTypeIdentifiers

enum FrameRenderer {

    static func dump(to dir: String) {
        let liveSize = ClawdSprite.liveSize
        let scale: CGFloat = 12
        let cellW = Int(liveSize.width * scale)
        let cellH = Int(liveSize.height * scale)
        let framesPerRow = 6

        let rows: [(String, ClaudeActivity, Double)] = [
            ("rest", .rest, 0),
            ("idle", .idle, 0),
            ("waiting", .waiting, 0),
            ("work .5", .working, 0.5),
            ("work 1.0", .working, 1.0),
        ]

        let sheetW = cellW * framesPerRow
        let sheetH = cellH * rows.count

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: sheetW, pixelsHigh: sheetH,
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let nsctx = NSGraphicsContext(bitmapImageRep: rep) else {
            FileHandle.standardError.write("failed to make bitmap context\n".data(using: .utf8)!)
            return
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsctx
        let ctx = nsctx.cgContext

        for (ri, row) in rows.enumerated() {
            let specs = sequence(state: row.1, activity: row.2, frames: framesPerRow)
            for (ci, spec) in specs.enumerated() {
                let ox = CGFloat(ci * cellW)
                let oy = CGFloat((rows.count - 1 - ri) * cellH)
                ctx.saveGState()
                ctx.translateBy(x: ox, y: oy)
                ctx.scaleBy(x: scale, y: scale)
                let bg: NSColor = (ci % 2 == 0)
                    ? NSColor(white: 0.10, alpha: 1)
                    : NSColor(white: 0.95, alpha: 1)
                ctx.setFillColor(bg.cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: liveSize.width, height: liveSize.height))
                ClawdSprite.draw(spec, into: ctx, size: liveSize)
                ctx.restoreGState()
            }
        }

        NSGraphicsContext.restoreGraphicsState()

        let outURL = URL(fileURLWithPath: dir).appendingPathComponent("clawd_sheet.png")
        if let data = rep.representation(using: .png, properties: [:]) {
            do {
                try data.write(to: outURL)
                FileHandle.standardOutput.write("wrote \(outURL.path)\n".data(using: .utf8)!)
            } catch {
                FileHandle.standardError.write("failed to write \(outURL.path): \(error.localizedDescription)\n".data(using: .utf8)!)
            }
        }
    }

    static func loopStrip(to dir: String) {
        let liveSize = ClawdSprite.liveSize
        let scale: CGFloat = 10
        let cellW = Int(liveSize.width * scale)
        let cellH = Int(liveSize.height * scale)
        let samples = 24

        let rows: [(String, ClaudeActivity, Double)] = [
            ("idle", .idle, 0.30),
            ("waiting", .waiting, 0.60),
            ("working", .working, 1.00),
        ]

        let cols = samples + 1
        let sheetW = cellW * cols
        let sheetH = cellH * rows.count

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: sheetW, pixelsHigh: sheetH,
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let nsctx = NSGraphicsContext(bitmapImageRep: rep) else {
            FileHandle.standardError.write("failed to make bitmap context\n".data(using: .utf8)!)
            return
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsctx
        let ctx = nsctx.cgContext

        for (ri, row) in rows.enumerated() {
            for ci in 0..<cols {
                let i = ci % samples
                let phase = Animator.loopPhase * Double(i) / Double(samples)
                let spec = Animator.pose(state: row.1, phase: phase, energy: row.2)

                let ox = CGFloat(ci * cellW)
                let oy = CGFloat((rows.count - 1 - ri) * cellH)
                ctx.saveGState()
                ctx.translateBy(x: ox, y: oy)
                ctx.scaleBy(x: scale, y: scale)
                let bg: NSColor = (ci == samples)
                    ? NSColor(srgbRed: 0.13, green: 0.27, blue: 0.16, alpha: 1)
                    : NSColor(white: 0.11, alpha: 1)
                ctx.setFillColor(bg.cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: liveSize.width, height: liveSize.height))
                ClawdSprite.draw(spec, into: ctx, size: liveSize)
                ctx.restoreGState()
            }
        }

        NSGraphicsContext.restoreGraphicsState()

        let outURL = URL(fileURLWithPath: dir).appendingPathComponent("clawd_loop.png")
        if let data = rep.representation(using: .png, properties: [:]) {
            do {
                try data.write(to: outURL)
                FileHandle.standardOutput.write("wrote \(outURL.path)\n".data(using: .utf8)!)
            } catch {
                FileHandle.standardError.write("failed to write \(outURL.path): \(error.localizedDescription)\n".data(using: .utf8)!)
            }
        }
    }

    static func loopGif(to dir: String, state stateName: String) {
        let liveSize = ClawdSprite.liveSize
        let scale: CGFloat = 12
        let frameCount = 24

        let state: ClaudeActivity, energy: Double, speed: Double
        switch stateName {
        case "idle":    (state, energy, speed) = (.idle, 0.30, 2.4)
        case "waiting": (state, energy, speed) = (.waiting, 0.60, 7)
        default:        (state, energy, speed) = (.working, 1.00, 21)
        }

        let period = Animator.loopPhase / speed
        let delay = period / Double(frameCount)

        let outURL = URL(fileURLWithPath: dir).appendingPathComponent("clawd_loop.gif")
        guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL,
                                                         UTType.gif.identifier as CFString,
                                                         frameCount, nil) else {
            FileHandle.standardError.write("failed to create gif destination\n".data(using: .utf8)!)
            return
        }

        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFLoopCount as String: 0,
            ],
        ] as CFDictionary)

        let frameProps = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFUnclampedDelayTime as String: delay,
                kCGImagePropertyGIFDelayTime as String: delay,
            ],
        ] as CFDictionary

        for i in 0..<frameCount {
            let phase = Animator.loopPhase * Double(i) / Double(frameCount)
            let spec = Animator.pose(state: state, phase: phase, energy: energy)
            guard let cg = frameImage(spec, size: liveSize, scale: scale) else { continue }
            CGImageDestinationAddImage(dest, cg, frameProps)
        }

        if CGImageDestinationFinalize(dest) {
            let ms = String(format: "%.0f", period * 1000)
            FileHandle.standardOutput.write("wrote \(outURL.path) (\(stateName), \(frameCount) frames, \(ms)ms loop)\n".data(using: .utf8)!)
        } else {
            FileHandle.standardError.write("failed to finalize gif\n".data(using: .utf8)!)
        }
    }

    static func verifyLoop(state stateName: String) {
        let state: ClaudeActivity, energy: Double
        switch stateName {
        case "idle":    (state, energy) = (.idle, 0.30)
        case "waiting": (state, energy) = (.waiting, 0.60)
        default:        (state, energy) = (.working, 1.00)
        }

        let n = 24
        func sig(_ i: Int) -> [Double] {
            let phase = Animator.loopPhase * Double(i) / Double(n)
            let s = Animator.pose(state: state, phase: phase, energy: energy)
            return [Double(s.bob), Double(s.leanRadians) * 50, Double(s.scaleX) * 50, Double(s.scaleY) * 50]
        }
        func step(_ a: [Double], _ b: [Double]) -> Double {
            zip(a, b).map { abs($0 - $1) }.reduce(0, +)
        }

        var maxInterior = 0.0
        for i in 0..<(n - 1) { maxInterior = max(maxInterior, step(sig(i), sig(i + 1))) }
        let wrapStep = step(sig(n - 1), sig(0))
        let identity = step(sig(0), sig(n))

        let line = String(format:
            "loop seam check [%@]: wrap step = %.4f, max interior step = %.4f, " +
            "pose(0) vs pose(4pi) = %.2e  -> %@\n",
            stateName, wrapStep, maxInterior, identity,
            (identity < 1e-9 && wrapStep <= maxInterior * 1.05) ? "SEAMLESS" : "SEAM")
        FileHandle.standardOutput.write(line.data(using: .utf8)!)
    }

    private static func frameImage(_ spec: ClawdDrawSpec, size: NSSize, scale: CGFloat) -> CGImage? {
        let w = Int(size.width * scale)
        let h = Int(size.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let nsctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsctx
        let ctx = nsctx.cgContext
        ctx.setFillColor(NSColor(white: 0.11, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        ctx.scaleBy(x: scale, y: scale)
        ClawdSprite.draw(spec, into: ctx, size: size)
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    private static func sequence(state: ClaudeActivity, activity: Double, frames: Int) -> [ClawdDrawSpec] {
        var anim = Animator()
        let snap = ActivitySnapshot(state: state,
                                    presentCount: state == .rest ? 0 : 1,
                                    workingCount: state == .working ? 2 : 0,
                                    activity: activity)
        for _ in 0..<40 { _ = anim.update(snap, dt: 1.0 / 60.0) }
        var out: [ClawdDrawSpec] = []
        for _ in 0..<frames {
            var spec = anim.update(snap, dt: 1.0 / 60.0)
            for _ in 0..<4 { spec = anim.update(snap, dt: 1.0 / 60.0) }
            out.append(spec)
        }
        return out
    }
}
