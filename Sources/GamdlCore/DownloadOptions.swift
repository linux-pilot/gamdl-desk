import Foundation

/// Everything the user can set in the app, turned into a `gamdl rip` command line.
/// Stored in UserDefaults as JSON (see `RawRepresentable`), so adding a field later keeps old settings.
public struct DownloadOptions: Equatable, Sendable {
    public var outputDir = "~/Music/gamdl"
    public var cookiesPath = ""
    public var songCodec = "aac"
    public var saveLyrics = true
    public var lyricsFormat = "lrc"
    public var mvCodec = "h264"
    public var mvContainer = "m4v"
    public var maxHeight = 1080
    public var saveCover = false
    public var coverFormat = "jpg"
    public var savePlaylist = false
    public var overwrite = false
    public var artistSelection = "all-albums"
    public var concurrentDownloads = 2

    public init() {}

    public static let songCodecs = ["aac", "aac-he", "aac-binaural", "aac-downmix", "aac-he-binaural",
                                    "aac-he-downmix", "aac-web", "aac-he-web", "atmos", "ac3",
                                    "alac", "alac-lossless", "alac-hires"]
    public static let lyricsFormats = ["lrc", "enhanced-lrc", "srt", "ttml", "enhanced-ttml", "text"]
    public static let mvCodecs = ["h264", "h265"]
    public static let mvContainers = ["m4v", "mp4"]
    public static let maxHeights = [480, 720, 1080, 1440, 2160]
    public static let coverFormats = ["jpg", "png"]
    /// gamdl's `--artist-auto-select` values. Without one, an artist link opens an
    /// interactive menu, which can't work because the app gives gamdl no terminal.
    public static let artistSelections: [(value: String, label: String)] = [
        ("all-albums", "All albums"),
        ("main-albums", "Main albums"),
        ("singles-eps", "Singles & EPs"),
        ("live-albums", "Live albums"),
        ("compilation-albums", "Compilations"),
        ("top-songs", "Top songs"),
        ("music-videos", "Music videos"),
        ("all", "All albums + music videos"),
    ]
    public static let concurrencyRange = 1...8

    public var expandedOutputDir: String { Self.expand(outputDir) }
    public var expandedCookiesPath: String { Self.expand(cookiesPath) }

    public static func expand(_ path: String) -> String {
        (path.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
    }

    /// Why a download can't start with these settings, or nil if it can.
    public func blockingIssue(fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        if outputDir.trimmingCharacters(in: .whitespaces).isEmpty { return "Choose an output folder." }
        if !cookiesPath.trimmingCharacters(in: .whitespaces).isEmpty, !fileExists(expandedCookiesPath) {
            return "The cookies file doesn't exist."
        }
        return nil
    }

    /// Arguments for `gamdl`. `inputs` must already be validated links/ISRCs (see `LinkParser`);
    /// they go after `--` so nothing in them can be read as an option.
    public func arguments(inputs: [String]) -> [String] {
        var a = ["rip", "--no-progress", "--no-tracebacks",
                 "--output-dir", expandedOutputDir,
                 "--song-codec", songCodec,
                 "--music-video-codec", mvCodec,
                 "--music-video-container", mvContainer,
                 "--max-height", String(maxHeight),
                 "--cover-format", coverFormat,
                 "--artist-auto-select", artistSelection,
                 "--concurrent-downloads", String(Self.concurrencyRange.clamped(concurrentDownloads)),
                 saveCover ? "--save-cover" : "--no-save-cover",
                 savePlaylist ? "--save-playlist" : "--no-save-playlist",
                 overwrite ? "--overwrite" : "--no-overwrite"]
        if saveLyrics { a += ["--lyrics-file-format", lyricsFormat] } else { a.append("--no-lyrics-file") }
        if !cookiesPath.trimmingCharacters(in: .whitespaces).isEmpty {
            a += ["--auth-mode", "cookies", "--cookies-path", expandedCookiesPath]
        }
        return a + ["--"] + inputs
    }
}

extension ClosedRange where Bound == Int {
    func clamped(_ v: Int) -> Int { Swift.min(Swift.max(v, lowerBound), upperBound) }
}

// MARK: - Persistence

extension DownloadOptions: Codable {
    private enum K: String, CodingKey {
        case outputDir, cookiesPath, songCodec, saveLyrics, lyricsFormat, mvCodec, mvContainer, maxHeight,
             saveCover, coverFormat, savePlaylist, overwrite, artistSelection, concurrentDownloads
    }

    /// Missing or unknown values fall back to defaults instead of failing, so settings survive upgrades.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let d = DownloadOptions()
        func v<T: Decodable>(_ k: K, _ fallback: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? fallback }
        func pick(_ k: K, _ fallback: String, in allowed: [String]) -> String {
            let s: String = v(k, fallback); return allowed.contains(s) ? s : fallback
        }
        outputDir = v(.outputDir, d.outputDir)
        cookiesPath = v(.cookiesPath, d.cookiesPath)
        songCodec = pick(.songCodec, d.songCodec, in: Self.songCodecs)
        saveLyrics = v(.saveLyrics, d.saveLyrics)
        lyricsFormat = pick(.lyricsFormat, d.lyricsFormat, in: Self.lyricsFormats)
        mvCodec = pick(.mvCodec, d.mvCodec, in: Self.mvCodecs)
        mvContainer = pick(.mvContainer, d.mvContainer, in: Self.mvContainers)
        let h: Int = v(.maxHeight, d.maxHeight)
        maxHeight = Self.maxHeights.contains(h) ? h : d.maxHeight
        saveCover = v(.saveCover, d.saveCover)
        coverFormat = pick(.coverFormat, d.coverFormat, in: Self.coverFormats)
        savePlaylist = v(.savePlaylist, d.savePlaylist)
        overwrite = v(.overwrite, d.overwrite)
        artistSelection = pick(.artistSelection, d.artistSelection, in: Self.artistSelections.map(\.value))
        concurrentDownloads = Self.concurrencyRange.clamped(v(.concurrentDownloads, d.concurrentDownloads))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(outputDir, forKey: .outputDir)
        try c.encode(cookiesPath, forKey: .cookiesPath)
        try c.encode(songCodec, forKey: .songCodec)
        try c.encode(saveLyrics, forKey: .saveLyrics)
        try c.encode(lyricsFormat, forKey: .lyricsFormat)
        try c.encode(mvCodec, forKey: .mvCodec)
        try c.encode(mvContainer, forKey: .mvContainer)
        try c.encode(maxHeight, forKey: .maxHeight)
        try c.encode(saveCover, forKey: .saveCover)
        try c.encode(coverFormat, forKey: .coverFormat)
        try c.encode(savePlaylist, forKey: .savePlaylist)
        try c.encode(overwrite, forKey: .overwrite)
        try c.encode(artistSelection, forKey: .artistSelection)
        try c.encode(concurrentDownloads, forKey: .concurrentDownloads)
    }
}

/// Lets SwiftUI's `@AppStorage` hold the whole struct as one JSON string.
extension DownloadOptions: RawRepresentable {
    public init?(rawValue: String) {
        guard let value = try? JSONDecoder().decode(Self.self, from: Data(rawValue.utf8)) else { return nil }
        self = value
    }

    /// Sorted keys make the string deterministic. That matters: for RawRepresentable types, `==` can
    /// resolve to comparing raw values, and unsorted JSON made equal settings compare unequal.
    public var rawValue: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? String(decoding: encoder.encode(self), as: UTF8.self)) ?? "{}"
    }
}
