import AppKit
import GamdlCore
import Observation

struct ActivityItem: Identifiable {
    let id: Int
    let event: OutputEvent
}

/// Log lines, kept separate from the controller so only the log view redraws when output arrives.
@Observable @MainActor
final class LogStore {
    static let maxLines = 20_000
    private(set) var lines: [String] = []
    /// Lines appended since the last clear; the view appends the ones it hasn't shown yet.
    private(set) var total = 0
    /// Changes whenever lines are removed (clearing, or trimming to `maxLines`), so the view starts over.
    private(set) var generation = 0

    func append(_ new: [String]) {
        guard !new.isEmpty else { return }
        lines += new
        total += new.count
        if lines.count > Self.maxLines {
            lines.removeFirst(lines.count - Self.maxLines * 3 / 4)
            generation += 1
        }
    }

    func clear() {
        lines = []
        total = 0
        generation += 1
    }

    var text: String { lines.joined(separator: "\n") }
}

@Observable @MainActor
final class DownloadController {
    enum Phase: Equatable {
        case idle
        case running(since: Date)
        case stopping(since: Date)
        case finished(CommandRunner.Termination, duration: TimeInterval)
        case failedToStart(String)

        var startedAt: Date? {
            switch self {
            case .running(let since), .stopping(let since): since
            default: nil
            }
        }

        var isStopping: Bool {
            if case .stopping = self { true } else { false }
        }
    }

    /// Progress of a "Sign In with Terminal…" attempt.
    enum SignInFlow: Equatable {
        case idle
        case waiting
        case succeeded(mode: String)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var items: [ActivityItem] = []
    private(set) var issues: Set<RunIssue> = []
    private var dismissedIssues: Set<RunIssue> = []
    private(set) var gamdlPath: String?
    private(set) var gamdlVersion: String?
    /// gamdl's saved sign-in; nil until it has been read (or if it couldn't be).
    private(set) var savedAuth: SavedAuth?
    private(set) var signInFlow: SignInFlow = .idle
    private var authCheck: Task<Void, Never>?
    @ObservationIgnored private var authChecksRequested = 0
    @ObservationIgnored private var authCheckStarted = true
    let log = LogStore()

    @ObservationIgnored private var runner: CommandRunner?
    @ObservationIgnored private var runCodec = SongCodec.aac
    @ObservationIgnored private var finishWaiters: [() -> Void] = []
    @ObservationIgnored private var signInTask: Task<Void, Never>?

    var isRunning: Bool { phase.startedAt != nil }
    var checkingAuth: Bool { authCheck != nil }

    var savedCount: Int { items.count(where: { $0.event.kind == .saved || $0.event.kind == .partial }) }
    var skippedCount: Int { items.count(where: { $0.event.kind == .skipped }) }
    var failedCount: Int { items.count(where: { $0.event.kind == .failed }) }

    func showsBanner(for issue: RunIssue) -> Bool { issues.contains(issue) && !dismissedIssues.contains(issue) }
    func dismiss(_ issue: RunIssue) { dismissedIssues.insert(issue) }

    init() {
        TerminalSignIn.removeLeftovers()
        locateGamdl()
    }

    func locateGamdl() {
        gamdlPath = Gamdl.locate()
        gamdlVersion = nil
        savedAuth = nil
        guard let gamdlPath else { return }
        Task {
            let output = await Gamdl.output(gamdlPath, ["--version"])
            guard self.gamdlPath == gamdlPath else { return }
            let version = output?.lines.lazy.compactMap { $0.firstMatch(of: /\d+\.\d+(\.\d+)?/) }.first
            gamdlVersion = version.map { String($0.output.0) }
        }
        refreshAuthStatus()
    }

    /// Re-reads gamdl's saved sign-in. The returned task reflects gamdl's state after this call: it
    /// waits for a check already reading (which may predate the change), and calls made before it
    /// starts share it.
    @discardableResult
    func refreshAuthStatus() -> Task<Void, Never> {
        if let authCheck, !authCheckStarted { return authCheck }
        let previous = authCheck
        authChecksRequested += 1
        let request = authChecksRequested
        authCheckStarted = false
        let check = Task {
            await previous?.value
            authCheckStarted = true
            await readSavedAuth()
            if request == authChecksRequested { authCheck = nil }
        }
        authCheck = check
        return check
    }

