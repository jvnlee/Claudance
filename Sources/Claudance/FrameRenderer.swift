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

    static func compositeSheet(to dir: String) {
        let liveSize = ClawdSprite.liveSize
        let scale: CGFloat = 12
        let states: [(ClaudeActivity, Double)] = [(.working, 1.0), (.waiting, 0.6), (.idle, 0.3)]

        let specs: [ClawdDrawSpec] = states.map { st in
            var anim = Animator()
            let snap = ActivitySnapshot(state: st.0, presentCount: 1,
                                        workingCount: st.0 == .working ? 2 : 0, activity: st.1)
            for _ in 0..<50 { _ = anim.update(snap, dance: .style(.bounce), dt: 1.0 / 60.0) }
            return anim.update(snap, dance: .style(.bounce), dt: 1.0 / 60.0)
        }

        let n = specs.count
        let cellW = Int(liveSize.width * scale)
        let cellH = Int(liveSize.height * scale)
        let sheetW = cellW * n
        let sheetH = cellH

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: sheetW, pixelsHigh: sheetH,
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let nsctx = NSGraphicsContext(bitmapImageRep: rep) else { return }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsctx
        let ctx = nsctx.cgContext

        for (i, spec) in specs.enumerated() {
            ctx.saveGState()
            ctx.translateBy(x: liveSize.width * scale * CGFloat(i), y: 0)
            ctx.scaleBy(x: scale, y: scale)
            ctx.setFillColor(NSColor(white: i % 2 == 0 ? 0.12 : 0.20, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: liveSize.width, height: liveSize.height))
            ClawdSprite.draw(spec, into: ctx, size: liveSize)
            ctx.restoreGState()
        }

        NSGraphicsContext.restoreGraphicsState()

        let outURL = URL(fileURLWithPath: dir).appendingPathComponent("clawd_composite.png")
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: outURL)
            FileHandle.standardOutput.write("wrote \(outURL.path)\n".data(using: .utf8)!)
        }
    }

    static func clusterSheet(to dir: String) {
        let unit = ClawdSprite.liveSize
        let scale: CGFloat = 10
        let gap: CGFloat = 6

        func settled(_ state: ClaudeActivity, _ activity: Double, _ working: Int) -> ClawdDrawSpec {
            var anim = Animator()
            let snap = ActivitySnapshot(state: state, presentCount: 1, workingCount: working, activity: activity)
            for _ in 0..<50 { _ = anim.update(snap, dance: .style(.bounce), dt: 1.0 / 60.0) }
            return anim.update(snap, dance: .style(.bounce), dt: 1.0 / 60.0)
        }

        let palette: [(SpriteColorMode, String?)] = [
            (.coral, nil), (.custom, "#3FA7A0"), (.custom, "#8A6FD1"), (.adaptive, nil), (.custom, "#C9A227"),
        ]
        let poses: [ClawdDrawSpec] = [
            settled(.working, 1.0, 3), settled(.working, 0.6, 1),
            settled(.waiting, 0, 0), settled(.idle, 0.3, 0), settled(.rest, 0, 0),
        ]

        func placements(count: Int, adaptiveHex: String) -> [ClawdPlacement] {
            (0..<count).map { i in
                var spec = poses[i]
                spec.colorMode = palette[i].0
                spec.customColorHex = palette[i].1
                spec.adaptiveColorHex = palette[i].0 == .adaptive ? adaptiveHex : nil
                spec.dim = ClawdSprite.dim(forSlot: CGFloat(i))
                return ClawdPlacement(spec: spec, slot: CGFloat(i))
            }
        }

        func sweep(_ sample: Int) -> [ClawdPlacement] {
            (0..<3).map { i in
                let phase = Double(sample) * Animator.loopPhase / 8 + Double(i) * 1.7
                let style = DanceStyle.allCases[i % DanceStyle.allCases.count]
                var spec = Animator.pose(state: .working, phase: phase, energy: 1.0, style: style)
                spec.colorMode = palette[i].0
                spec.customColorHex = palette[i].1
                spec.dim = ClawdSprite.dim(forSlot: CGFloat(i))
                return ClawdPlacement(spec: spec, slot: CGFloat(i))
            }
        }

        let counts = [2, 3, 5]
        let backgrounds: [(NSColor, String)] = [
            (NSColor(white: 0.13, alpha: 1), "#FFFFFF"),
            (NSColor(white: 0.95, alpha: 1), "#000000"),
        ]
        let sweeps = 8

        let maxWidth = unit.width + CGFloat(counts.max()! - 1) * ClawdSprite.clusterStep
        let sheetW = Int(maxWidth * scale)
        let rowH = unit.height * scale + gap
        let sheetH = Int(rowH * CGFloat(counts.count * backgrounds.count + sweeps))

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: sheetW, pixelsHigh: sheetH,
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let nsctx = NSGraphicsContext(bitmapImageRep: rep) else { return }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsctx
        nsctx.imageInterpolation = .none
        let ctx = nsctx.cgContext

        var row = 0
        for (background, adaptiveHex) in backgrounds {
            for count in counts {
                let items = placements(count: count, adaptiveHex: adaptiveHex)
                let image = ClawdSprite.clusterImage(items, unit: unit)
                let y = CGFloat(sheetH) - CGFloat(row + 1) * rowH + gap
                ctx.setFillColor(background.cgColor)
                ctx.fill(CGRect(x: 0, y: y, width: CGFloat(sheetW), height: unit.height * scale))
                let dest = NSRect(x: 0, y: y, width: image.size.width * scale, height: image.size.height * scale)
                image.draw(in: dest, from: .zero, operation: .sourceOver, fraction: 1)
                row += 1
            }
        }

        for sample in 0..<sweeps {
            let image = ClawdSprite.clusterImage(sweep(sample), unit: unit)
            let y = CGFloat(sheetH) - CGFloat(row + 1) * rowH + gap
            ctx.setFillColor(NSColor(white: sample % 2 == 0 ? 0.13 : 0.95, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 0, y: y, width: CGFloat(sheetW), height: unit.height * scale))
            let dest = NSRect(x: 0, y: y, width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: dest, from: .zero, operation: .sourceOver, fraction: 1)
            row += 1
        }

        NSGraphicsContext.restoreGraphicsState()

        let outURL = URL(fileURLWithPath: dir).appendingPathComponent("clawd_cluster.png")
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: outURL)
            FileHandle.standardOutput.write("wrote \(outURL.path)\n".data(using: .utf8)!)
        }
    }

    static func loopStrip(to dir: String) {
        let liveSize = ClawdSprite.liveSize
        let scale: CGFloat = 10
        let cellW = Int(liveSize.width * scale)
        let cellH = Int(liveSize.height * scale)
        let samples = 24

        var rows: [(String, ClaudeActivity, Double, DanceStyle)] = [
            ("idle", .idle, 0.30, .bounce),
            ("waiting", .waiting, 0.60, .bounce),
        ]
        rows += DanceStyle.allCases.map { ($0.rawValue, .working, 1.00, $0) }

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
                let spec = Animator.pose(state: row.1, phase: phase, energy: row.2, style: row.3)

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

    static func loopGif(to dir: String, state stateName: String, style: DanceStyle) {
        let liveSize = ClawdSprite.liveSize
        let scale: CGFloat = 12
        let frameCount = 24

        let state: ClaudeActivity, energy: Double, speed: Double
        switch stateName {
        case "idle":    (state, energy, speed) = (.idle, 0.30, 2.4)
        case "waiting": (state, energy, speed) = (.waiting, 0.60, 7)
        default:        (state, energy, speed) = (.working, 1.00, 21 * style.tempo)
        }

        let period = Animator.loopPhase / speed
        let delay = period / Double(frameCount)
        let label = state == .working ? style.rawValue : stateName

        let outURL = URL(fileURLWithPath: dir).appendingPathComponent("clawd_loop_\(label).gif")
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
            let spec = Animator.pose(state: state, phase: phase, energy: energy, style: style)
            guard let cg = frameImage(spec, size: liveSize, scale: scale) else { continue }
            CGImageDestinationAddImage(dest, cg, frameProps)
        }

        if CGImageDestinationFinalize(dest) {
            let ms = String(format: "%.0f", period * 1000)
            FileHandle.standardOutput.write("wrote \(outURL.path) (\(label), \(frameCount) frames, \(ms)ms loop)\n".data(using: .utf8)!)
        } else {
            FileHandle.standardError.write("failed to finalize gif\n".data(using: .utf8)!)
        }
    }

    static func verifyLoop(label: String, state: ClaudeActivity, energy: Double, style: DanceStyle) {
        let n = 24
        func pose(_ phase: Double) -> ClawdDrawSpec {
            Animator.pose(state: state, phase: phase, energy: energy, style: style)
        }
        func sig(_ i: Int) -> [Double] {
            let s = pose(Animator.loopPhase * Double(i) / Double(n))
            return [Double(s.bob), Double(s.shift), Double(s.leanRadians) * 50,
                    Double(s.scaleX) * 50, Double(s.scaleY) * 50]
        }
        func step(_ a: [Double], _ b: [Double]) -> Double {
            zip(a, b).map { abs($0 - $1) }.reduce(0, +)
        }

        var maxInterior = 0.0
        for i in 0..<(n - 1) { maxInterior = max(maxInterior, step(sig(i), sig(i + 1))) }
        let wrapStep = step(sig(n - 1), sig(0))
        let identity = step(sig(0), sig(n))

        let size = ClawdSprite.liveSize
        let samples = 96
        var left = 0.0, right = 0.0, top = 0.0
        for i in 0..<samples {
            let box = ClawdSprite.inkBounds(pose(Animator.loopPhase * Double(i) / Double(samples)), size: size)
            left = max(left, Double(-box.minX))
            right = max(right, Double(box.maxX - size.width))
            top = max(top, Double(box.maxY - size.height))
        }

        let line = String(format:
            "loop seam check [%@]: wrap step = %.4f, max interior step = %.4f, " +
            "pose(0) vs pose(4pi) = %.2e -> %@ | overflow left %.2f right %.2f top %.2f\n",
            label, wrapStep, maxInterior, identity,
            (identity < 1e-9 && wrapStep <= maxInterior * 1.05) ? "SEAMLESS" : "SEAM",
            left, right, top)
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
        for _ in 0..<40 { _ = anim.update(snap, dance: .style(.bounce), dt: 1.0 / 60.0) }
        var out: [ClawdDrawSpec] = []
        for _ in 0..<frames {
            var spec = anim.update(snap, dance: .style(.bounce), dt: 1.0 / 60.0)
            for _ in 0..<4 { spec = anim.update(snap, dance: .style(.bounce), dt: 1.0 / 60.0) }
            out.append(spec)
        }
        return out
    }
}
