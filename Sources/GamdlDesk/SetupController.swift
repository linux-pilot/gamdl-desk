import AppKit
import GamdlCore
import Observation

/// Installs what gamdl needs: uv (which also downloads a suitable Python), then gamdl itself.
/// Sign-in stays with `DownloadController`, which owns gamdl's location, version and saved sign-in.
@Observable @MainActor
final class SetupController {
    enum Install: Equatable {
        case uv, gamdl

        var name: String { self == .uv ? "uv" : "gamdl" }

        /// The command as shown to you before it runs.
        var command: String { self == .uv ? Gamdl.uvInstallCommand : Gamdl.installCommand }
    }

    let downloads: DownloadController
    let log = LogStore()
    /// Whether the Setup sheet is showing. It opens by itself when gamdl isn't installed.
    var isPresented: Bool
    private(set) var uvPath: String?
    private(set) var uvVersion: String?
    private(set) var installing: Install?
    /// Why the last install didn't work, if it didn't.
    private(set) var failure: String?
    @ObservationIgnored private var runner: CommandRunner?
    @ObservationIgnored private var finishWaiters: [() -> Void] = []

    var isRunning: Bool { installing != nil }

    init(downloads: DownloadController) {
        self.downloads = downloads
        isPresented = downloads.gamdlPath == nil
        locateUV()
    }

    /// Looks for uv and gamdl again, e.g. after installing them yourself in Terminal.
    func checkAgain() {
        locateUV()
        downloads.locateGamdl()
    }

    private func locateUV() {
        uvPath = Gamdl.locate("uv")
        uvVersion = nil
        guard let uvPath else { return }
        Task {
            let output = await Gamdl.output(uvPath, ["--version"])
            guard self.uvPath == uvPath else { return }
            uvVersion = output.flatMap { ToolVersion.find(in: $0.lines) }
        }
    }

    /// Why `install` can't run now, if it can't.
    func blockingReason(for install: Install) -> String? {
        if isRunning { return "Wait for the current installation to finish." }
        // Replacing gamdl while it runs would break the download.
        if downloads.isRunning { return "Wait for the download to finish." }
        if install == .gamdl && uvPath == nil { return "Install uv first." }
        return nil
    }

    func install(_ install: Install) {
        guard blockingReason(for: install) == nil else { return }
        let executable: String, arguments: [String]
        switch install {
        case .uv: (executable, arguments) = ("/bin/sh", ["-c", Gamdl.uvInstallCommand])
        case .gamdl: (executable, arguments) = (uvPath!, Gamdl.installArguments)
        }
        failure = nil
        log.append(["$ \(install.command)"])
        do {
            runner = try Gamdl.start(executable, arguments,
                                     onLines: { [log] in log.append($0) },
                                     onFinish: { [weak self] in self?.finished(install, $0) })
            installing = install
        } catch {
            failure = "Couldn't start the installation: \(error.localizedDescription)"
            log.append([failure!, ""])
        }
    }

    func stop() { runner?.stop() }

    /// Stops the installation and calls `done` once it has exited (right away if nothing is running).
    func stopAndWait(_ done: @escaping () -> Void) {
        guard let runner else { return done() }
        finishWaiters.append(done)
        runner.stop()
    }

    private func finished(_ install: Install, _ t: CommandRunner.Termination) {
        runner = nil
        installing = nil
        checkAgain()
        let found = (install == .uv ? uvPath : downloads.gamdlPath) != nil
        if t.stoppedByUser {
            failure = "The \(install.name) installation was stopped."
        } else if !t.succeeded {
            failure = "Installing \(install.name) failed (exit code \(t.status)). The details are below."
        } else if !found {
            failure = "\(install.name) was installed, but not in a folder Gamdl Desk looks in: "
                + Gamdl.searchPaths.prefix(3).map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", ") + "."
        }
        log.append([failure ?? "Installed \(install.name).", ""])
        let waiters = finishWaiters
        finishWaiters = []
        waiters.forEach { $0() }
    }
}
