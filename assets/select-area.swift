import Cocoa

// Usage: select-area [x y w h screenIndex]   (points, relative to that screen's top-left)
// With no args, starts as the full screen under the mouse.
// Prints "x,y,w,h,scale,screenIndex" on Record, exits 1 on cancel.
// Drag handles on corners/sides to resize, drag anywhere else to move.
// Return / Record button = start, Esc / Cancel button / right-click = cancel.

let args = CommandLine.arguments
var screenIndex: Int? = nil
var initial: [Double]? = nil
if args.count >= 6, let x = Double(args[1]), let y = Double(args[2]), let w = Double(args[3]),
   let h = Double(args[4]), let i = Int(args[5]) {
    initial = [x, y, w, h]
    screenIndex = i
}

let minSize: CGFloat = 40
let grab: CGFloat = 12

enum Handle { case move, left, right, top, bottom, tl, tr, bl, br }

final class SelectView: NSView {
    var rect: NSRect
    var active: Handle?
    var dragOrigin = NSPoint.zero
    var rectOrigin = NSRect.zero
    var onDone: ((NSRect) -> Void)?

    init(frame: NSRect, initial: NSRect) {
        rect = initial
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var recordButton: NSRect { buttonRect(index: 0) }
    var cancelButton: NSRect { buttonRect(index: 1) }

    // Row of [Record] [Cancel], centered at the bottom of the box.
    func buttonRect(index: Int) -> NSRect {
        let widths: [CGFloat] = [90, 90], gap: CGFloat = 10
        let total = widths.reduce(0, +) + gap
        var x = rect.midX - total / 2 + widths[..<index].reduce(0, +) + gap * CGFloat(index)
        var y = rect.minY + 16
        let rowStart = min(max(rect.midX - total / 2, 4), bounds.width - total - 4)
        x += rowStart - (rect.midX - total / 2)
        y = min(max(y, 4), bounds.height - 34)
        return NSRect(x: x, y: y, width: widths[index], height: 30)
    }


    func handlePoints() -> [(Handle, NSPoint)] {
        [(.tl, NSPoint(x: rect.minX, y: rect.maxY)), (.tr, NSPoint(x: rect.maxX, y: rect.maxY)),
         (.bl, NSPoint(x: rect.minX, y: rect.minY)), (.br, NSPoint(x: rect.maxX, y: rect.minY)),
         (.left, NSPoint(x: rect.minX, y: rect.midY)), (.right, NSPoint(x: rect.maxX, y: rect.midY)),
         (.top, NSPoint(x: rect.midX, y: rect.maxY)), (.bottom, NSPoint(x: rect.midX, y: rect.minY))]
    }

    func hit(_ p: NSPoint) -> Handle? {
        for (h, pt) in handlePoints() where abs(p.x - pt.x) <= grab && abs(p.y - pt.y) <= grab { return h }
        if abs(p.x - rect.minX) <= grab / 2, p.y >= rect.minY, p.y <= rect.maxY { return .left }
        if abs(p.x - rect.maxX) <= grab / 2, p.y >= rect.minY, p.y <= rect.maxY { return .right }
        if abs(p.y - rect.minY) <= grab / 2, p.x >= rect.minX, p.x <= rect.maxX { return .bottom }
        if abs(p.y - rect.maxY) <= grab / 2, p.x >= rect.minX, p.x <= rect.maxX { return .top }
        return .move  // dragging anywhere else moves the box
    }

    override func draw(_ dirtyRect: NSRect) {
        // Fully transparent pixels are click-through on macOS, so the hole inside the box must be
        // nearly (not fully) transparent for the window to keep receiving mouse events.
        NSGraphicsContext.current?.compositingOperation = .copy
        NSColor.black.withAlphaComponent(0.4).setFill()
        bounds.fill()
        NSColor.black.withAlphaComponent(0.01).setFill()
        rect.fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver

        NSColor.systemRed.setStroke()
        let border = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
        border.lineWidth = 2
        border.stroke()

        NSColor.white.setFill()
        for (_, pt) in handlePoints() {
            let r = NSRect(x: pt.x - 5, y: pt.y - 5, width: 10, height: 10)
            let p = NSBezierPath(roundedRect: r.intersection(bounds.insetBy(dx: -5, dy: -5)), xRadius: 2, yRadius: 2)
            p.fill()
            NSColor.systemRed.setStroke()
            p.lineWidth = 1
            p.stroke()
        }

        let label = "\(Int(rect.width)) × \(Int(rect.height))" as NSString
        label.draw(at: NSPoint(x: rect.minX + 14, y: rect.maxY - 30), withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.6),
        ])

