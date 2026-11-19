import AppKit
import GamdlCore
import Observation

/// Updates Gamdl Desk from the DMG attached to the latest GitHub release: checks at launch (unless
/// turned off), and on request downloads the DMG, copies the app out of it, swaps it in for the
/// running app and relaunches.
@Observable @MainActor
final class AppUpdater {
    struct Release: Equatable {
        let version: String
        let dmgURL: URL
        let pageURL: URL
    }

    enum State: Equatable {
        case idle, checking, upToDate
        case available(Release)
        /// Downloading the DMG and preparing the new app.
        case installing(Release)
        case failed(String)
    }

    static let repository = "linux-pilot/gamdl-desk"
    static let releasesURL = URL(string: "https://github.com/\(repository)/releases")!
    static let automaticKey = "checkForUpdatesAutomatically"

    let downloads: DownloadController
    let setup: SetupController
    private(set) var state = State.idle
    /// Whether the result of the last check should show as a banner in the main window. Automatic
    /// checks only show one when there's an update; checks you ask for always do.
    var showsBanner = false

    /// The running app's version, or nil when it isn't running from an app bundle (`swift run`).
    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    init(downloads: DownloadController, setup: SetupController) {
        self.downloads = downloads
        self.setup = setup
    }

    var isBusy: Bool {
        switch state {
        case .checking, .installing: true
        default: false
        }
    }

    /// Why installing can't start now, if it can't.
    var installBlockingReason: String? {
        if downloads.isRunning { return "Wait for the download to finish." }
        if setup.isRunning { return "Wait for Setup to finish installing." }
        return nil
    }

    func checkAtLaunch() {
        UserDefaults.standard.register(defaults: [Self.automaticKey: true])
        guard UserDefaults.standard.bool(forKey: Self.automaticKey) else { return }
        check(userInitiated: false)
    }

    func check(userInitiated: Bool) {
        guard !isBusy else { return }
        guard let currentVersion else {
            state = .failed("This copy isn't running as an app, so it can't update itself.")
            showsBanner = userInitiated
            return
        }
        state = .checking
        if userInitiated { showsBanner = true }
        Task {
            do {
                let release = try await Self.latestRelease()
                if ToolVersion.isNewer(release.version, than: currentVersion) {
                    state = .available(release)
                    showsBanner = true
                } else {
                    state = .upToDate
                }
            } catch {
                state = .failed("Couldn't check for updates: \(error.localizedDescription)")
            }
        }
    }

    /// Downloads the update, swaps it in for this app, and relaunches. If the app's folder can't be
    /// written to, opens the DMG in Finder instead so you can drag the app over yourself.
    func install(_ release: Release) {
        guard installBlockingReason == nil, !isBusy else { return }
        state = .installing(release)
        showsBanner = true
        let appPath = Bundle.main.bundlePath
        Task {
            do {
                let dmg = try await Self.download(release)
                let work = try await Task.detached { try Self.prepare(dmg, release, replacing: appPath) }.value
                if let staged = work.stagedApp {
                    try Self.relaunch(replacing: appPath, with: staged, in: work.directory)
                    NSApp.terminate(nil)
                } else {
                    NSWorkspace.shared.open(work.dmg)
                    state = .failed("Gamdl Desk can't replace itself in \((appPath as NSString).deletingLastPathComponent). The new version is open in Finder: drag it to Applications.")
                }
            } catch {
                state = .failed("Couldn't install the update: \(error.localizedDescription)")
            }
        }
    }

    // MARK: GitHub

    private static func latestRelease() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("GamdlDesk", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError("GitHub answered with status \((response as? HTTPURLResponse)?.statusCode ?? 0).")
        }
        struct Payload: Decodable {
            struct Asset: Decodable { let name: String; let browser_download_url: URL }
            let tag_name: String
            let html_url: URL
            let assets: [Asset]
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard let dmg = payload.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }) else {
            throw UpdateError("The latest release (\(payload.tag_name)) has no DMG attached.")
        }
        let version = payload.tag_name.hasPrefix("v") ? String(payload.tag_name.dropFirst()) : payload.tag_name
        return Release(version: version, dmgURL: dmg.browser_download_url, pageURL: payload.html_url)
    }

    // MARK: Installing

    private struct Prepared: Sendable {
        let directory: URL
        let dmg: URL
        /// The new app, copied out of the DMG, or nil if the running app's folder isn't writable.
        let stagedApp: URL?
    }

    /// Downloads the DMG into a new temporary folder.
    private static func download(_ release: Release) async throws -> URL {
        let (downloaded, response) = try await URLSession.shared.download(from: release.dmgURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError("The download failed (status \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GamdlDeskUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dmg = directory.appendingPathComponent(release.dmgURL.lastPathComponent)
        try FileManager.default.moveItem(at: downloaded, to: dmg)
        return dmg
    }

    /// Copies the app out of the DMG, checking it's this app at the new version.
    nonisolated private static func prepare(_ dmg: URL, _ release: Release, replacing appPath: String) throws -> Prepared {
        let fm = FileManager.default
        let directory = dmg.deletingLastPathComponent()

        guard fm.isWritableFile(atPath: (appPath as NSString).deletingLastPathComponent),
              fm.isWritableFile(atPath: appPath) else {
            return Prepared(directory: directory, dmg: dmg, stagedApp: nil)
        }

        let mount = directory.appendingPathComponent("mount")
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }

        guard let appName = try fm.contentsOfDirectory(atPath: mount.path).first(where: { $0.hasSuffix(".app") }) else {
            throw UpdateError("The DMG doesn't contain an app.")
        }
        let staged = directory.appendingPathComponent(appName)
        try run("/usr/bin/ditto", [mount.appendingPathComponent(appName).path, staged.path])

        let info = Bundle(url: staged)?.infoDictionary
        guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            throw UpdateError("The DMG contains a different app.")
        }
        guard let version = info?["CFBundleShortVersionString"] as? String,
              !ToolVersion.isNewer(release.version, than: version) else {
            throw UpdateError("The app in the DMG isn't version \(release.version).")
        }
        return Prepared(directory: directory, dmg: dmg, stagedApp: staged)
    }

    /// Starts a helper that waits for this app to quit, swaps the new app in (putting the old one
    /// back if that fails), and opens it. The caller then quits.
    private static func relaunch(replacing appPath: String, with staged: URL, in directory: URL) throws {
        let script = """
            while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
            if mv "$2" "$4"; then
              if mv "$3" "$2"; then rm -rf "$4"; else mv "$4" "$2"; fi
            fi
            open "$2"
            """
        let backup = directory.appendingPathComponent("previous.app").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier), appPath, staged.path, backup]
        try process.run()
    }

    @discardableResult
    nonisolated private static func run(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError("\((path as NSString).lastPathComponent) failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return output
    }
}

struct UpdateError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
