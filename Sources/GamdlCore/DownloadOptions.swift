import Foundation

/// Everything the user can set in the app, turned into a `gamdl rip` command line.
/// Stored in UserDefaults as JSON (see `RawRepresentable`), so adding a field later keeps old settings.
public struct DownloadOptions: Equatable, Sendable {
    public var outputDir = "~/Music/gamdl"
    public var cookiesPath = ""
    public var songCodec = SongCodec.aac
    public var saveLyrics = true
    public var lyricsFormat = LyricsFormat.lrc
    public var mvCodec = MusicVideoCodec.h264
    public var mvContainer = MusicVideoContainer.m4v
    public var maxHeight = 1080
    public var saveCover = false
    public var coverFormat = CoverFormat.jpg
    public var savePlaylist = false
    public var overwrite = false
    public var artistSelection = ArtistSelection.allAlbums
    public var concurrentDownloads = 2
    /// Off: music-video links are left out and artist links download albums only. gamdl itself can't
    /// skip videos that are part of an album or playlist, so those still download.
    public var downloadMusicVideos = true
    public var folderLayout = FolderLayout.artistAlbum {
        didSet { FolderLayout.seedCustom(&customTemplates, from: oldValue, to: folderLayout) }
    }
    public var fileNaming = FileNaming.trackTitle {
        didSet { FileNaming.seedCustom(&customTemplates, from: oldValue, to: fileNaming) }
    }
    /// Used for the parts set to Custom (folders, file names, or both).
    public var customTemplates = PathTemplates()
    /// gamdl's `--truncate`: longest folder or file name in bytes; 0 means no limit beyond gamdl's 255.
    public var maxNameLength = 0

    public init() {}

    // Limits are enforced when settings are loaded; the Options controls stay within them.
    public static let maxHeights = [480, 720, 1080, 1440, 2160]
    public static let concurrencyRange = 1...8
    public static let nameLengthRange = 40...255
    /// Where "Limit name length" starts when it's turned on.
    public static let suggestedNameLength = 120

    public var availableArtistSelections: [ArtistSelection] {
        ArtistSelection.allCases.filter { downloadMusicVideos || !$0.includesMusicVideos }
    }

    /// The `--artist-auto-select` value actually used: video categories fall back to all albums
    /// while music videos are off (the saved choice is kept for when they're turned back on).
    public var effectiveArtistSelection: ArtistSelection {
        availableArtistSelections.contains(artistSelection) ? artistSelection : .allAlbums
    }

    public func inputsToDownload(_ valid: [String]) -> (inputs: [String], skippedVideos: Int) {
        guard !downloadMusicVideos else { return (valid, 0) }
        let inputs = valid.filter { !LinkParser.isMusicVideoLink($0) }
        return (inputs, valid.count - inputs.count)
    }
    public var expandedOutputDir: String { Self.expand(outputDir) }
    /// The cookies file to sign in with, or nil to use gamdl's saved sign-in.
    public var cookiesFile: String? {
        cookiesPath.trimmingCharacters(in: .whitespaces).isEmpty ? nil : Self.expand(cookiesPath)
    }

