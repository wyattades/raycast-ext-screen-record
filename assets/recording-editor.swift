import Cocoa
import AVKit

// Usage: recording-editor <recording.mp4> <ffmpeg-path>
// Preview a recording, trim its ends, split + cut pieces, pick MP4/GIF, then copy to clipboard or save to Downloads.

let args = CommandLine.arguments
guard args.count >= 3 else { exit(2) }
let sourceURL = URL(fileURLWithPath: args[1])
let ffmpegPath = args[2]
let asset = AVURLAsset(url: sourceURL)
let duration = max(CMTimeGetSeconds(asset.duration), 0.2)  // sync read is fine for a local file
let tempDir = NSTemporaryDirectory() + "screen-recorder-\(getpid())/"
try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)

func fmt(_ t: Double) -> String {
    let s = max(0, t)
    return String(format: "%d:%04.1f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
}

// MARK: - Model

final class Model {
    var trimStart = 0.0
    var trimEnd = duration
    var bounds: [Double] = [0, duration]   // segment boundaries, including both ends
    var enabled: [Bool] = [true]
    var selected = 0

    func segment(at t: Double) -> Int {
        for i in 0..<enabled.count where t >= bounds[i] && t < bounds[i + 1] { return i }
        return enabled.count - 1
    }

    /// Splitting opens a small cut gap around `t`; drag either edge to widen or narrow it.
    func split(at t: Double) {
        let i = segment(at: t)
        let a = bounds[i], b = bounds[i + 1]
        let gap = min(max(duration * 0.04, 0.3), 1.0)
        let s = min(max(t - gap / 2, a + 0.1), b - 0.1 - gap)
        let e = s + gap
        guard s >= a + 0.1, e <= b - 0.1 else { return }
        let keep = enabled[i]
        bounds.insert(contentsOf: [s, e], at: i + 1)
        enabled.insert(contentsOf: [false, keep], at: i + 1)
        selected = i + 1
    }

    func toggleSelected() { enabled[selected].toggle() }

    /// Time ranges that survive trimming and cuts, merged where contiguous.
    func keepRanges() -> [(Double, Double)] {
        var out: [(Double, Double)] = []
        for i in 0..<enabled.count where enabled[i] {
            let s = max(bounds[i], trimStart), e = min(bounds[i + 1], trimEnd)
            guard e - s > 0.02 else { continue }
            if let last = out.last, abs(last.1 - s) < 1e-6 { out[out.count - 1].1 = e } else { out.append((s, e)) }
        }
        return out
    }

    var keptDuration: Double { keepRanges().reduce(0) { $0 + $1.1 - $1.0 } }
}

// MARK: - Timeline

final class TimelineView: NSView {
    let model: Model
    var playhead = 0.0
    var onScrub: ((Double) -> Void)?
    var onChange: (() -> Void)?

    enum Drag { case none, trimStart, trimEnd, split(Int), scrub }
    var drag = Drag.none
    let pad: CGFloat = 18

    init(model: Model) {
        self.model = model
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var track: NSRect { NSRect(x: pad, y: 14, width: bounds.width - pad * 2, height: 44) }
    func x(_ t: Double) -> CGFloat { track.minX + CGFloat(t / duration) * track.width }
    func time(_ x: CGFloat) -> Double { min(max(Double((x - track.minX) / track.width), 0), 1) * duration }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.12, alpha: 1).setFill()
        bounds.fill()

        for i in 0..<model.enabled.count {
            let r = NSRect(x: x(model.bounds[i]), y: track.minY, width: x(model.bounds[i + 1]) - x(model.bounds[i]), height: track.height)
            (model.enabled[i] ? NSColor.systemBlue : NSColor(white: 0.28, alpha: 1)).setFill()
            r.fill()
            if !model.enabled[i] {
                NSColor(white: 0.5, alpha: 0.5).setStroke()
                let p = NSBezierPath()
                var sx = r.minX - r.height
                while sx < r.maxX {
                    p.move(to: NSPoint(x: max(sx, r.minX), y: sx < r.minX ? r.minY + (r.minX - sx) : r.minY))
                    p.line(to: NSPoint(x: min(sx + r.height, r.maxX), y: sx + r.height > r.maxX ? r.minY + (r.maxX - sx) : r.maxY))
                    sx += 10
                }
                p.lineWidth = 1
                p.stroke()
            }
            if i == model.selected {
                NSColor.white.setStroke()
                let b = NSBezierPath(rect: r.insetBy(dx: 1, dy: 1))
                b.lineWidth = 2
                b.stroke()
            }
        }
        // trimmed-away regions
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSRect(x: track.minX, y: track.minY, width: x(model.trimStart) - track.minX, height: track.height).fill()
        NSRect(x: x(model.trimEnd), y: track.minY, width: track.maxX - x(model.trimEnd), height: track.height).fill()

        // split lines
        NSColor.white.setFill()
        for j in 1..<(model.bounds.count - 1) {
            NSRect(x: x(model.bounds[j]) - 1, y: track.minY - 4, width: 2, height: track.height + 8).fill()
        }
        // trim handles
        NSColor.systemYellow.setFill()
        NSBezierPath(roundedRect: NSRect(x: x(model.trimStart) - 10, y: track.minY - 6, width: 10, height: track.height + 12), xRadius: 3, yRadius: 3).fill()
        NSBezierPath(roundedRect: NSRect(x: x(model.trimEnd), y: track.minY - 6, width: 10, height: track.height + 12), xRadius: 3, yRadius: 3).fill()
        // playhead
        NSColor.systemRed.setFill()
        NSRect(x: x(playhead) - 1, y: track.minY - 8, width: 2, height: track.height + 16).fill()
        let tri = NSBezierPath()
        tri.move(to: NSPoint(x: x(playhead) - 6, y: track.maxY + 8))
        tri.line(to: NSPoint(x: x(playhead) + 6, y: track.maxY + 8))
        tri.line(to: NSPoint(x: x(playhead), y: track.maxY))
        tri.fill()

        let label = "\(fmt(playhead)) / \(fmt(duration))     Kept \(fmt(model.keptDuration))" as NSString
        label.draw(at: NSPoint(x: pad, y: track.maxY + 8), withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.lightGray,
        ])
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if abs(p.x - (x(model.trimStart) - 5)) <= 9 { drag = .trimStart }
        else if abs(p.x - (x(model.trimEnd) + 5)) <= 9 { drag = .trimEnd }
        else if let j = (1..<(model.bounds.count - 1)).first(where: { abs(p.x - x(model.bounds[$0])) <= 6 }) { drag = .split(j) }
        else {
            drag = .scrub
            model.selected = model.segment(at: time(p.x))
        }
        mouseDragged(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        let t = time(convert(event.locationInWindow, from: nil).x)
        switch drag {
        case .trimStart: model.trimStart = min(t, model.trimEnd - 0.1); onScrub?(model.trimStart)
        case .trimEnd: model.trimEnd = max(t, model.trimStart + 0.1); onScrub?(model.trimEnd)
        case .split(let j): model.bounds[j] = min(max(t, model.bounds[j - 1] + 0.1), model.bounds[j + 1] - 0.1); onScrub?(model.bounds[j])
        case .scrub: onScrub?(t)
        case .none: break
        }
        onChange?()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) { drag = .none }
}

