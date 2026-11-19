import Foundation

/// The sign-in gamdl has saved, read from `gamdl config show` (which redacts tokens).
/// `gamdl auth` only saves after Apple Music accepted the sign-in, so a saved mode means it worked
/// when it was set up. It can still expire later; a download then reports an authentication error.
public enum SavedAuth: Equatable, Sendable {
    case none
    case mode(String)

    /// Nil if the output has no `auth.mode` (unlike `.none`: gamdl says nobody is signed in).
    public static func parse(configShow output: String) -> SavedAuth? {
        var inAuth = false
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if !line.hasPrefix(" ") && !line.isEmpty {
                inAuth = line.trimmingCharacters(in: .whitespaces) == "auth:"
                continue
            }
            guard inAuth else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("mode:") else { continue }
            let value = trimmed.dropFirst("mode:".count).trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            return ["", "null", "~"].contains(value) ? SavedAuth.none : .mode(value)
        }
        return nil
    }

    public static func label(for mode: String) -> String { mode.replacingOccurrences(of: "-", with: " ") }

    /// Signed in through Wrapper v2, the only sign-in Apple grants ALAC keys to.
    public var isWrapper: Bool { self == .mode("wrapper") }
}
