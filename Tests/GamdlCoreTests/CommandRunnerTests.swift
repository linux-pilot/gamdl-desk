import Foundation
import Testing
@testable import GamdlCore

/// Runs real child processes (via /bin/sh) to check streaming, ordering, exit status and stopping.
@Suite(.serialized) struct CommandRunnerTests {
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _lines: [String] = []
        private var _termination: CommandRunner.Termination?
        private var _linesAfterFinish = 0
        let done = DispatchSemaphore(value: 0)

        func handle(_ e: CommandRunner.Event) {
            lock.lock(); defer { lock.unlock() }
            switch e {
            case .lines(let l):
                if _termination != nil { _linesAfterFinish += l.count }
                _lines += l
            case .finished(let t):
                precondition(_termination == nil, "finished twice")
                _termination = t
                done.signal()
            }
        }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }
        var termination: CommandRunner.Termination? { lock.lock(); defer { lock.unlock() }; return _termination }
        var linesAfterFinish: Int { lock.lock(); defer { lock.unlock() }; return _linesAfterFinish }
    }

    func run(_ script: String, stopAfter: TimeInterval? = nil, grace: TimeInterval = 0.5,
             timeout: TimeInterval = 10) throws -> (Recorder, TimeInterval, CommandRunner) {
        let rec = Recorder()
        let r = CommandRunner(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
                              deliveryQueue: DispatchQueue(label: "test.delivery"), stopGrace: grace,
                              drainTimeout: 0.5) { rec.handle($0) }
        let start = Date()
        try r.start()
        if let stopAfter {
            Thread.sleep(forTimeInterval: stopAfter)
            r.stop()
        }
        #expect(rec.done.wait(timeout: .now() + timeout) == .success, "runner never finished")
        return (rec, Date().timeIntervalSince(start), r)
    }

    @Test func streamsStdoutAndStderrInOrderThenFinishes() throws {
        let (rec, _, _) = try run("printf 'one\\n'; printf 'two ✓\\n' >&2; printf 'no newline at end'; exit 3")
        #expect(rec.lines == ["one", "two ✓", "no newline at end"])
        #expect(rec.termination == .init(status: 3, signaled: false, stoppedByUser: false))
        #expect(rec.linesAfterFinish == 0)
    }

    @Test func manyLinesAreAllDeliveredBeforeFinished() throws {
        let (rec, _, _) = try run("i=0; while [ $i -lt 5000 ]; do echo \"line $i ✓\"; i=$((i+1)); done")
        #expect(rec.lines.count == 5000)
        #expect(rec.lines.last == "line 4999 ✓")
        #expect(rec.termination?.succeeded == true)
        #expect(rec.linesAfterFinish == 0)
    }

    @Test func stdinIsClosedSoPromptsFailFast() throws {
        let (rec, elapsed, _) = try run("read answer; echo \"got:$answer\"")
        #expect(rec.lines == ["got:"])
        #expect(elapsed < 5)
    }

    @Test func stopInterruptsWithSIGINT() throws {
        let (rec, elapsed, _) = try run("echo started; sleep 30", stopAfter: 0.3)
        #expect(rec.lines == ["started"])
        #expect(rec.termination?.stoppedByUser == true)
        #expect(rec.termination?.succeeded == false)
        #expect(elapsed < 3)
    }

    @Test func stopEscalatesWhenSIGINTAndSIGTERMAreIgnored() throws {
        let (rec, elapsed, _) = try run("trap '' INT TERM; echo stubborn; while :; do sleep 0.05; done",
                                        stopAfter: 0.3, grace: 0.4)
        #expect(rec.lines == ["stubborn"])
        #expect(rec.termination == .init(status: SIGKILL, signaled: true, stoppedByUser: true))
        #expect(elapsed > 1.0 && elapsed < 5)
    }

    @Test func finishesEvenIfAGrandchildKeepsTheOutputOpen() throws {
        // The shell exits at once, but the background sleep inherits stdout and holds the pipe open.
        let (rec, elapsed, _) = try run("echo parent; sleep 20 & exit 0")
        #expect(rec.lines == ["parent"])
        #expect(rec.termination?.succeeded == true)
        #expect(elapsed < 5)
    }

    @Test func missingExecutableThrowsAndDeliversNothing() {
        let rec = Recorder()
        let r = CommandRunner(executable: URL(fileURLWithPath: "/nonexistent/gamdl"), arguments: [],
                              deliveryQueue: DispatchQueue(label: "t")) { rec.handle($0) }
        #expect(throws: (any Error).self) { try r.start() }
        #expect(rec.done.wait(timeout: .now() + 0.5) == .timedOut)
    }
}