// MARK: - Window

final class EditorWindow: NSWindow {
    var onKey: ((NSEvent) -> Bool)?
    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
}

final class Controller: NSObject, NSWindowDelegate {
    let model = Model()
    let window: EditorWindow
    let player: AVPlayer
    let playerView = AVPlayerView()
    let timeline: TimelineView
    let status = NSTextField(labelWithString: "Drag the yellow handles to trim. Press S to cut a gap at the playhead (drag its edges to resize), ⌫ to cut/restore the selected piece.")
    let spinner = NSProgressIndicator()
    let formatControl = NSSegmentedControl(labels: ["MP4", "GIF"], trackingMode: .selectOne, target: nil, action: nil)
    var buttons: [NSButton] = []
    var cache: [String: URL] = [:]
    var busy = false

    override init() {
        player = AVPlayer(url: sourceURL)
        timeline = TimelineView(model: model)
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        let size = NSSize(width: 980, height: 720)
        let origin = NSPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2)
        window = EditorWindow(contentRect: NSRect(origin: origin, size: size), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Edit Recording"
        window.minSize = NSSize(width: 760, height: 520)
        window.delegate = self
        window.onKey = { [weak self] e in self?.handleKey(e) ?? false }
        build()
    }

    func button(_ title: String, _ frame: NSRect, _ mask: NSView.AutoresizingMask, _ action: Selector, primary: Bool = false) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.frame = frame
        b.autoresizingMask = mask
        b.bezelStyle = .rounded
        if primary { b.keyEquivalent = "\r" }
        window.contentView!.addSubview(b)
        buttons.append(b)
        return b
    }

    func build() {
        let c = window.contentView!
        let w = c.bounds.width

        playerView.frame = NSRect(x: 0, y: 190, width: w, height: c.bounds.height - 190)
        playerView.autoresizingMask = [.width, .height]
        playerView.player = player
        playerView.controlsStyle = .inline
        c.addSubview(playerView)

        timeline.frame = NSRect(x: 0, y: 84, width: w, height: 106)
        timeline.autoresizingMask = [.width, .maxYMargin]
        timeline.onScrub = { [weak self] t in self?.seek(t) }
        timeline.onChange = { [weak self] in self?.updateTitle() }
        c.addSubview(timeline)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.frame = NSRect(x: 18, y: 58, width: 16, height: 16)
        spinner.autoresizingMask = [.maxYMargin]
        c.addSubview(spinner)

        status.frame = NSRect(x: 40, y: 56, width: w - 58, height: 18)
        status.autoresizingMask = [.width, .maxYMargin]
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 12)
        c.addSubview(status)

        let left: NSView.AutoresizingMask = [.maxXMargin, .maxYMargin]
        let right: NSView.AutoresizingMask = [.minXMargin, .maxYMargin]
        _ = button("Cut gap at playhead (S)", NSRect(x: 16, y: 16, width: 160, height: 28), left, #selector(splitAction))
        _ = button("Cut / restore piece (⌫)", NSRect(x: 184, y: 16, width: 170, height: 28), left, #selector(cutAction))

        formatControl.frame = NSRect(x: w - 16 - 130 - 8 - 150 - 8 - 110, y: 16, width: 110, height: 28)
        formatControl.autoresizingMask = right
        formatControl.selectedSegment = UserDefaults.standard.string(forKey: "format") == "gif" ? 1 : 0
        formatControl.target = self
        formatControl.action = #selector(formatChanged)
        c.addSubview(formatControl)
        _ = button("Copy to Clipboard", NSRect(x: w - 16 - 130 - 8 - 150, y: 16, width: 150, height: 28), right, #selector(copyAction))
        _ = button("Download", NSRect(x: w - 16 - 130, y: 16, width: 130, height: 28), right, #selector(downloadAction), primary: true)

        player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.03, preferredTimescale: 600), queue: .main) { [weak self] t in
            self?.tick(CMTimeGetSeconds(t))
        }
        updateTitle()
    }

    var format: String { formatControl.selectedSegment == 1 ? "gif" : "mp4" }
    @objc func formatChanged() { UserDefaults.standard.set(format, forKey: "format") }

    func updateTitle() { window.title = "Edit Recording — keeping \(fmt(model.keptDuration))" }

    func seek(_ t: Double) {
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        timeline.playhead = t
        timeline.needsDisplay = true
    }

    /// Playback skips cut pieces and loops within the trimmed range.
    func tick(_ t: Double) {
        timeline.playhead = t
        timeline.needsDisplay = true
        guard player.rate != 0 else { return }
        let ranges = model.keepRanges()
        guard !ranges.isEmpty else { return }
        if ranges.contains(where: { t >= $0.0 - 0.02 && t < $0.1 }) { return }
        if let next = ranges.first(where: { $0.0 > t }) { seek(next.0) } else { player.pause(); seek(ranges[0].0) }
    }

    @objc func splitAction() { model.split(at: timeline.playhead); timeline.needsDisplay = true }
    @objc func cutAction() { model.toggleSelected(); timeline.needsDisplay = true; updateTitle() }

    func handleKey(_ e: NSEvent) -> Bool {
        if e.modifierFlags.contains(.command), e.charactersIgnoringModifiers == "w" { window.close(); return true }
        switch e.keyCode {
        case 53: window.close(); return true                      // esc
        case 51, 117: cutAction(); return true                    // delete
        case 49: player.rate == 0 ? player.play() : player.pause(); return true  // space
        default:
            if e.charactersIgnoringModifiers?.lowercased() == "s" { splitAction(); return true }
            return false
        }
    }

    // MARK: Export

    func setBusy(_ b: Bool, _ message: String) {
        busy = b
        buttons.forEach { $0.isEnabled = !b }
        formatControl.isEnabled = !b
        status.stringValue = message
        b ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
    }

    func filterGraph(ranges: [(Double, Double)], format: String) -> String {
        var parts = ranges.enumerated().map { i, r in
            "[0:v]trim=start=\(r.0):end=\(r.1),setpts=PTS-STARTPTS[v\(i)]"
        }
        let labels = ranges.indices.map { "[v\($0)]" }.joined()
        parts.append("\(labels)concat=n=\(ranges.count):v=1:a=0[cat]")
        if format == "gif" {
            parts.append("[cat]fps=15,scale='min(960,iw)':-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5[out]")
        } else {
            parts.append("[cat]pad=ceil(iw/2)*2:ceil(ih/2)*2[out]")
        }
        return parts.joined(separator: ";")
    }

    func export(then done: @escaping (URL) -> Void) {
        let ranges = model.keepRanges()
        guard !ranges.isEmpty else { setBusy(false, "Nothing left to export — restore a piece first."); return }
        let fmt = format
        let key = "\(fmt)|\(ranges.map { "\($0.0)-\($0.1)" }.joined(separator: ","))"
        if let url = cache[key], FileManager.default.fileExists(atPath: url.path) { done(url); return }

        setBusy(true, "Encoding \(fmt.uppercased())…")
        let out = URL(fileURLWithPath: tempDir + "out-\(cache.count).\(fmt)")
        var ffargs = ["-hide_banner", "-loglevel", "error", "-y", "-i", sourceURL.path,
                      "-filter_complex", filterGraph(ranges: ranges, format: fmt), "-map", "[out]"]
        if fmt == "mp4" { ffargs += ["-c:v", "libx264", "-crf", "20", "-pix_fmt", "yuv420p", "-movflags", "+faststart"] }
        ffargs.append(out.path)

        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ffmpegPath)
            p.arguments = ffargs
            let pipe = Pipe()
            p.standardError = pipe
            try? p.run()
            let err = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            p.waitUntilExit()
            DispatchQueue.main.async {
                if p.terminationStatus == 0 {
                    self.cache[key] = out
                    done(out)
                } else {
                    self.setBusy(false, "Encoding failed: \(err.suffix(200))")
                }
            }
        }
    }

    @objc func copyAction() {
        export { url in
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([url as NSURL])
            self.setBusy(false, "Copied \(url.pathExtension.uppercased()) to clipboard.")
        }
    }

    @objc func downloadAction() {
        export { url in
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            let dest = dir.appendingPathComponent("Screen Recording \(df.string(from: Date())).\(url.pathExtension)")
            do {
                try FileManager.default.copyItem(at: url, to: dest)
                self.setBusy(false, "Saved to Downloads: \(dest.lastPathComponent)")
            } catch {
                self.setBusy(false, "Save failed: \(error.localizedDescription)")
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        try? FileManager.default.removeItem(at: sourceURL)
        try? FileManager.default.removeItem(atPath: tempDir)
        exit(0)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let mainMenu = NSMenu()
let appItem = NSMenuItem()
mainMenu.addItem(appItem)
let appMenu = NSMenu()
appMenu.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
appMenu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
appItem.submenu = appMenu
app.mainMenu = mainMenu

let controller = Controller()
controller.window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)

app.run()
