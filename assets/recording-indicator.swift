import Cocoa

// Usage: recording-indicator <ffmpegPid> <url-to-open-on-click>
// Shows a flashing red "STOP" item in the menu bar while the recorder process is alive.
// Clicking it opens the URL (the Raycast deeplink that stops + encodes the recording).

let args = CommandLine.arguments
guard args.count >= 3, let pid = Int32(args[1]), let url = URL(string: args[2]) else { exit(2) }
let _ = (pid, url)

final class Controller: NSObject {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var on = true
    let pid: Int32
    let url: URL

    init(pid: Int32, url: URL) {
        self.pid = pid
        self.url = url
        super.init()
        guard let b = item.button else { return }
        b.wantsLayer = true
        b.layer?.cornerRadius = 5
        b.attributedTitle = NSAttributedString(string: " ⏹ STOP REC ", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .heavy),
            .foregroundColor: NSColor.white,
        ])
        b.target = self
        b.action = #selector(clicked)
        render()
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            self.on.toggle()
            self.render()
        }
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            if kill(pid, 0) != 0 { exit(0) }  // recording ended
        }
    }

    func render() {
        item.button?.layer?.backgroundColor = (on ? NSColor.systemRed : NSColor(red: 0.45, green: 0, blue: 0.05, alpha: 1)).cgColor
    }

    @objc func clicked() { NSWorkspace.shared.open(url) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller(pid: pid, url: url)
app.run()
