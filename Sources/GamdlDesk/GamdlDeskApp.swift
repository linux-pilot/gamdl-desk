import AppKit
import SwiftUI

@main
struct GamdlDeskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // A single window: one gamdl process at a time, and quitting can stop it cleanly.
        Window("Gamdl Desk", id: "main") {
            ContentView(controller: appDelegate.controller, setup: appDelegate.setup)
        }
        .commands {
            CommandGroup(after: .appSettings) {
                Button("Setup…") { appDelegate.setup.isPresented = true }
            }
        }
        .defaultSize(width: 980, height: 680)
        .windowResizability(.contentMinSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller: DownloadController
    let setup: SetupController

    override init() {
        controller = DownloadController()
        setup = SetupController(downloads: controller)
        super.init()
    }

    #if DEBUG
    func applicationDidFinishLaunching(_ notification: Notification) {
        DebugDriver.install(controller: controller, setup: setup)
    }
    #endif

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidBecomeActive(_ notification: Notification) {
        controller.appBecameActive()
    }

    /// Don't leave gamdl (or an installation) running in the background after the app quits.
    /// Downloads and installations never run at the same time.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let alert = NSAlert()
        let stopAndWait: (@escaping () -> Void) -> Void
        if controller.isRunning {
            alert.messageText = "A download is in progress"
            alert.informativeText = "Quitting stops it. Files that are already finished are kept."
            stopAndWait = controller.stopAndWait
        } else if setup.isRunning {
            alert.messageText = "An installation is in progress"
            alert.informativeText = "Quitting stops it. You can install again from Setup next time."
            stopAndWait = setup.stopAndWait
        } else {
            return .terminateNow
        }
        alert.addButton(withTitle: "Stop and Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        stopAndWait { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
