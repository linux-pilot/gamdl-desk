import Foundation

/// Runs one child process, streaming its combined stdout/stderr as lines.
///
/// Guarantees: every `.lines` event is delivered before the single `.finished` event, all on
/// `deliveryQueue`, in order. `.finished` waits for both process exit and end of output, but no
/// longer than `drainTimeout` after exit (a grandchild process may keep the pipe open).
/// `stop()` sends SIGINT, then SIGTERM, then SIGKILL, `stopGrace` seconds apart, until it exits.
public final class CommandRunner: @unchecked Sendable {
    public struct Termination: Equatable, Sendable {
        public var status: Int32
        public var signaled: Bool
        public var stoppedByUser: Bool
        public var succeeded: Bool { status == 0 && !signaled && !stoppedByUser }
    }

    public enum Event: Sendable {
        case lines([String])
        case finished(Termination)
    }

    private let process = Process()
    private let pipe = Pipe()
    private let deliveryQueue: DispatchQueue
    private let onEvent: @Sendable (Event) -> Void
    private let stopGrace: TimeInterval
    private let drainTimeout: TimeInterval

    // All mutable state below is only touched on `queue`.
    private let queue = DispatchQueue(label: "GamdlCore.CommandRunner")
    private let splitter = LineSplitter()
    private var started = false
    private var reachedEOF = false
    private var exit: (status: Int32, signaled: Bool)?
    private var stopRequested = false
    private var finished = false

    public init(executable: URL, arguments: [String], environment: [String: String]? = nil,
                deliveryQueue: DispatchQueue = .main, stopGrace: TimeInterval = 4, drainTimeout: TimeInterval = 2,
                onEvent: @escaping @Sendable (Event) -> Void) {
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        // No stdin: an interactive prompt fails fast instead of hanging forever.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        self.deliveryQueue = deliveryQueue
        self.onEvent = onEvent
        self.stopGrace = stopGrace
        self.drainTimeout = drainTimeout
    }

    /// Starts the process. On failure nothing is delivered and the error is thrown.
    public func start() throws {
        try queue.sync {
            precondition(!started, "CommandRunner can only be started once")
            started = true
            // The runner keeps itself alive until the process has finished.
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil } // EOF: stop the handler re-firing
                self.queue.async { self.received(data) }
            }
            process.terminationHandler = { p in
                let status = p.terminationStatus, signaled = p.terminationReason == .uncaughtSignal
                self.queue.async { self.exited(status: status, signaled: signaled) }
            }
            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                process.terminationHandler = nil
                throw error
            }
        }
    }

    public func stop() {
        queue.async {
            guard self.started, self.exit == nil, !self.stopRequested else { return }
            self.stopRequested = true
            self.process.interrupt()
            self.escalate(after: self.stopGrace) {
                self.process.terminate()
                self.escalate(after: self.stopGrace) { kill(self.process.processIdentifier, SIGKILL) }
            }
        }
    }

    private func escalate(after delay: TimeInterval, _ action: @escaping @Sendable () -> Void) {
        queue.asyncAfter(deadline: .now() + delay) {
            if self.exit == nil, self.process.isRunning { action() }
        }
    }

    private func received(_ data: Data) {
        guard !finished else { return }
        if data.isEmpty {
            reachedEOF = true
            deliver(splitter.finish())
            finishIfDone()
        } else {
            deliver(splitter.feed(data))
        }
    }

    private func exited(status: Int32, signaled: Bool) {
        exit = (status, signaled)
        finishIfDone()
        guard !finished else { return }
        queue.asyncAfter(deadline: .now() + drainTimeout) {
            guard !self.finished else { return }
            self.pipe.fileHandleForReading.readabilityHandler = nil
            self.deliver(self.splitter.finish())
            self.reachedEOF = true
            self.finishIfDone()
        }
    }

    private func finishIfDone() {
        guard !finished, reachedEOF, let exit else { return }
        finished = true
        // Break the runner <-> process handler reference cycle.
        pipe.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        let t = Termination(status: exit.status, signaled: exit.signaled, stoppedByUser: stopRequested)
        deliveryQueue.async { self.onEvent(.finished(t)) }
    }

    private func deliver(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        deliveryQueue.async { self.onEvent(.lines(lines)) }
    }
}
