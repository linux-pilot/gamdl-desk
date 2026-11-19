import Foundation

/// gamdl's eight output-path templates (`--album-folder-template` and friends).
/// A file is saved at `<output dir>/<folder template>/<file template>.<ext>`; gamdl picks the album,
/// compilation or no-album folder (and single-disc, multi-disc or no-album file name) per item.
/// See gamdl/download/paths.py.
public struct PathTemplates: Equatable, Sendable {
    public enum Slot: String, CaseIterable, Sendable, CodingKey {
        case albumFolder, compilationFolder, noAlbumFolder, playlistFolder
        case singleDiscFile, multiDiscFile, noAlbumFile, playlistFile

        static let folders = allCases.filter(\.isFolder)
        static let files = allCases.filter { !$0.isFolder }

        var isFolder: Bool {
            switch self {
            case .albumFolder, .compilationFolder, .noAlbumFolder, .playlistFolder: true
            default: false
            }
        }

        var gamdlDefault: String {
            switch self {
            case .albumFolder: "{album_artist}/{album}"
            case .compilationFolder: "Compilations/{album}"
            case .noAlbumFolder: "{artist}/Unknown Album"
            case .playlistFolder: "Playlists/{playlist_artist}"
            case .singleDiscFile: "{track:02d} {title}"
            case .multiDiscFile: "{disc}-{track:02d} {title}"
            case .noAlbumFile: "{title}"
            case .playlistFile: "{playlist_title}"
            }
        }

        var flag: String {
            switch self {
            case .albumFolder: "--album-folder-template"
            case .compilationFolder: "--compilation-folder-template"
            case .noAlbumFolder: "--no-album-folder-template"
            case .playlistFolder: "--playlist-folder-template"
            case .singleDiscFile: "--single-disc-file-template"
            case .multiDiscFile: "--multi-disc-file-template"
            case .noAlbumFile: "--no-album-file-template"
            case .playlistFile: "--playlist-file-template"
            }
        }

        /// What gamdl uses it for, as a field title and in error messages.
        public var title: String {
            switch self {
            case .albumFolder: "Album folder"
            case .compilationFolder: "Compilation folder"
            case .noAlbumFolder: "Songs without an album, and videos"
            case .playlistFolder: "Playlist file folder"
            case .singleDiscFile: "Album track"
            case .multiDiscFile: "Track on a multi-disc album"
            case .noAlbumFile: "Song without an album, or video"
            case .playlistFile: "Playlist file"
            }
        }
    }

    /// Always holds every slot, so `==` compares what the templates are.
    private var values = Dictionary(uniqueKeysWithValues: Slot.allCases.map { ($0, $0.gamdlDefault) })

    public init() {}

    public subscript(slot: Slot) -> String {
        get { values[slot]! }
        set { values[slot] = newValue }
    }

    var arguments: [String] { Slot.allCases.flatMap { [$0.flag, self[$0]] } }
}

extension PathTemplates: Codable {
    /// Missing values fall back to gamdl's defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Slot.self)
        for slot in Slot.allCases {
            if let value = (try? c.decodeIfPresent(String.self, forKey: slot)) ?? nil { self[slot] = value }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Slot.self)
        for slot in Slot.allCases { try c.encode(self[slot], forKey: slot) }
    }
}

/// A named choice for one group of template slots (folders or file names), plus Custom.
public protocol PathPreset: CaseIterable, Hashable, Sendable where AllCases == [Self] {
    static var custom: Self { get }
    static var slots: [PathTemplates.Slot] { get }
    var label: String { get }
    /// The templates this preset sets; slots it leaves out get gamdl's default. Nil for Custom, which
    /// uses the custom templates, and for presets resolved elsewhere (see `FolderLayout.flat`).
    var templates: [PathTemplates.Slot: String]? { get }
}

extension PathPreset {
    public static var presets: [Self] { allCases.filter { $0 != custom } }

