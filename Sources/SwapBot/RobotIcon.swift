import AppKit

enum RobotIcon {
    enum Badge {
        case questionmark, xmark

        var symbol: String {
            switch self {
            case .questionmark: "questionmark.circle.fill"
            case .xmark: "xmark.circle.fill"
            }
        }
    }

    static func image(badge: Badge? = nil) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.set()

            let stalk = NSBezierPath()
            stalk.move(to: NSPoint(x: 9, y: 13.5))
            stalk.line(to: NSPoint(x: 9, y: 15.3))
            stalk.lineWidth = 1.5
            stalk.stroke()
            NSBezierPath(ovalIn: NSRect(x: 7.6, y: 14.8, width: 2.8, height: 2.8)).fill()

            NSBezierPath(roundedRect: NSRect(x: 0.5, y: 6.5, width: 2, height: 3.5), xRadius: 0.8, yRadius: 0.8).fill()
            NSBezierPath(roundedRect: NSRect(x: 15.5, y: 6.5, width: 2, height: 3.5), xRadius: 0.8, yRadius: 0.8).fill()

            let head = NSBezierPath(roundedRect: NSRect(x: 3, y: 2.5, width: 12, height: 11), xRadius: 3, yRadius: 3)
            head.lineWidth = 1.5
            head.stroke()

            NSBezierPath(ovalIn: NSRect(x: 5.4, y: 7.4, width: 2.4, height: 2.6)).fill()
            NSBezierPath(ovalIn: NSRect(x: 10.2, y: 7.4, width: 2.4, height: 2.6)).fill()
            let mouth = NSBezierPath()
            mouth.move(to: NSPoint(x: 7, y: 5))
            mouth.line(to: NSPoint(x: 11, y: 5))
            mouth.lineWidth = 1.2
            mouth.lineCapStyle = .round
            mouth.stroke()

            if let badge {
                let rect = NSRect(x: 9.5, y: -0.5, width: 9, height: 9)
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: rect.insetBy(dx: -1, dy: -1)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
                NSImage(systemSymbolName: badge.symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(config)?
                    .draw(in: rect)
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Claude account"
        return image
    }

    static func writeAppIconset(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = points * scale
                let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
                try? appIconPNG(pixels: pixels)?.write(to: dir.appendingPathComponent(name))
            }
        }
    }

    static func appIconPNG(pixels: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        let side = CGFloat(pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        defer { NSGraphicsContext.restoreGraphicsState() }

        let body = NSRect(x: side * 100 / 1024, y: side * 100 / 1024, width: side * 824 / 1024, height: side * 824 / 1024)
        let squircle = NSBezierPath(roundedRect: body, xRadius: side * 185 / 1024, yRadius: side * 185 / 1024)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowOffset = NSSize(width: 0, height: -side * 10 / 1024)
        shadow.shadowBlurRadius = side * 20 / 1024
        shadow.set()
        NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1).setFill()
        squircle.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGradient(starting: NSColor(srgbRed: 0.91, green: 0.55, blue: 0.42, alpha: 1),
                   ending: NSColor(srgbRed: 0.78, green: 0.39, blue: 0.27, alpha: 1))?
            .draw(in: squircle, angle: -90)

        let robot = image()
        let white = NSImage(size: robot.size, flipped: false) { rect in
            robot.draw(in: rect)
            NSColor.white.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        white.draw(in: body.insetBy(dx: body.width * 0.17, dy: body.height * 0.17))
        return rep.representation(using: .png, properties: [:])
    }
}
