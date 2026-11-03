import AppKit

/// One template image keeps the warning attached to the status item on macOS.
@MainActor
enum MenuBarStatusImage {
    static func make(needsAttention: Bool) -> NSImage {
        let mustache = NSImage(systemSymbolName: "mustache.fill", accessibilityDescription: nil)!
        guard needsAttention else { return mustache }
        let warning = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)!
        let image = NSImage(size: NSSize(width: 26, height: 18), flipped: false) { _ in
            mustache.draw(in: NSRect(x: 0, y: 0, width: 20, height: 14))
            // Clear space around the badge so both symbols stay legible in either appearance.
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .copy
            NSColor.clear.setFill()
            NSBezierPath(roundedRect: NSRect(x: 13, y: 6, width: 13, height: 12), xRadius: 3, yRadius: 3).fill()
            NSGraphicsContext.restoreGraphicsState()
            warning.draw(in: NSRect(x: 14, y: 7, width: 12, height: 11))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "MovemberCam needs attention"
        return image
    }
}
