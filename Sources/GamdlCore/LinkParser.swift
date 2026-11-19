import Foundation

/// Splits pasted text into inputs gamdl accepts: Apple Music links and ISRC codes.
/// This is the trust boundary for the URL box: anything else is reported, never passed to gamdl.
public enum LinkParser {
    public struct Result: Equatable, Sendable {
        public var valid: [String] = []
        public var invalid: [String] = []
        public var duplicates = 0
    }

    public static func parse(_ text: String) -> Result {
        var result = Result()
        var seen = Set<String>()
        for raw in text.split(whereSeparator: { $0.isWhitespace }) {
            let token = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'(),;"))
            guard !token.isEmpty else { continue }
            guard let input = normalize(token) else {
                result.invalid.append(token)
                continue
            }
            if seen.insert(input).inserted { result.valid.append(input) } else { result.duplicates += 1 }
        }
        return result
    }

    /// Returns the form to pass to gamdl, or nil if the token isn't an Apple Music link or ISRC.
    static func normalize(_ token: String) -> String? {
        if isISRC(token) { return token.uppercased() }
        var candidate = token
        if !candidate.contains("://") { candidate = "https://" + candidate }
        guard let comps = URLComponents(string: candidate),
              let scheme = comps.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = comps.host?.lowercased(),
              host == "music.apple.com" || host.hasSuffix(".music.apple.com"),
              comps.path.count > 1
        else { return nil }
        return candidate
    }

    /// A link straight to a music video (music.apple.com/<storefront>/music-video/<name>/<id>).
    public static func isMusicVideoLink(_ input: String) -> Bool {
        URLComponents(string: input)?.path.split(separator: "/").contains("music-video") ?? false
    }

    /// ISRC: 2-letter country, 3 alphanumeric registrant, 7 digits (year + designation).
    static func isISRC(_ s: String) -> Bool {
        let u = Array(s.uppercased().utf8)
        guard u.count == 12 else { return false }
        func letter(_ c: UInt8) -> Bool { c >= 65 && c <= 90 }
        func digit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }
        return u[0..<2].allSatisfy(letter) && u[2..<5].allSatisfy { letter($0) || digit($0) } && u[5...].allSatisfy(digit)
    }
}