    public static func expand(_ path: String) -> String {
        (path.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
    }

    public func blockingIssue(fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        if outputDir.trimmingCharacters(in: .whitespaces).isEmpty { return "Choose an output folder." }
        if cookiesFileIsMissing(fileExists: fileExists) { return "The cookies file doesn't exist." }
        return pathIssue
    }

    /// gamdl will sign in through Wrapper (the only sign-in Apple grants ALAC keys to): it's the
    /// saved sign-in and no cookies file overrides it.
    public func usesWrapper(savedAuth: SavedAuth?) -> Bool { cookiesFile == nil && savedAuth?.isWrapper == true }

    public func cookiesFileIsMissing(fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Bool {
        cookiesFile.map { !fileExists($0) } ?? false
    }

    var truncate: Int? { maxNameLength > 0 ? maxNameLength : nil }

    /// For "No folders": gamdl always saves at least one folder below --output-dir, so it gets the
    /// output folder's parent, and the output folder's own name as the folder template.
    private var flatTarget: (parent: String, name: String, isRoot: Bool)? {
        guard folderLayout == .flat else { return nil }
        let url = URL(fileURLWithPath: expandedOutputDir).standardized
        return (url.deletingLastPathComponent().path, url.lastPathComponent, url.path == "/")
    }

    var resolvedPaths: (outputDir: String, templates: PathTemplates) {
        var t = PathTemplates()
        fileNaming.apply(to: &t, custom: customTemplates)
        guard let flat = flatTarget else {
            folderLayout.apply(to: &t, custom: customTemplates)
            return (expandedOutputDir, t)
        }
        for slot in PathTemplates.Slot.folders { t[slot] = PathTemplate.literal(flat.name) }
        return (flat.parent, t)
    }

    public var pathIssue: String? {
        if let flat = flatTarget {
            if flat.isRoot { return "“No folders” can't be used with / as the output folder." }
            if PathTemplate.clean(flat.name, directory: true, truncate: truncate) != flat.name {
                return "“No folders” needs an output folder whose name has no : / \\ ? * < > | \" characters, doesn't start or end with a dot, and fits the name length limit."
            }
        }
        let templates = resolvedPaths.templates
        for slot in PathTemplates.Slot.allCases {
            if let problem = PathTemplate.problem(in: templates[slot]) { return "\(slot.title): \(problem)" }
        }
        return nil
    }

    /// Example paths for the current settings, rendered the way gamdl would.
    public func previewPaths() -> [(label: String, path: String)] {
        let (dir, t) = resolvedPaths
        let base = (dir as NSString).abbreviatingWithTildeInPath
        func path(_ folder: String, _ file: String, _ values: [String: PathTemplate.Value], _ ext: String) -> String {
            guard let folders = PathTemplate.render(folder, values: values, truncate: truncate),
                  let files = PathTemplate.render(file, values: values, fileExtension: ext, truncate: truncate)
            else { return "—" }
            return ([base] + folders + files).joined(separator: "/")
        }
        let song: [String: PathTemplate.Value] = [
            "album": .text("Abbey Road"), "album_artist": .text("The Beatles"), "artist": .text("The Beatles"),
            "title": .text("Come Together"), "track": .number(1), "track_total": .number(17),
            "disc": .number(1), "disc_total": .number(1), "date": .date("1969-09-26"),
            "composer": .text("John Lennon"), "media_type": .text("Song")]
        var multi = song
        (multi["album"], multi["title"], multi["track"], multi["disc"], multi["disc_total"], multi["date"]) =
            (.text("The Beatles (White Album)"), .text("Birthday"), .number(1), .number(2), .number(2), .date("1968-11-22"))
        let video: [String: PathTemplate.Value] = [
            "artist": .text("The Beatles"), "title": .text("Something"), "date": .date("1969-10-06"),
            "media_type": .text("Music Video")]
        var paths = [("Song", path(t[.albumFolder], t[.singleDiscFile], song, ".m4a")),
                     ("Multi-disc album", path(t[.albumFolder], t[.multiDiscFile], multi, ".m4a"))]
        if downloadMusicVideos {
            paths.append(("Music video", path(t[.noAlbumFolder], t[.noAlbumFile], video, "." + mvContainer.rawValue)))
        }
        if savePlaylist {
            let playlist: [String: PathTemplate.Value] = [
                "playlist_title": .text("Road Trip"), "playlist_artist": .text("Apple Music"), "playlist_track": .number(3)]
            paths.append(("Playlist file", path(t[.playlistFolder], t[.playlistFile], playlist, ".m3u8")))
        }
        return paths
    }

    /// Arguments for `gamdl`. `inputs` must already be validated links/ISRCs (see `LinkParser`);
    /// they go after `--` so nothing in them can be read as an option. Music-video links are left out
    /// while music videos are off.
    public func arguments(inputs: [String]) -> [String] {
        let paths = resolvedPaths
        var a = ["rip", "--no-progress", "--no-tracebacks",
                 "--output-dir", paths.outputDir,
                 "--song-codec", songCodec.rawValue,
                 "--music-video-codec", mvCodec.rawValue,
                 "--music-video-container", mvContainer.rawValue,
                 "--max-height", String(maxHeight),
                 "--cover-format", coverFormat.rawValue,
                 "--artist-auto-select", effectiveArtistSelection.rawValue,
                 "--concurrent-downloads", String(concurrentDownloads),
                 saveCover ? "--save-cover" : "--no-save-cover",
                 savePlaylist ? "--save-playlist" : "--no-save-playlist",
                 overwrite ? "--overwrite" : "--no-overwrite"]
        if saveLyrics { a += ["--lyrics-file-format", lyricsFormat.rawValue] } else { a.append("--no-lyrics-file") }
        a += paths.templates.arguments
        if let truncate { a += ["--truncate", String(truncate)] }
        if let cookiesFile { a += ["--auth-mode", "cookies", "--cookies-path", cookiesFile] }
        return a + ["--"] + inputsToDownload(inputs).inputs
    }
}

extension ClosedRange where Bound == Int {
    func clamped(_ v: Int) -> Int { Swift.min(Swift.max(v, lowerBound), upperBound) }
}

// MARK: - Persistence

// Explicit keys and `encode`: as a RawRepresentable type, DownloadOptions would otherwise get the
// standard library's rawValue-based encoding, which calls back into `rawValue` forever.
extension DownloadOptions: Codable {
    private enum CodingKeys: String, CodingKey {
        case outputDir, cookiesPath, songCodec, saveLyrics, lyricsFormat, mvCodec, mvContainer, maxHeight,
             saveCover, coverFormat, savePlaylist, overwrite, artistSelection, concurrentDownloads, downloadMusicVideos,
             folderLayout, fileNaming, customTemplates, maxNameLength
    }

    /// Missing or unknown values fall back to defaults instead of failing, so settings survive upgrades.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DownloadOptions()
        func v<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? fallback }
        outputDir = v(.outputDir, d.outputDir)
        cookiesPath = v(.cookiesPath, d.cookiesPath)
        songCodec = v(.songCodec, d.songCodec)
        saveLyrics = v(.saveLyrics, d.saveLyrics)
        lyricsFormat = v(.lyricsFormat, d.lyricsFormat)
        mvCodec = v(.mvCodec, d.mvCodec)
        mvContainer = v(.mvContainer, d.mvContainer)
        let h: Int = v(.maxHeight, d.maxHeight)
        maxHeight = Self.maxHeights.contains(h) ? h : d.maxHeight
        saveCover = v(.saveCover, d.saveCover)
        coverFormat = v(.coverFormat, d.coverFormat)
        savePlaylist = v(.savePlaylist, d.savePlaylist)
        overwrite = v(.overwrite, d.overwrite)
        artistSelection = v(.artistSelection, d.artistSelection)
        downloadMusicVideos = v(.downloadMusicVideos, d.downloadMusicVideos)
        concurrentDownloads = Self.concurrencyRange.clamped(v(.concurrentDownloads, d.concurrentDownloads))
        folderLayout = v(.folderLayout, d.folderLayout)
        fileNaming = v(.fileNaming, d.fileNaming)
        customTemplates = v(.customTemplates, d.customTemplates)
        let length: Int = v(.maxNameLength, d.maxNameLength)
        maxNameLength = length > 0 ? Self.nameLengthRange.clamped(length) : 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
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
        try c.encode(downloadMusicVideos, forKey: .downloadMusicVideos)
        try c.encode(folderLayout, forKey: .folderLayout)
        try c.encode(fileNaming, forKey: .fileNaming)
        try c.encode(customTemplates, forKey: .customTemplates)
        try c.encode(maxNameLength, forKey: .maxNameLength)
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

// MARK: - Values gamdl accepts (raw values are gamdl's spelling)

public enum SongCodec: String, CaseIterable, Codable, Sendable {
    case aac, aacHe = "aac-he", aacBinaural = "aac-binaural", aacDownmix = "aac-downmix",
         aacHeBinaural = "aac-he-binaural", aacHeDownmix = "aac-he-downmix", aacWeb = "aac-web",
         aacHeWeb = "aac-he-web", atmos, ac3, alac, alacLossless = "alac-lossless", alacHires = "alac-hires"

    /// What each codec is, for the picker. Availability still varies by track.
    public var label: String {
        switch self {
        case .aac: "AAC 256 kbps"
        case .aacHe: "HE-AAC 64 kbps"
        case .aacBinaural: "AAC binaural"
        case .aacDownmix: "AAC downmix"
        case .aacHeBinaural: "HE-AAC binaural"
        case .aacHeDownmix: "HE-AAC downmix"
        case .aacWeb: "AAC (web stream)"
        case .aacHeWeb: "HE-AAC (web stream)"
        case .atmos: "Dolby Atmos"
        case .ac3: "Dolby Digital (AC-3)"
        case .alac: "ALAC, best available (Wrapper)"
        case .alacLossless: "ALAC Lossless (Wrapper)"
        case .alacHires: "ALAC Hi-Res (Wrapper)"
        }
    }

    /// Apple only grants ALAC keys through gamdl's Wrapper v2 connection; with cookies or a
    /// media user token every ALAC download fails with a DRM license error (checked with gamdl 4.0.2).
    public var needsWrapper: Bool {
        switch self {
        case .alac, .alacLossless, .alacHires: true
        default: false
        }
    }
}

public enum LyricsFormat: String, CaseIterable, Codable, Sendable {
    case lrc, enhancedLrc = "enhanced-lrc", srt, ttml, enhancedTtml = "enhanced-ttml", text
}

public enum MusicVideoCodec: String, CaseIterable, Codable, Sendable { case h264, h265 }
public enum MusicVideoContainer: String, CaseIterable, Codable, Sendable { case m4v, mp4 }
public enum CoverFormat: String, CaseIterable, Codable, Sendable { case jpg, png }

/// gamdl's `--artist-auto-select` values. Without one, an artist link opens an
/// interactive menu, which can't work because the app gives gamdl no terminal.
public enum ArtistSelection: String, CaseIterable, Codable, Sendable {
    case allAlbums = "all-albums", mainAlbums = "main-albums", singlesEps = "singles-eps",
         liveAlbums = "live-albums", compilationAlbums = "compilation-albums", topSongs = "top-songs",
         musicVideos = "music-videos", all

    public var label: String {
        switch self {
        case .allAlbums: "All albums"
        case .mainAlbums: "Main albums"
        case .singlesEps: "Singles & EPs"
        case .liveAlbums: "Live albums"
        case .compilationAlbums: "Compilations"
        case .topSongs: "Top songs"
        case .musicVideos: "Music videos"
        case .all: "All albums + music videos"
        }
    }

    public var includesMusicVideos: Bool { self == .musicVideos || self == .all }
}

extension FolderLayout: Codable {}
extension FileNaming: Codable {}
