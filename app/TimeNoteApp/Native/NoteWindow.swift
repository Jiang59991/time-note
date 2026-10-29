import AppKit
import WebKit

final class NoteWindow: NSWindow {
    var compactMode = false
    override var canBecomeKey: Bool { !compactMode }
    override var canBecomeMain: Bool { !compactMode }

    override func sendEvent(_ event: NSEvent) {
        // Hover expansion intentionally stays non-key. A borderless WebKit window
        // can otherwise accept a click without becoming the text input target.
        // Activate only on a deliberate click, before WebKit processes its focus.
        if !compactMode && event.type == .leftMouseDown {
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
            if !isKeyWindow { makeKeyAndOrderFront(nil) }
        }
        super.sendEvent(event)
    }
}

/// Sits above WebKit but receives only the empty top strip and central date area.
/// All navigation buttons, tabs, forms and menus pass directly to WebKit.
final class NoteDragSurface: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, window?.isMovable == true else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        let fromTop = bounds.height - local.y
        let topStrip = fromTop < 20 && local.x < bounds.width - 45
        let dateArea = fromTop < 52 && local.x > 65 && local.x < bounds.width - 65
        return topStrip || dateArea ? self : nil
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private var dragAnchor: (pointer: NSPoint, origin: NSPoint)?
    override func mouseDown(with event: NSEvent) {
        guard let window, window.isMovable else { return }
        window.makeKey()
        dragAnchor = (window.convertPoint(toScreen: event.locationInWindow), window.frame.origin)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window, window.isMovable, let anchor = dragAnchor else { return }
        let pointer = window.convertPoint(toScreen: event.locationInWindow)
        window.setFrameOrigin(NSPoint(x: anchor.origin.x + pointer.x - anchor.pointer.x,
                                      y: anchor.origin.y + pointer.y - anchor.pointer.y))
    }
    override func mouseUp(with event: NSEvent) { dragAnchor = nil }
    override func resetCursorRects() {
        guard window?.isMovable == true else { return }
        addCursorRect(NSRect(x: 0, y: bounds.height - 20, width: max(0, bounds.width - 45), height: 20), cursor: .openHand)
        addCursorRect(NSRect(x: 65, y: bounds.height - 52, width: max(0, bounds.width - 130), height: 32), cursor: .openHand)
    }
}

/// A real 40-point window, not an invisible full-size panel over other apps.
final class NoteOrbView: NSView {
    var onOpen: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    var onDragEnd: (() -> Void)?
    private var anchor: (pointer: NSPoint, origin: NSPoint)?
    private var moved = false
    private(set) var holdingPointer = false
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        holdingPointer = true; moved = false
        anchor = (window.convertPoint(toScreen: event.locationInWindow), window.frame.origin)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window, window.isMovable, let anchor else { return }
        let pointer = window.convertPoint(toScreen: event.locationInWindow)
        let dx = pointer.x - anchor.pointer.x, dy = pointer.y - anchor.pointer.y
        guard moved || hypot(dx, dy) >= 3 else { return }
        moved = true
        var origin = NSPoint(x: anchor.origin.x + dx, y: anchor.origin.y + dy)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? window.screen {
            origin.x = min(screen.visibleFrame.maxX - window.frame.width, max(screen.visibleFrame.minX, origin.x))
            origin.y = min(screen.visibleFrame.maxY - window.frame.height, max(screen.visibleFrame.minY, origin.y))
        }
        window.setFrameOrigin(origin)
    }
    override func mouseUp(with event: NSEvent) {
        holdingPointer = false; anchor = nil
        if moved { onDragEnd?() } else { onOpen?() }
        moved = false
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 1, green: 0.827, blue: 0.18, alpha: 1).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
        NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
        for x in [13.0, 24.0] {
            NSBezierPath(roundedRect: NSRect(x: x, y: 15, width: 3, height: 10), xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { "展开时间便签" }
    override func accessibilityPerformPress() -> Bool { onOpen?(); return true }
}

final class NoteWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
