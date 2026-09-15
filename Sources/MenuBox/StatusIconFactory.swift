import AppKit

enum StatusIconFactory {
    static func boxIcon() -> NSImage {
        if let image = NSImage(systemSymbolName: "shippingbox", accessibilityDescription: "MenuBox") {
            return horizontallyFlippedTemplateImage(image)
        }

        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()
        NSColor.labelColor.setStroke()
        let path = NSBezierPath(roundedRect: NSRect(x: 3, y: 4, width: 12, height: 10), xRadius: 2, yRadius: 2)
        path.lineWidth = 1.6
        path.stroke()
        NSBezierPath.strokeLine(from: NSPoint(x: 3, y: 8), to: NSPoint(x: 15, y: 8))
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    static func tapeIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()

        NSColor.labelColor.setFill()
        let body = NSBezierPath(roundedRect: NSRect(x: 7, y: 2.5, width: 4, height: 13), xRadius: 1.7, yRadius: 1.7)
        body.fill()

        NSColor.windowBackgroundColor.setStroke()
        for y in stride(from: 4.5, through: 13.5, by: 3) {
            let stripe = NSBezierPath()
            stripe.move(to: NSPoint(x: 7.4, y: y))
            stripe.line(to: NSPoint(x: 10.6, y: y + 1.4))
            stripe.lineWidth = 0.8
            stripe.stroke()
        }

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private static func horizontallyFlippedTemplateImage(_ source: NSImage) -> NSImage {
        let size = source.size.width > 0 && source.size.height > 0
            ? source.size
            : NSSize(width: 18, height: 18)
        let image = NSImage(size: size)

        image.lockFocus()
        guard let context = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            source.isTemplate = true
            return source
        }

        context.translateBy(x: size.width, y: 0)
        context.scaleBy(x: -1, y: 1)
        source.draw(in: NSRect(origin: .zero, size: size))
        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}
