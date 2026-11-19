import AppKit
import GamdlCore

/// Runs `gamdl auth`, which asks questions and so needs a real terminal. Terminal gives the app no
/// handle on the process, so the script writes gamdl's exit code to a status file (130 if the window
/// is closed or interrupted) and the app waits for that file.
struct TerminalSignIn: Sendable {
    enum Outcome: Equatable {
        case finished(exitCode: Int32)
        /// Interrupted, or the Terminal window was closed (the script exits with 130).
        case cancelled
        /// Gave up waiting, or the wait was cancelled.
        case noResult
        case failed(String)
    }

    var command: String
    /// Starts the script, normally in a Terminal window.
    var open: @Sendable (URL) async throws -> Void

    static func terminal(gamdl: String) -> TerminalSignIn {
        TerminalSignIn(command: Shell.quoted(gamdl) + " auth") { script in
            let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                NSWorkspace.shared.open([script], withApplicationAt: terminal,
                                        configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        }
    }

    private static let folderPrefix = "gamdl-desk-auth-"
    private static let cancelledExitCode: Int32 = 130

    /// Removes scripts left behind if the app quit while one was open.
    static func removeLeftovers() {
        let tmp = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        for name in names where name.hasPrefix(folderPrefix) {
            try? FileManager.default.removeItem(at: tmp.appendingPathComponent(name))
        }
    }

    func run() async -> Outcome {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(Self.folderPrefix + UUID().uuidString)
        let script = dir.appendingPathComponent("Sign in to Apple Music.command")
        let status = dir.appendingPathComponent("status")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try scriptText(statusFile: status).write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        } catch {
            return .failed("Couldn't prepare the sign-in script: \(error.localizedDescription)")
        }
        do {
            try await open(script)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            return .failed("Couldn't open Terminal: \(error.localizedDescription). Run `gamdl auth` in Terminal instead.")
        }
        // Give up after 30 minutes; activating the app still re-checks the saved sign-in.
        for _ in 0..<1800 {
            try? await Task.sleep(for: .seconds(1))
            // The folder stays: the script may still be running and will write its status there.
            // It's removed at the next launch.
            if Task.isCancelled { return .noResult }
            guard let text = try? String(contentsOf: status, encoding: .utf8),
                  let code = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { continue }
            try? FileManager.default.removeItem(at: dir)
            return code == Self.cancelledExitCode ? .cancelled : .finished(exitCode: code)
        }
        try? FileManager.default.removeItem(at: dir)
        return .noResult
    }

    private func scriptText(statusFile: URL) -> String {
        """
        #!/bin/zsh
        STATUS=\(Shell.quoted(statusFile.path))
        # Report how the script ended on every path: normal exit, error, Ctrl-C or closing the window.
        trap 'exit \(Self.cancelledExitCode)' INT HUP TERM
        trap 'echo $? > "$STATUS.tmp" && mv "$STATUS.tmp" "$STATUS"' EXIT
        clear
        echo "Signing in to Apple Music for gamdl. Answer the questions below."
        echo
        \(command)
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
    }
}
