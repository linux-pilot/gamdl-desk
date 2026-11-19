import AppKit
import GamdlCore
import Observation

/// One finished item shown in the Activity list.
struct ActivityItem: Identifiable {
    let id: Int
    let event: OutputEvent
}

/// Log lines, kept separate from the controller so only the log view redraws when output arrives.
@Observable @MainActor
final class LogStore {
    static let maxLines = 20_000
    private(set) var lines: [String] = []
    /// Lines ever appended in this generation; lets the view append only what's new.
    private(set) var total = 0
    /// Bumped on clear, so the view knows to start over.
    private(set) var generation = 0

    func append(_ new: [String]) {
        guard !new.isEmpty else { return }
        lines += new
        total += new.count
        if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines * 3 / 4) }
    }

    func clear() {
        lines = []
        total = 0
        generation += 1
    }

    var text: String { lines.joined(separator: "\n") }
}

/// Owns the gamdl process for the window: starts and stops it, and turns its output into state.
@Observable @MainActor
final class DownloadController {
    enum Phase: Equatable {
        case idle
        case running(since: Date)
        case stopping(since: Date)
        case finished(CommandRunner.Termination, duration: TimeInterval)
        case failedToStart(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var items: [ActivityItem] = []
    private(set) var needsSignIn = false
    private(set) var gamdlPath: String?
    private(set) var gamdlVersion: String?
    let log = LogStore()

    @ObservationIgnored private var runner: CommandRunner?
    @ObservationIgnored private var finishWaiters: [() -> Void] = []

    static let searchPaths = [
        "\(NSHomeDirectory())/.local/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]
    static let installCommand = #"uv tool install "gamdl[widevine]""#

    var isRunning: Bool {
        switch phase { case .running, .stopping: true; default: false }
    }

    var savedCount: Int { items.count(where: { $0.event.kind == .saved || $0.event.kind == .partial }) }
    var skippedCount: Int { items.count(where: { $0.event.kind == .skipped }) }
    var failedCount: Int { items.count(where: { $0.event.kind == .failed }) }

    init() { locateGamdl() }

    /// Looks for gamdl (the app doesn't get the login shell's PATH) and reads its version.
    func locateGamdl() {
        gamdlPath = Self.searchPaths.map { "\($0)/gamdl" }.first { FileManager.default.isExecutableFile(atPath: $0) }
        gamdlVersion = nil
        guard let gamdlPath else { return }
        var output: [String] = []
        let r = CommandRunner(executable: URL(fileURLWithPath: gamdlPath), arguments: ["--version"],
                              environment: Self.environment) { [weak self] event in
            MainActor.assumeIsolated {
                switch event {
                case .lines(let l): output += l
                case .finished:
                    let version = output.lazy.compactMap { $0.firstMatch(of: /\d+\.\d+(\.\d+)?/) }.first
                    self?.gamdlVersion = version.map { String($0.output.0) }
                }
            }
        }
        try? r.start()
    }

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (searchPaths + [env["PATH"] ?? ""]).filter { !$0.isEmpty }.joined(separator: ":")
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONIOENCODING"] = "utf-8"
        // Rich wraps at 80 columns without a terminal, which splits lines (and file paths) in two.
        env["COLUMNS"] = "4096"
        return env
    }

    func start(options: DownloadOptions, inputs: [String]) {
        guard !isRunning, !inputs.isEmpty else { return }
        if gamdlPath == nil { locateGamdl() }
        guard let gamdlPath else {
            phase = .failedToStart("gamdl isn't installed.")
            log.append(["gamdl not found. Install it in Terminal with:", "  \(Self.installCommand)", ""])
            return
        }
        do {
            try FileManager.default.createDirectory(atPath: options.expandedOutputDir, withIntermediateDirectories: true)
        } catch {
            phase = .failedToStart("Can't create the output folder.")
            log.append(["Can't create \(options.expandedOutputDir): \(error.localizedDescription)", ""])
            return
        }

        let arguments = options.arguments(inputs: inputs)
        items = []
        needsSignIn = false
        if !log.lines.isEmpty { log.append([""]) }
        log.append(["$ gamdl " + arguments.map(Self.shellQuoted).joined(separator: " ")])

        let r = CommandRunner(executable: URL(fileURLWithPath: gamdlPath), arguments: arguments,
                              environment: Self.environment) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        do {
            try r.start()
            runner = r
            phase = .running(since: .now)
        } catch {
            phase = .failedToStart("Couldn't start gamdl.")
            log.append(["Failed to start gamdl: \(error.localizedDescription)"])
        }
    }

    func stop() {
        guard case .running(let since) = phase else { return }
        phase = .stopping(since: since)
        runner?.stop()
    }

    /// Stops any download and calls `done` once gamdl has exited (immediately if idle).
    func stopAndWait(_ done: @escaping () -> Void) {
        guard isRunning else { return done() }
        finishWaiters.append(done)
        stop()
    }

    func clear() {
        guard !isRunning else { return }
        log.clear()
        items = []
        needsSignIn = false
        phase = .idle
    }

    #if DEBUG
    /// Feeds lines as if gamdl printed them (DebugDriver), to exercise the UI without an account.
    func debugInject(_ lines: [String]) { handle(.lines(lines)) }
    #endif

    private func handle(_ event: CommandRunner.Event) {
        switch event {
        case .lines(let raw):
            let lines = raw.map(TerminalText.strip)
            log.append(lines)
            // Build the batch first: mutating an observed array once per line copies it each time.
            var newItems: [ActivityItem] = []
            for line in lines {
                if !needsSignIn, OutputEvent.indicatesSignInProblem(line) { needsSignIn = true }
                if let e = OutputEvent.parse(line) { newItems.append(ActivityItem(id: items.count + newItems.count, event: e)) }
            }
            if !newItems.isEmpty { items += newItems }
        case .finished(let t):
            let since: Date? = switch phase {
            case .running(let s), .stopping(let s): s
            default: nil
            }
            let duration = since.map { Date.now.timeIntervalSince($0) } ?? 0
            phase = .finished(t, duration: duration)
            runner = nil
            let summary = t.stoppedByUser ? "stopped" : t.signaled ? "killed by signal \(t.status)" : "exit code \(t.status)"
            log.append(["— finished (\(summary)) —"])
            if !NSApp.isActive {
                NSApp.dockTile.badgeLabel = failedCount > 0 || !t.succeeded ? "!" : "✓"
                NSApp.requestUserAttention(.informationalRequest)
            }
            let waiters = finishWaiters
            finishWaiters = []
            waiters.forEach { $0() }
        }
    }

    /// `gamdl auth` asks questions, so it has to run in a real terminal.
    func signInInTerminal() {
        guard let gamdlPath else { return }
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("gamdl-auth.command")
        let body = """
        #!/bin/zsh
        clear
        echo "Signing in to Apple Music for gamdl. Answer the questions below."
        echo
        \(Self.shellQuoted(gamdlPath)) auth
        echo
        echo "Done. You can close this window and return to Gamdl Desk."
        rm -f \(Self.shellQuoted(script.path))

        """
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        } catch {
            log.append(["Couldn't open Terminal: \(error.localizedDescription)", "Run this in Terminal instead:  gamdl auth"])
        }
    }

    static func shellQuoted(_ s: String) -> String {
        if !s.isEmpty, s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./:=@%+,".contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
