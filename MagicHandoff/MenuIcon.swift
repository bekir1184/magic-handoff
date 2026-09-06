import AppKit

/// Menu bar icon: a rounded-square outline with a dot in the top-left corner,
/// like the app icon's LED. The dot is green when every known device is
/// connected to this Mac; otherwise it takes the outline's colour.
enum MenuIcon {
    private struct Key: Hashable { let connected: Bool; let dark: Bool }
    private static var cache: [Key: NSImage] = [:]

    static func image(allConnected: Bool, dark: Bool) -> NSImage {
        let key = Key(connected: allConnected, dark: dark)
        if let cached = cache[key] { return cached }

        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let ink: NSColor = dark ? .white : .black
            let green = NSColor(calibratedRed: 0.27, green: 0.80, blue: 0.36, alpha: 1)

            let frame = rect.insetBy(dx: 2, dy: 2)
            let outline = NSBezierPath(roundedRect: frame, xRadius: 4.5, yRadius: 4.5)
            outline.lineWidth = 1.8
            ink.setStroke()
            outline.stroke()

            let dotRadius: CGFloat = 2.1
            let center = NSPoint(x: frame.minX + 4.6, y: frame.maxY - 4.6)
            let dot = NSBezierPath(ovalIn: NSRect(x: center.x - dotRadius, y: center.y - dotRadius,
                                                  width: dotRadius * 2, height: dotRadius * 2))
            (allConnected ? green : ink).setFill()
            dot.fill()
            return true
        }
        image.isTemplate = false
        cache[key] = image
        return image
    }
}
