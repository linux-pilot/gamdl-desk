import AppKit
import SwiftUI

@main
struct GamdlDeskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var controller = DownloadController()

    var body: some Scene {
        // A single window: one gamdl process at a time, and quitting can stop it cleanly.
        Window("Gamdl Desk", id: "main") {
            ContentView(controller: controller)
                .onAppear {
                    appDelegate.controller = controller
                    #if DEBUG
                    DebugDriver.install(controller: controller)
                    #endif
                }
        }
        .defaultSize(width: 980, height: 680)
        .windowResizability(.contentMinSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: DownloadController?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidBecomeActive(_ notification: Notification) {
        NSApp.dockTile.badgeLabel = nil
        // You may have signed in (or out) with gamdl elsewhere, e.g. in Terminal.
        controller?.refreshAuthStatus()
    }

    /// Don't leave gamdl running in the background after the app quits.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller, controller.isRunning else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "A download is in progress"
        alert.informativeText = "Quitting stops it. Files that are already finished are kept."
        alert.addButton(withTitle: "Stop and Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        controller.stopAndWait { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
