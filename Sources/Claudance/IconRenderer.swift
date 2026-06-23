import AppKit

enum IconRenderer {

    static func dump(to dir: String) {
        let side = 1024
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: side, pixelsHigh: side,
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
        draw(into: nsctx.cgContext, side: CGFloat(side))
        NSGraphicsContext.restoreGraphicsState()

        let outURL = URL(fileURLWithPath: dir).appendingPathComponent("AppIcon_1024.png")
        if let data = rep.representation(using: .png, properties: [:]) {
            do {
                try data.write(to: outURL)
                FileHandle.standardOutput.write("wrote \(outURL.path)\n".data(using: .utf8)!)
            } catch {
                FileHandle.standardError.write("failed to write \(outURL.path): \(error.localizedDescription)\n".data(using: .utf8)!)
            }
        }
    }

    static func draw(into ctx: CGContext, side: CGFloat) {
        let margin = side * (100.0 / 1024.0)
        let body = CGRect(x: margin, y: margin, width: side - 2 * margin, height: side - 2 * margin)
        let radius = body.width * 0.2237
        let squircle = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -side * 0.012),
                      blur: side * 0.03,
                      color: NSColor(white: 0, alpha: 0.22).cgColor)
        ctx.addPath(squircle)
        ctx.setFillColor(srgb(0x2E, 0x2E, 0x32))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(squircle)
        ctx.clip()
        if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: [srgb(0x3A, 0x3A, 0x3E), srgb(0x28, 0x28, 0x2C)] as CFArray,
                                 locations: [0, 1]) {
            ctx.drawLinearGradient(grad,
                                   start: CGPoint(x: 0, y: body.maxY),
                                   end: CGPoint(x: 0, y: body.minY),
                                   options: [])
        }
        ctx.restoreGState()
    }

    private static func srgb(_ r: Int, _ g: Int, _ b: Int) -> CGColor {
        NSColor(srgbRed: CGFloat(r) / 255.0, green: CGFloat(g) / 255.0, blue: CGFloat(b) / 255.0, alpha: 1).cgColor
    }
}