        drawButton(recordButton, "Record ⏎", NSColor.systemRed)
        drawButton(cancelButton, "Cancel ⎋", NSColor.darkGray)
    }

    func drawButton(_ r: NSRect, _ title: String, _ color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
        let s = title as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white,
        ]
        let sz = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2), withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if recordButton.contains(p) { onDone?(rect); return }
        if cancelButton.contains(p) { exit(1) }
        active = hit(p)
        dragOrigin = p
        rectOrigin = rect
    }

    override func mouseDragged(with event: NSEvent) {
        guard let h = active else { return }
        let p = convert(event.locationInWindow, from: nil)
        let dx = p.x - dragOrigin.x, dy = p.y - dragOrigin.y
        var minX = rectOrigin.minX, maxX = rectOrigin.maxX, minY = rectOrigin.minY, maxY = rectOrigin.maxY
        switch h {
        case .move:
            let w = rectOrigin.width, ht = rectOrigin.height
            minX = min(max(rectOrigin.minX + dx, 0), bounds.width - w)
            minY = min(max(rectOrigin.minY + dy, 0), bounds.height - ht)
            maxX = minX + w; maxY = minY + ht
        default:
            if [.left, .tl, .bl].contains(h) { minX = rectOrigin.minX + dx }
            if [.right, .tr, .br].contains(h) { maxX = rectOrigin.maxX + dx }
            if [.bottom, .bl, .br].contains(h) { minY = rectOrigin.minY + dy }
            if [.top, .tl, .tr].contains(h) { maxY = rectOrigin.maxY + dy }
            minX = max(0, min(minX, maxX - minSize)); maxX = min(bounds.width, max(maxX, minX + minSize))
            minY = max(0, min(minY, maxY - minSize)); maxY = min(bounds.height, max(maxY, minY + minSize))
        }
        rect = NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        needsDisplay = true
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    override func mouseUp(with event: NSEvent) { active = nil }
    override func rightMouseDown(with event: NSEvent) { exit(1) }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: exit(1)                       // esc
        case 36, 76: onDone?(rect)             // return / enter
        default: break
        }
    }
}

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { exit(1) }
        super.keyDown(with: event)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let mouse = NSEvent.mouseLocation
let screens = NSScreen.screens
let screen: NSScreen = {
    if let i = screenIndex, i < screens.count { return screens[i] }
    return screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
}()
let size = screen.frame.size

var start = NSRect(origin: .zero, size: size)
if let a = initial, a[0] >= 0, a[1] >= 0, a[2] >= minSize, a[3] >= minSize,
   a[0] + a[2] <= size.width, a[1] + a[3] <= size.height {
    start = NSRect(x: a[0], y: size.height - a[1] - a[3], width: a[2], height: a[3])
}

let window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
window.level = .screenSaver
window.isOpaque = false
window.backgroundColor = .clear
window.hasShadow = false
window.acceptsMouseMovedEvents = true
window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

let view = SelectView(frame: NSRect(origin: .zero, size: size), initial: start)
view.onDone = { r in
    let yTop = size.height - r.maxY
    let idx = screens.firstIndex(of: screen) ?? 0
    print("\(Int(r.minX)),\(Int(yTop)),\(Int(r.width)),\(Int(r.height)),\(Int(screen.backingScaleFactor)),\(idx)")
    fflush(stdout)
    exit(0)
}
window.contentView = view

// Local monitor: Esc / Return work even if the view isn't first responder.
NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
    if e.keyCode == 53 { exit(1) }
    if e.keyCode == 36 || e.keyCode == 76 { view.onDone?(view.rect); return nil }
    return e
}
// Safety net: never leave an overlay stuck on screen.
DispatchQueue.main.asyncAfter(deadline: .now() + 120) { exit(1) }

window.makeKeyAndOrderFront(nil)
window.makeFirstResponder(view)
app.activate(ignoringOtherApps: true)
app.run()
