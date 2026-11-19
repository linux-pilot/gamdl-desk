import Foundation
import GamdlCore

/// Where gamdl is installed and how the app runs it.
enum Gamdl {
    /// The app doesn't get the login shell's PATH, so gamdl is looked for where installers put it.
    static let searchPaths = [
        "\(NSHomeDirectory())/.local/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]
    static let installCommand = #"uv tool install "gamdl[widevine]""#
    static let configPath = "\(NSHomeDirectory())/.gamdl/config.yml"
    static let wrapperURL = URL(string: "https://github.com/glomatico/wrapper-v2")!

    static func locate() -> String? {
        searchPaths.map { "\($0)/gamdl" }.first { FileManager.default.isExecutableFile(atPath: $0) }
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

    /// Starts the gamdl at `path`. Output arrives with terminal escapes removed.
    @MainActor
    static func start(_ path: String, _ arguments: [String],
                      onLines: @escaping @MainActor @Sendable ([String]) -> Void,
                      onFinish: @escaping @MainActor @Sendable (CommandRunner.Termination) -> Void) throws -> CommandRunner {
        let runner = CommandRunner(executable: URL(fileURLWithPath: path), arguments: arguments,
                                   environment: environment, deliveryQueue: .main) { event in
            MainActor.assumeIsolated {
                switch event {
                case .lines(let lines): onLines(lines.map(TerminalText.strip))
                case .finished(let termination): onFinish(termination)
                }
            }
        }
        try runner.start()
        return runner
    }

    /// Runs gamdl to the end and returns everything it printed, or nil if it couldn't start.
    @MainActor
    static func output(_ path: String, _ arguments: [String]) async -> (lines: [String], termination: CommandRunner.Termination)? {
        let buffer = LineBuffer()
        return await withCheckedContinuation { continuation in
            do {
                _ = try start(path, arguments, onLines: { buffer.lines += $0 },
                              onFinish: { continuation.resume(returning: (buffer.lines, $0)) })
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }
}

@MainActor private final class LineBuffer {
    var lines: [String] = []
}
