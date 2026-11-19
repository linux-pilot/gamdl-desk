import Foundation

/// Turns a byte stream into text lines. Bytes are split on CR/LF before decoding, and those bytes
/// never occur inside a multi-byte UTF-8 character, so a character split across two reads stays intact.
/// A lone CR rewinds the current line like a terminal does (progress-style redraws keep only the last one).
/// Not thread-safe: feed it from one queue.
final class LineSplitter {
    private var current = Data()
    private var pendingCR = false

    init() {}

    func feed(_ data: Data) -> [String] {
        var lines: [String] = []
        for byte in data {
            if pendingCR {
                pendingCR = false
                if byte == 0x0A { lines.append(take()); continue }
                current.removeAll(keepingCapacity: true) // lone CR: overwrite the line
            }
            switch byte {
            case 0x0A: lines.append(take())
            case 0x0D: pendingCR = true
            default: current.append(byte)
            }
        }
        return lines
    }

    /// Call at end of stream: returns the unterminated last line, if any.
    func finish() -> [String] {
        defer { pendingCR = false }
        if pendingCR { return [take()] }
        return current.isEmpty ? [] : [take()]
    }

    private func take() -> String {
        defer { current.removeAll(keepingCapacity: true) }
        return String(decoding: current, as: UTF8.self)
    }
}

public enum TerminalText {
    private static let escapes = try! NSRegularExpression(
        pattern: "\u{1B}(?:\\[[0-?]*[ -/]*[@-~]|\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)|[0-~])")

    /// Removes ANSI colour/cursor sequences (CSI, OSC and two-byte escapes).
    public static func strip(_ s: String) -> String {
        guard s.contains("\u{1B}") else { return s }
        return escapes.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
    }
}

/// One finished item reported by `gamdl rip --no-progress`.
public struct OutputEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case saved, skipped, partial, failed }
    public var kind: Kind
    public var title: String
    public var detail: String
    public var path: String?

    init(kind: Kind, title: String, detail: String, path: String? = nil) {
        self.kind = kind; self.title = title; self.detail = detail; self.path = path
    }

    /// gamdl prints, per item (see gamdl/cli/progress.py and commands/runner.py):
    ///   `✓ Title: downloaded → /path`                         saved / overwritten
    ///   `✓ Title: media saved (finalization incomplete) → /p` partial
    ///   `↷ Title: skipped (reason) → /path`                   skipped
    ///   `  ✗ Label: message`                                  failure, in the final "Errors (N):" list
    public static func parse(_ rawLine: String) -> OutputEvent? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("✗ ") {
            let body = String(line.dropFirst(2))
            let (title, detail) = splitLast(body, on: ": ") ?? (body, "failed")
            return OutputEvent(kind: .failed, title: title, detail: detail)
        }
        let isSkip = line.hasPrefix("↷ ")
        guard isSkip || line.hasPrefix("✓ ") else { return nil }
        var body = String(line.dropFirst(2))
        var path: String?
        if let r = body.range(of: " → ") {
            path = String(body[r.upperBound...])
            body = String(body[..<r.lowerBound])
        }
        if isSkip {
            guard let r = body.range(of: ": skipped", options: .backwards) else { return nil }
            var reason = String(body[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            if reason.hasPrefix("("), reason.hasSuffix(")") { reason = String(reason.dropFirst().dropLast()) }
            return OutputEvent(kind: .skipped, title: String(body[..<r.lowerBound]),
                               detail: reason.isEmpty ? "skipped" : reason, path: path)
        }
        guard let (title, status) = splitLast(body, on: ": ") else { return nil }
        let partial = status.hasPrefix("media saved")
        return OutputEvent(kind: partial ? .partial : .saved, title: title, detail: status, path: path)
    }

    private static func splitLast(_ s: String, on sep: String) -> (String, String)? {
        guard let r = s.range(of: sep, options: .backwards) else { return nil }
        return (String(s[..<r.lowerBound]), String(s[r.upperBound...]))
    }
}

/// Something in a run's output the user has to act on.
public enum RunIssue: Hashable, Sendable {
    /// gamdl couldn't sign in; the user needs to run `gamdl auth` or pick a cookies file.
    case signInRejected
    /// Apple refused the ALAC decryption key: lossless needs gamdl's Wrapper.
    case losslessRefused

    public static func detect(in line: String, songCodec: SongCodec) -> RunIssue? {
        let l = line.lowercased()
        if l.contains("authentication setup requires an interactive terminal") || l.contains("authentication failed") {
            return .signInRejected
        }
        if songCodec.needsWrapper,
           l.contains("drmlicenseerror") || l.contains("unable to acquire or process decryption key") {
            return .losslessRefused
        }
        return nil
    }
}