    func apply(to t: inout PathTemplates, custom: PathTemplates) {
        for slot in Self.slots { t[slot] = templates.map { $0[slot] ?? slot.gamdlDefault } ?? custom[slot] }
    }

    /// Switching to Custom starts from the previous preset, so it's easy to tweak, unless the
    /// custom templates were already edited (those are never overwritten).
    static func seedCustom(_ custom: inout PathTemplates, from old: Self, to new: Self) {
        guard new == Self.custom, old.templates != nil,
              Self.slots.allSatisfy({ custom[$0] == $0.gamdlDefault }) else { return }
        old.apply(to: &custom, custom: custom)
    }
}

public enum FolderLayout: String, PathPreset {
    case artistAlbum, artistYearAlbum, artistDashAlbum, albumOnly, artistOnly, flat, custom

    public static let slots = PathTemplates.Slot.folders

    public var label: String {
        switch self {
        case .artistAlbum: "Artist / Album"
        case .artistYearAlbum: "Artist / Year - Album"
        case .artistDashAlbum: "Artist - Album"
        case .albumOnly: "Album"
        case .artistOnly: "Artist"
        case .flat: "No folders"
        case .custom: "Custom"
        }
    }

    /// No folders has none: its folder is the output folder's own name (see `DownloadOptions`).
    public var templates: [PathTemplates.Slot: String]? {
        switch self {
        case .artistAlbum: [:]
        case .artistYearAlbum: [.albumFolder: "{album_artist}/{date:%Y} - {album}",
                                .compilationFolder: "Compilations/{date:%Y} - {album}"]
        case .artistDashAlbum: [.albumFolder: "{album_artist} - {album}", .compilationFolder: "Compilations - {album}",
                                .noAlbumFolder: "{artist} - Unknown Album"]
        case .albumOnly: [.albumFolder: "{album}", .compilationFolder: "{album}", .noAlbumFolder: "Unknown Album"]
        case .artistOnly: [.albumFolder: "{album_artist}", .compilationFolder: "Compilations", .noAlbumFolder: "{artist}"]
        case .flat, .custom: nil
        }
    }
}

public enum FileNaming: String, PathPreset {
    case trackTitle, title, artistTitle, trackArtistTitle, custom

    public static let slots = PathTemplates.Slot.files

    public var label: String {
        switch self {
        case .trackTitle: "01 Title"
        case .title: "Title"
        case .artistTitle: "Artist - Title"
        case .trackArtistTitle: "01 Artist - Title"
        case .custom: "Custom"
        }
    }

    public var templates: [PathTemplates.Slot: String]? {
        switch self {
        case .trackTitle: [:]
        case .title: [.singleDiscFile: "{title}", .multiDiscFile: "{title}", .noAlbumFile: "{title}"]
        case .artistTitle: [.singleDiscFile: "{artist} - {title}", .multiDiscFile: "{artist} - {title}",
                            .noAlbumFile: "{artist} - {title}"]
        case .trackArtistTitle: [.singleDiscFile: "{track:02d} {artist} - {title}",
                                 .multiDiscFile: "{disc}-{track:02d} {artist} - {title}", .noAlbumFile: "{artist} - {title}"]
        case .custom: nil
        }
    }
}

/// Renders gamdl path templates the way gamdl does (Python `str.format` with its restrictions and
/// filename clean-up), for validation and previews.
public enum PathTemplate {
    public static let fields = ["album", "album_artist", "artist", "title", "composer", "date", "track",
                                "track_total", "disc", "disc_total", "media_type", "playlist_title",
                                "playlist_artist", "playlist_track", "album_id", "artist_id", "title_id",
                                "composer_id", "playlist_id"]

    public enum Value: Sendable {
        case text(String)
        case number(Int)
        case date(String) // ISO date, formatted with strftime-style specs like %Y
    }

    enum Piece: Equatable {
        case literal(String)
        case field(name: String, spec: String)
    }

    /// Why gamdl would reject this template, or nil if it's fine.
    public static func problem(in template: String) -> String? {
        do { _ = try segments(of: template); return nil } catch { return error.message }
    }

