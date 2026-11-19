import Foundation

/// gamdl's eight output-path templates (`--album-folder-template` and friends).
/// A file is saved at `<output dir>/<folder template>/<file template>.<ext>`; gamdl picks the album,
/// compilation or no-album folder (and single-disc, multi-disc or no-album file name) per item.
/// See gamdl/download/paths.py.
public struct PathTemplates: Equatable, Sendable {
    public var albumFolder = "{album_artist}/{album}"
    public var compilationFolder = "Compilations/{album}"
    public var noAlbumFolder = "{artist}/Unknown Album"
    public var playlistFolder = "Playlists/{playlist_artist}"
    public var singleDiscFile = "{track:02d} {title}"
    public var multiDiscFile = "{disc}-{track:02d} {title}"
    public var noAlbumFile = "{title}"
    public var playlistFile = "{playlist_title}"

    public init() {}

    /// gamdl's command-line flags for these templates.
    public var arguments: [String] {
        ["--album-folder-template", albumFolder,
         "--compilation-folder-template", compilationFolder,
         "--no-album-folder-template", noAlbumFolder,
         "--playlist-folder-template", playlistFolder,
         "--single-disc-file-template", singleDiscFile,
         "--multi-disc-file-template", multiDiscFile,
         "--no-album-file-template", noAlbumFile,
         "--playlist-file-template", playlistFile]
    }

    /// Each template with a name for error messages.
    public var labeled: [(label: String, template: String)] {
        [("Album folder", albumFolder), ("Compilation folder", compilationFolder),
         ("No-album folder", noAlbumFolder), ("Playlist folder", playlistFolder),
         ("Single-disc file", singleDiscFile), ("Multi-disc file", multiDiscFile),
         ("No-album file", noAlbumFile), ("Playlist file", playlistFile)]
    }
}

/// How downloads are arranged into folders.
public enum FolderLayout: String, CaseIterable, Sendable {
    case artistAlbum, artistYearAlbum, artistDashAlbum, albumOnly, artistOnly, flat, custom

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

    /// Album, compilation and no-album folder templates. Flat and custom are handled by the caller.
    public var folders: (album: String, compilation: String, noAlbum: String)? {
        switch self {
        case .artistAlbum: ("{album_artist}/{album}", "Compilations/{album}", "{artist}/Unknown Album")
        case .artistYearAlbum: ("{album_artist}/{date:%Y} - {album}", "Compilations/{date:%Y} - {album}", "{artist}/Unknown Album")
        case .artistDashAlbum: ("{album_artist} - {album}", "Compilations - {album}", "{artist} - Unknown Album")
        case .albumOnly: ("{album}", "{album}", "Unknown Album")
        case .artistOnly: ("{album_artist}", "Compilations", "{artist}")
        case .flat, .custom: nil
        }
    }
}

/// How files are named.
public enum FileNaming: String, CaseIterable, Sendable {
    case trackTitle, title, artistTitle, trackArtistTitle, custom

    public var label: String {
        switch self {
        case .trackTitle: "01 Title"
        case .title: "Title"
        case .artistTitle: "Artist - Title"
        case .trackArtistTitle: "01 Artist - Title"
        case .custom: "Custom"
        }
    }

    /// Single-disc, multi-disc and no-album file templates, or nil for custom.
    public var files: (single: String, multi: String, noAlbum: String)? {
        switch self {
        case .trackTitle: ("{track:02d} {title}", "{disc}-{track:02d} {title}", "{title}")
        case .title: ("{title}", "{title}", "{title}")
        case .artistTitle: ("{artist} - {title}", "{artist} - {title}", "{artist} - {title}")
        case .trackArtistTitle: ("{track:02d} {artist} - {title}", "{disc}-{track:02d} {artist} - {title}", "{artist} - {title}")
        case .custom: nil
        }
    }
}

/// Renders gamdl path templates the way gamdl does (Python `str.format` with its restrictions and
/// filename clean-up), for validation and previews.
public enum PathTemplate {
    public static let fields = ["album", "album_artist", "album_id", "artist", "artist_id", "composer",
                                "composer_id", "date", "disc", "disc_total", "media_type", "playlist_artist",
                                "playlist_id", "playlist_title", "playlist_track", "title", "title_id",
                                "track", "track_total"]

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
        if template.trimmingCharacters(in: .whitespaces).isEmpty { return "It's empty." }
        if template.hasPrefix("/") { return "It can't start with /." }
        if template.split(separator: "/", omittingEmptySubsequences: false).contains(where: \.isEmpty) {
            return "It has an empty folder name (// or a trailing /)."
        }
        for segment in template.split(separator: "/") {
            do { _ = try parse(String(segment)) } catch let error as ParseError { return error.message } catch { return "Invalid template." }
        }
        return nil
    }

    struct ParseError: Error { let message: String }

    /// Python `Formatter.parse`, plus gamdl's rules: only known fields, no `!conversion`,
    /// no nested `{}` in format specs. gamdl splits on "/" before parsing, so call this per segment.
    static func parse(_ s: String) throws -> [Piece] {
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

    /// Path components for `template` (nil if invalid). The last one gets `fileExtension` when set.
    public static func render(_ template: String, values: [String: Value], fileExtension: String? = nil,
                              truncate: Int? = nil) -> [String]? {
        guard problem(in: template) == nil else { return nil }
        let segments = template.split(separator: "/").map(String.init)
        return segments.enumerated().map { index, segment in
            let pieces = (try? parse(segment)) ?? []
            let text = pieces.map { piece -> String in
                switch piece {
                case .literal(let l): return l
                case .field(let name, let spec): return format(values[name], spec: spec, fallback: fallback(for: name))
                }
            }.joined()
            let isFile = fileExtension != nil && index == segments.count - 1
            return clean(text, directory: !isFile, fileExtension: isFile ? fileExtension! : "", truncate: truncate)
        }
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
    public static func clean(_ value: String, directory: Bool, fileExtension: String = "", truncate: Int? = nil) -> String {
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

    /// Escapes text so a template renders it literally.
    public static func literal(_ s: String) -> String {
        s.replacingOccurrences(of: "{", with: "{{").replacingOccurrences(of: "}", with: "}}")
    }
}