    /// The app came to the front: you may have signed in (or out) with gamdl elsewhere.
    func appBecameActive() {
        NSApp.dockTile.badgeLabel = nil
        refreshAuthStatus()
    }

    private func readSavedAuth() async {
        guard let gamdlPath else { return }
        let output = await Gamdl.output(gamdlPath, ["config", "show"])
        let parsed = output.flatMap {
            $0.termination.succeeded ? SavedAuth.parse(configShow: $0.lines.joined(separator: "\n")) : nil
        }
        let previous = savedAuth
        // Keep the last known state if gamdl couldn't be read this time.
        if let parsed { savedAuth = parsed }
        // Signed in outside the app (e.g. `gamdl auth` in your own terminal) after a sign-in error.
        if issues.contains(.signInRejected), signInFlow == .idle, previous != nil, previous != parsed,
           case .mode(let mode)? = parsed {
            signedIn(mode: mode)
        }
    }

    private func signedIn(mode: String) {
        issues.remove(.signInRejected)
        signInFlow = .succeeded(mode: mode)
    }

    func start(options: DownloadOptions, inputs: [String]) {
        guard !isRunning, !inputs.isEmpty else { return }
        if gamdlPath == nil { locateGamdl() }
        guard let gamdlPath else {
            phase = .failedToStart("gamdl isn't installed.")
            log.append(["gamdl not found. Install it in Terminal with:", "  \(Gamdl.installCommand)", ""])
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
        resetRun()
        runCodec = options.songCodec
        if signInFlow != .waiting { signInFlow = .idle }
        if !log.lines.isEmpty { log.append([""]) }
        log.append(["$ gamdl " + arguments.map(Shell.quoted).joined(separator: " ")])

        do {
            runner = try Gamdl.start(gamdlPath, arguments,
                                     onLines: { [weak self] in self?.received($0) },
                                     onFinish: { [weak self] in self?.finished($0) })
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
        resetRun()
        phase = .idle
    }

    private func resetRun() {
        items = []
        issues = []
        dismissedIssues = []
    }

    #if DEBUG
    /// Feeds lines as if gamdl printed them (DebugDriver), to exercise the UI without an account.
    func debugInject(_ lines: [String]) { received(lines.map(TerminalText.strip)) }
    #endif

    private func received(_ lines: [String]) {
        log.append(lines)
        // Build the batch first: mutating an observed array once per line copies it each time.
        var newItems: [ActivityItem] = []
        for line in lines {
            if let issue = RunIssue.detect(in: line, songCodec: runCodec), !issues.contains(issue) { issues.insert(issue) }
            if let e = OutputEvent.parse(line) { newItems.append(ActivityItem(id: items.count + newItems.count, event: e)) }
        }
        if !newItems.isEmpty { items += newItems }
    }

    private func finished(_ t: CommandRunner.Termination) {
        let duration = phase.startedAt.map { Date.now.timeIntervalSince($0) } ?? 0
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

    /// Signs in with `gamdl auth` in Terminal (or `signIn`, for UI tests), then re-reads the saved
    /// sign-in to confirm or report the result.
    func signInInTerminal(using signIn: TerminalSignIn? = nil) {
        guard let gamdlPath, signInFlow != .waiting else { return }
        let signIn = signIn ?? .terminal(gamdl: gamdlPath)
        signInFlow = .waiting
        signInTask = Task {
            let outcome = await signIn.run()
            guard !Task.isCancelled, signInFlow == .waiting else { return }
            switch outcome {
            case .failed(let reason):
                signInFlow = .failed(reason)
            case .noResult:
                signInFlow = .idle
            case .cancelled:
                signInFlow = .failed("Sign-in was cancelled before it finished.")
            case .finished(let exitCode):
                await refreshAuthStatus().value
                guard !Task.isCancelled, signInFlow == .waiting else { return }
                if exitCode == 0, case .mode(let mode) = savedAuth {
                    signedIn(mode: mode)
                } else {
                    signInFlow = .failed("gamdl couldn't sign in (exit code \(exitCode)). Check the Terminal window for details.")
                }
            }
        }
    }

    func cancelSignInWait() {
        signInTask?.cancel()
        signInTask = nil
        signInFlow = .idle
        refreshAuthStatus()
    }

    func dismissSignInResult() {
        if signInFlow != .waiting { signInFlow = .idle }
    }
}