    /// The template's folder/file segments, parsed, or the reason gamdl would reject it.
    static func segments(of template: String) throws(ParseError) -> [[Piece]] {
        if template.trimmingCharacters(in: .whitespaces).isEmpty { throw ParseError(message: "It's empty.") }
        if template.hasPrefix("/") { throw ParseError(message: "It can't start with /.") }
        let segments = template.split(separator: "/", omittingEmptySubsequences: false)
        if segments.contains(where: \.isEmpty) { throw ParseError(message: "It has an empty folder name (// or a trailing /).") }
        return try segments.map { (segment) throws(ParseError) in try parse(String(segment)) }
    }

    struct ParseError: Error { let message: String }

    /// Python `Formatter.parse`, plus gamdl's rules: only known fields, no `!conversion`,
    /// no nested `{}` in format specs. gamdl splits on "/" before parsing, so call this per segment.
    static func parse(_ s: String) throws(ParseError) -> [Piece] {
        var pieces: [Piece] = []
        var literal = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            let next = s.index(after: i)
            if c == "{" {
                if next < s.endIndex, s[next] == "{" { literal.append("{"); i = s.index(after: next); continue }
                guard let close = s[next...].firstIndex(where: { $0 == "}" || $0 == "{" }), s[close] == "}" else {
                    throw ParseError(message: s[next...].contains("}") ? "Fields can't contain { }." : "A { isn't closed.")
                }
                let body = String(s[next..<close])
                let nameEnd = body.firstIndex(where: { $0 == ":" || $0 == "!" }) ?? body.endIndex
                let name = String(body[..<nameEnd])
                if body[nameEnd...].hasPrefix("!") {
                    throw ParseError(message: "{\(body)}: conversions like !r aren't allowed.")
                }
                guard fields.contains(name) else {
                    throw ParseError(message: name.isEmpty ? "{} needs a field name." : "{\(name)} isn't a field gamdl knows.")
                }
                if !literal.isEmpty { pieces.append(.literal(literal)); literal = "" }
                pieces.append(.field(name: name, spec: nameEnd < body.endIndex ? String(body[body.index(after: nameEnd)...]) : ""))
                i = s.index(after: close)
            } else if c == "}" {
                guard next < s.endIndex, s[next] == "}" else { throw ParseError(message: "A } has no matching {. Use }} for a literal }.") }
                literal.append("}")
                i = s.index(after: next)
            } else {
                literal.append(c)
                i = next
            }
        }
        if !literal.isEmpty { pieces.append(.literal(literal)) }
        return pieces
    }

    static func render(_ template: String, values: [String: Value], fileExtension: String? = nil,
                       truncate: Int? = nil) -> [String]? {
        guard let segments = try? segments(of: template) else { return nil }
        var components: [String] = []
        for (index, pieces) in segments.enumerated() {
            let text = pieces.map { piece -> String in
                switch piece {
                case .literal(let l): return l
                case .field(let name, let spec): return format(values[name], spec: spec, fallback: fallback(for: name))
                }
            }.joined()
            let isFile = fileExtension != nil && index == segments.count - 1
            components.append(clean(text, directory: !isFile, fileExtension: isFile ? fileExtension! : "", truncate: truncate))
        }
        return components
    }

    /// gamdl substitutes these when a value is missing (or a format spec doesn't fit the value).
    static func fallback(for field: String) -> String {
        switch field {
        case "disc", "disc_total", "track", "track_total", "playlist_track": ""
        case "date": "Unknown Date"
        case "album_artist", "artist": "Unknown Artist"
        default: "Unknown " + field.split(separator: "_").map { $0 == "id" ? "ID" : $0.capitalized }.joined(separator: " ")
        }
    }

    static func format(_ value: Value?, spec: String, fallback: String) -> String {
        switch value {
        case nil: return fallback
        case .text(let s):
            return s.isEmpty ? fallback : pythonFormat(s, spec: spec, numeric: false) ?? fallback
        case .number(let n):
            return pythonFormat(String(n), spec: spec, numeric: true) ?? fallback
        case .date(let raw):
            guard spec.hasPrefix("%") else { return pythonFormat(raw, spec: spec, numeric: false) ?? fallback }
            let parts = raw.prefix(10).split(separator: "-").map(String.init)
            guard let year = parts.first, year.count == 4, let month = Int(parts.count > 1 ? parts[1] : "1"),
                  (1...12).contains(month) else { return fallback }
            let months = ["January", "February", "March", "April", "May", "June", "July", "August",
                          "September", "October", "November", "December"]
            let day = parts.count > 2 ? parts[2] : "01"
            var out = "", chars = Array(spec), i = 0
            while i < chars.count {
                if chars[i] == "%", i + 1 < chars.count {
                    switch chars[i + 1] {
                    case "Y": out += year
                    case "y": out += String(year.suffix(2))
                    case "m": out += String(format: "%02d", month)
                    case "d": out += day
                    case "B": out += months[month - 1]
                    case "b": out += String(months[month - 1].prefix(3))
                    case "%": out += "%"
                    default: out += String(chars[i...(i + 1)])
                    }
                    i += 2
                } else {
                    out.append(chars[i]); i += 1
                }
            }
            return out
        }
    }

    /// Python's format-spec mini-language, the parts that make sense in names:
    /// `[[fill]align][0][width][.precision][s|d]`. Returns nil where Python would raise
    /// (gamdl then uses the field's fallback text).
    static func pythonFormat(_ value: String, spec: String, numeric: Bool) -> String? {
        guard let m = spec.wholeMatch(of: /(?:(.)?([<>^=]))?(0)?(\d+)?(?:\.(\d+))?([sd])?/) else { return nil }
        let (_, fill, align, zero, widthText, precision, type) = m.output
        if numeric ? (type == "s" || precision != nil) : (type == "d" || align == "=") { return nil }
        var text = value
        if let p = precision.flatMap({ Int($0) }) { text = String(text.prefix(p)) }
        let width = widthText.flatMap { Int($0) } ?? 0
        guard text.count < width else { return text }
        let padChar = fill.map(String.init) ?? (zero != nil && align == nil ? "0" : " ")
        let padding = width - text.count
        func pad(_ n: Int) -> String { String(repeating: padChar, count: n) }
        switch align.map(String.init) ?? (numeric ? ">" : "<") {
        case "<": return text + pad(padding)
        case "^": return pad(padding / 2) + text + pad(padding - padding / 2)
        default: return pad(padding) + text
        }
    }

    /// gamdl's `_component`: replace characters macOS/Windows can't use, avoid hidden and empty names,
    /// and limit to `truncate` (max 255) UTF-8 bytes including the extension.
    static func clean(_ value: String, directory: Bool, fileExtension: String = "", truncate: Int? = nil) -> String {
        var s = String(value.unicodeScalars.map { scalar -> Character in
            "<>:\"/\\|?*".unicodeScalars.contains(scalar) || scalar.value < 0x20 || scalar.value == 0x7F
                ? "_" : Character(scalar)
        }).trimmingCharacters(in: .whitespaces)
        if s.hasPrefix(".") { s = "_" + s.dropFirst() }
        if !directory, s == "." || s == ".." { s = s.replacingOccurrences(of: ".", with: "_") }
        if s.hasSuffix(".") { s = s.dropLast() + "_" }
        if s.isEmpty { s = "_" }
        let limit = min(truncate ?? 255, 255) - fileExtension.utf8.count
        while s.utf8.count > max(limit, 1) { s.removeLast() }
        if s.isEmpty || s == "." || s == ".." { s = "_" }
        if s.hasPrefix(".") { s = "_" + s.dropFirst() }
        return s + fileExtension
    }

    static func literal(_ s: String) -> String {
        s.replacingOccurrences(of: "{", with: "{{").replacingOccurrences(of: "}", with: "}}")
    }
}
