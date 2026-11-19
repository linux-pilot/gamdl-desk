#if DEBUG
import AppKit

/// UI test hook, compiled into debug builds only. Launch with GAMDL_DESK_DRIVER=/path/commands.txt,
/// write commands to that file, then `kill -USR1 <pid>`. One command per line:
///   size <w> <h> | input <text, \n for newlines> | lines <fake gamdl output, \n separated>
///   download | stop | signin | refresh | tab activity|log
///   options on|off | prefs <DownloadOptions JSON> | scroll <y> | dark | light | snap <png path>
/// Snapshots are taken by the app itself, so they need no screen-recording permission.
@MainActor
enum DebugDriver {
    static let inputNotification = Notification.Name("DebugDriver.input")
    static let downloadNotification = Notification.Name("DebugDriver.download")
    private static var source: DispatchSourceSignal?

    static func install(controller: DownloadController) {
        guard source == nil, let path = ProcessInfo.processInfo.environment["GAMDL_DESK_DRIVER"] else { return }
        signal(SIGUSR1, SIG_IGN)
        let s = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        s.setEventHandler {
            MainActor.assumeIsolated {
                let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
                run(text.split(separator: "\n").map(String.init), controller: controller)
            }
        }
        s.resume()
        source = s
    }

    private static func run(_ commands: [String], controller: DownloadController) {
        guard let command = commands.first else { return }
        let rest = Array(commands.dropFirst())
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        let window = NSApp.windows.first { $0.isVisible && $0.contentView != nil }
        var delay = 0.4
        switch parts.first ?? "" {
        case "size":
            let n = arg.split(separator: " ").compactMap { Double($0) }
            if n.count == 2 { window?.setContentSize(NSSize(width: n[0], height: n[1])) }
        case "input":
            NotificationCenter.default.post(name: inputNotification, object: arg.replacingOccurrences(of: "\\n", with: "\n"))
        case "download": NotificationCenter.default.post(name: downloadNotification, object: nil)
        case "stop": controller.stop()
        case "signin": controller.signInInTerminal() // runs GAMDL_DESK_AUTH_COMMAND instead of Terminal
        case "refresh": controller.refreshAuthStatus()
        case "prefs": UserDefaults.standard.set(arg, forKey: "downloadOptions") // DownloadOptions JSON
        case "lines": controller.debugInject(arg.components(separatedBy: "\\n"))
        case "tab": UserDefaults.standard.set(arg == "log" ? "Log" : "Activity", forKey: "resultsTab")
        case "options": UserDefaults.standard.set(arg == "on", forKey: "showOptions")
        case "scroll": // scroll the rightmost scroll view (the Options inspector) to y points from the top
            if let root = window?.contentView {
                func all(_ v: NSView) -> [NSScrollView] { (v as? NSScrollView).map { [$0] } ?? [] + v.subviews.flatMap(all) }
                if let sv = all(root).max(by: { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }) {
                    sv.contentView.scroll(to: NSPoint(x: 0, y: Double(arg) ?? 0))
                    sv.reflectScrolledClipView(sv.contentView)
                }
            }
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "wait": delay = Double(arg) ?? 1
        case "snap":
            if let frame = window?.contentView?.superview {
                frame.layoutSubtreeIfNeeded()
                if let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
                    frame.cacheDisplay(in: frame.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arg))
                }
            }
            delay = 0.1
        default: break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated { run(rest, controller: controller) }
        }
    }
}
#endif
