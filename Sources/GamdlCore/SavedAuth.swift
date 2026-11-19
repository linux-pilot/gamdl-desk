import Foundation

/// The sign-in gamdl has saved, read from `gamdl config show` (which redacts tokens).
/// `gamdl auth` only saves after Apple Music accepted the sign-in, so a saved mode means it worked
/// when it was set up. It can still expire later; a download then reports an authentication error.
public enum SavedAuth: Equatable, Sendable {
    case none
    case mode(String)

    /// Parses the `auth.mode` value. Returns nil if the output doesn't contain it.
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

    /// How to describe the mode to a person.
    public static func label(for mode: String) -> String {
        switch mode {
        case "cookies": "cookies"
        case "media-user-token": "media user token"
        case "wrapper": "wrapper"
        default: mode
        }
    }
}
