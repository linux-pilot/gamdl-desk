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
    static let signInDirPrefix = "gamdl-desk-auth-"

    /// gamdl's saved sign-in; nil until it has been read (or if it couldn't be).
    private(set) var savedAuth: SavedAuth?
    private(set) var checkingAuth = false
    private(set) var signInFlow: SignInFlow = .idle
    let log = LogStore()

    /// Progress of a "Sign In with Terminal…" attempt.
    enum SignInFlow: Equatable {
        case idle
        case waiting
        case succeeded(mode: String)
        case failed(String)
    }

    @ObservationIgnored private var runner: CommandRunner?
    @ObservationIgnored private var finishWaiters: [() -> Void] = []
    @ObservationIgnored private var authCheckWaiters: [() -> Void] = []
    @ObservationIgnored private var signInWatch: Task<Void, Never>?

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

    init() {
        Self.removeStaleSignInFolders()
        locateGamdl()
    }

    /// Sign-in scripts left behind if the app quit while one was open.
    private static func removeStaleSignInFolders() {
        let tmp = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        for name in names where name.hasPrefix(signInDirPrefix) {
            try? FileManager.default.removeItem(at: tmp.appendingPathComponent(name))
        }
    }

    /// Looks for gamdl (the app doesn't get the login shell's PATH), reads its version and sign-in.
    func locateGamdl() {
        gamdlPath = Self.searchPaths.map { "\($0)/gamdl" }.first { FileManager.default.isExecutableFile(atPath: $0) }
        gamdlVersion = nil
        savedAuth = nil
        guard gamdlPath != nil else { return }
        capture(["--version"]) { [weak self] output, _ in
            let version = output.lazy.compactMap { $0.firstMatch(of: /\d+\.\d+(\.\d+)?/) }.first
            self?.gamdlVersion = version.map { String($0.output.0) }
        }
        refreshAuthStatus()
    }

    /// Re-reads gamdl's saved sign-in. Called at launch, when the app becomes active (you may have
    /// run `gamdl auth` yourself) and after a Terminal sign-in. Concurrent calls share one check.
    func refreshAuthStatus(then done: (() -> Void)? = nil) {
        if let done { authCheckWaiters.append(done) }
        guard !checkingAuth else { return }
        checkingAuth = true
        let started = capture(["config", "show"]) { [weak self] output, termination in
            guard let self else { return }
            let parsed = termination.succeeded ? SavedAuth.parse(configShow: output.joined(separator: "\n")) : nil
            let previous = self.savedAuth
            // Keep the last known state if gamdl couldn't be read this time.
            if parsed != nil || self.savedAuth == nil { self.savedAuth = parsed }
            // Signed in outside the app (e.g. `gamdl auth` in your own terminal) after a sign-in error.
            if self.needsSignIn, self.signInFlow == .idle, previous != nil, previous != parsed,
               case .mode(let mode)? = parsed {
                self.needsSignIn = false
                self.signInFlow = .succeeded(mode: mode)
            }
            self.finishAuthCheck()
        }
        if !started { finishAuthCheck() }
    }

    private func finishAuthCheck() {
        checkingAuth = false
        let waiters = authCheckWaiters
        authCheckWaiters = []
        waiters.forEach { $0() }
    }

    /// Runs gamdl with `arguments` and hands its output to `completion` on the main actor.
    /// Returns false if gamdl couldn't be started (completion is then never called).
    @discardableResult
    private func capture(_ arguments: [String],
                         completion: @escaping @MainActor ([String], CommandRunner.Termination) -> Void) -> Bool {
        guard let gamdlPath else { return false }
        var output: [String] = []
        let r = CommandRunner(executable: URL(fileURLWithPath: gamdlPath), arguments: arguments,
                              environment: Self.environment) { event in
            MainActor.assumeIsolated {
                switch event {
                case .lines(let l): output += l.map(TerminalText.strip)
                case .finished(let t): completion(output, t)
                }
            }
        }
        do { try r.start(); return true } catch { return false }
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
        if signInFlow != .waiting { signInFlow = .idle }
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

    /// `gamdl auth` asks questions, so it has to run in a real terminal. The script writes gamdl's exit
    /// code to a status file (130 if the window is closed or interrupted); the app watches for it and
    /// then re-reads the saved sign-in, so it can confirm or report the result.
    func signInInTerminal() {
        guard let gamdlPath, signInFlow != .waiting else { return }
        #if DEBUG
        // Tests replace `gamdl auth` and run the script without Terminal (see DebugDriver).
        let testCommand = ProcessInfo.processInfo.environment["GAMDL_DESK_AUTH_COMMAND"]
        #else
        let testCommand: String? = nil
        #endif
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(Self.signInDirPrefix + UUID().uuidString)
        let script = dir.appendingPathComponent("Sign in to Apple Music.command")
        let status = dir.appendingPathComponent("status")
        let body = """
        #!/bin/zsh
        STATUS=\(Self.shellQuoted(status.path))
        # Report how the script ended on every path: normal exit, error, Ctrl-C or closing the window.
        trap 'exit 130' INT HUP TERM
        trap 'echo $? > "$STATUS.tmp" && mv "$STATUS.tmp" "$STATUS"' EXIT
        clear
        echo "Signing in to Apple Music for gamdl. Answer the questions below."
        echo
        \(testCommand ?? Self.shellQuoted(gamdlPath) + " auth")
        code=$?
        echo
        if [ $code -eq 0 ]; then
          echo "Signed in. You can close this window and return to Gamdl Desk."
        else
          echo "Sign-in didn't complete (exit code $code). Return to Gamdl Desk to try again."
        fi
        rm -f "$0"
        exit $code

        """
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        } catch {
            signInFlow = .failed("Couldn't prepare the sign-in script: \(error.localizedDescription)")
            return
        }
        signInFlow = .waiting
        watchSignIn(statusFile: status, directory: dir)
        if testCommand != nil {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = [script.path]
            p.standardOutput = FileHandle.nullDevice
            try? p.run()
            return
        }
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in
                self?.stopWatchingSignIn()
                self?.signInFlow = .failed("Couldn't open Terminal: \(error.localizedDescription). Run `gamdl auth` in Terminal instead.")
            }
        }
    }

    func cancelSignInWait() {
        stopWatchingSignIn()
        signInFlow = .idle
        refreshAuthStatus()
    }

    func dismissSignInResult() {
        if signInFlow != .waiting { signInFlow = .idle }
    }

    private func watchSignIn(statusFile: URL, directory: URL) {
        signInWatch?.cancel()
        signInWatch = Task { [weak self] in
            // Give up after 30 minutes; activating the app still re-checks the saved sign-in.
            for _ in 0..<1800 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                guard let text = try? String(contentsOf: statusFile, encoding: .utf8),
                      let code = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { continue }
                try? FileManager.default.removeItem(at: directory)
                self?.signInFinished(exitCode: code)
                return
            }
            try? FileManager.default.removeItem(at: directory)
            self?.signInFlow = .idle
        }
    }

    private func stopWatchingSignIn() {
        signInWatch?.cancel()
        signInWatch = nil
    }

    private func signInFinished(exitCode: Int32) {
        signInWatch = nil
        refreshAuthStatus { [weak self] in
            guard let self, self.signInFlow == .waiting else { return }
            if exitCode == 0, case .mode(let mode) = self.savedAuth {
                self.signInFlow = .succeeded(mode: mode)
                self.needsSignIn = false
            } else if exitCode == 130 {
                self.signInFlow = .failed("Sign-in was cancelled before it finished.")
            } else {
                self.signInFlow = .failed("gamdl couldn't sign in (exit code \(exitCode)). Check the Terminal window for details.")
            }
        }
    }

    static func shellQuoted(_ s: String) -> String {
        if !s.isEmpty, s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./:=@%+,".contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
