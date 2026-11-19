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
    /// Off: music-video links are left out and artist links download albums only. gamdl itself can't
    /// skip videos that are part of an album or playlist, so those still download.
    public var downloadMusicVideos = true
    public var folderLayout = FolderLayout.artistAlbum
    public var fileNaming = FileNaming.trackTitle
    /// Used for the parts set to Custom (folders, file names, or both).
    public var customTemplates = PathTemplates()
    /// gamdl's `--truncate`: longest folder or file name in bytes; 0 means no limit beyond gamdl's 255.
    public var maxNameLength = 0

    public init() {}

    public static let songCodecs = ["aac", "aac-he", "aac-binaural", "aac-downmix", "aac-he-binaural",
                                    "aac-he-downmix", "aac-web", "aac-he-web", "atmos", "ac3",
                                    "alac", "alac-lossless", "alac-hires"]
    /// What each codec is, for the picker. Availability still varies by track.
    public static func songCodecLabel(_ codec: String) -> String {
        switch codec {
        case "aac": "AAC 256 kbps"
        case "aac-he": "HE-AAC 64 kbps"
        case "aac-binaural": "AAC binaural"
        case "aac-downmix": "AAC downmix"
        case "aac-he-binaural": "HE-AAC binaural"
        case "aac-he-downmix": "HE-AAC downmix"
        case "aac-web": "AAC (web stream)"
        case "aac-he-web": "HE-AAC (web stream)"
        case "atmos": "Dolby Atmos"
        case "ac3": "Dolby Digital (AC-3)"
        case "alac": "ALAC, best available (Wrapper)"
        case "alac-lossless": "ALAC Lossless (Wrapper)"
        case "alac-hires": "ALAC Hi-Res (Wrapper)"
        default: codec
        }
    }

    /// Apple only grants ALAC keys through gamdl's Wrapper v2 connection; with cookies or a
    /// media user token every ALAC download fails with a DRM license error (checked with gamdl 4.0.2).
    public var songCodecNeedsWrapper: Bool { songCodec.hasPrefix("alac") }

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

    /// Artist choices that make sense with the current music-video setting.
    public var availableArtistSelections: [(value: String, label: String)] {
        downloadMusicVideos ? Self.artistSelections
            : Self.artistSelections.filter { $0.value != "music-videos" && $0.value != "all" }
    }

    /// The `--artist-auto-select` value actually used: video categories fall back to all albums
    /// while music videos are off (the saved choice is kept for when they're turned back on).
    public var effectiveArtistSelection: String {
        availableArtistSelections.contains { $0.value == artistSelection } ? artistSelection : "all-albums"
    }

    /// The validated links/ISRCs to send to gamdl, and how many music-video links were left out.
    public func inputsToDownload(_ valid: [String]) -> (inputs: [String], skippedVideos: Int) {
        guard !downloadMusicVideos else { return (valid, 0) }
        let inputs = valid.filter { !LinkParser.isMusicVideoLink($0) }
        return (inputs, valid.count - inputs.count)
    }
    public static let nameLengthRange = 40...255

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
        return pathIssue
    }

    var truncate: Int? { maxNameLength > 0 ? Self.nameLengthRange.clamped(maxNameLength) : nil }

    /// The output folder and templates gamdl actually gets, after applying the layout and naming choices.
    public var resolvedPaths: (outputDir: String, templates: PathTemplates) {
        let defaults = PathTemplates()
        var t = customTemplates
        if let f = folderLayout.folders {
            (t.albumFolder, t.compilationFolder, t.noAlbumFolder) = f
            t.playlistFolder = defaults.playlistFolder
        }
        if let f = fileNaming.files {
            (t.singleDiscFile, t.multiDiscFile, t.noAlbumFile) = f
            t.playlistFile = defaults.playlistFile
        }
        var dir = expandedOutputDir
        if folderLayout == .flat {
            // gamdl always saves at least one folder below --output-dir. So pass the parent folder and use
            // the output folder's own name as the folder template: everything lands directly in it.
            let url = URL(fileURLWithPath: dir).standardized
            let name = PathTemplate.literal(url.lastPathComponent)
            dir = url.deletingLastPathComponent().path
            (t.albumFolder, t.compilationFolder, t.noAlbumFolder, t.playlistFolder) = (name, name, name, name)
        }
        return (dir, t)
    }

    /// Why the folder/file name settings can't be used, or nil.
    public var pathIssue: String? {
        if folderLayout == .flat {
            let url = URL(fileURLWithPath: expandedOutputDir).standardized
            let name = url.lastPathComponent
            if url.path == "/" { return "“No folders” can't be used with / as the output folder." }
            if PathTemplate.clean(name, directory: true, truncate: truncate) != name {
                return "“No folders” needs an output folder whose name has no : / \\ ? * < > | \" characters, doesn't start or end with a dot, and fits the name length limit."
            }
        }
        for (label, template) in resolvedPaths.templates.labeled {
            if let problem = PathTemplate.problem(in: template) { return "\(label) template: \(problem)" }
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
        var paths = [("Song", path(t.albumFolder, t.singleDiscFile, song, ".m4a")),
                     ("Multi-disc album", path(t.albumFolder, t.multiDiscFile, multi, ".m4a"))]
        if downloadMusicVideos {
            paths.append(("Music video", path(t.noAlbumFolder, t.noAlbumFile, video, "." + mvContainer)))
        }
        if savePlaylist {
            let playlist: [String: PathTemplate.Value] = [
                "playlist_title": .text("Road Trip"), "playlist_artist": .text("Apple Music"), "playlist_track": .number(3)]
            paths.append(("Playlist file", path(t.playlistFolder, t.playlistFile, playlist, ".m3u8")))
        }
        return paths
    }

    /// Arguments for `gamdl`. `inputs` must already be validated links/ISRCs (see `LinkParser`);
    /// they go after `--` so nothing in them can be read as an option.
    public func arguments(inputs: [String]) -> [String] {
        let paths = resolvedPaths
        var a = ["rip", "--no-progress", "--no-tracebacks",
                 "--output-dir", paths.outputDir,
                 "--song-codec", songCodec,
                 "--music-video-codec", mvCodec,
                 "--music-video-container", mvContainer,
                 "--max-height", String(maxHeight),
                 "--cover-format", coverFormat,
                 "--artist-auto-select", effectiveArtistSelection,
                 "--concurrent-downloads", String(Self.concurrencyRange.clamped(concurrentDownloads)),
                 saveCover ? "--save-cover" : "--no-save-cover",
                 savePlaylist ? "--save-playlist" : "--no-save-playlist",
                 overwrite ? "--overwrite" : "--no-overwrite"]
        if saveLyrics { a += ["--lyrics-file-format", lyricsFormat] } else { a.append("--no-lyrics-file") }
        a += paths.templates.arguments
        if let truncate { a += ["--truncate", String(truncate)] }
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
             saveCover, coverFormat, savePlaylist, overwrite, artistSelection, concurrentDownloads, downloadMusicVideos,
             folderLayout, fileNaming, customTemplates, maxNameLength
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
        downloadMusicVideos = v(.downloadMusicVideos, d.downloadMusicVideos)
        concurrentDownloads = Self.concurrencyRange.clamped(v(.concurrentDownloads, d.concurrentDownloads))
        folderLayout = FolderLayout(rawValue: v(.folderLayout, "")) ?? d.folderLayout
        fileNaming = FileNaming(rawValue: v(.fileNaming, "")) ?? d.fileNaming
        customTemplates = v(.customTemplates, d.customTemplates)
        let length: Int = v(.maxNameLength, d.maxNameLength)
        maxNameLength = length > 0 ? Self.nameLengthRange.clamped(length) : 0
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
        try c.encode(downloadMusicVideos, forKey: .downloadMusicVideos)
        try c.encode(concurrentDownloads, forKey: .concurrentDownloads)
        try c.encode(folderLayout.rawValue, forKey: .folderLayout)
        try c.encode(fileNaming.rawValue, forKey: .fileNaming)
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

extension PathTemplates: Codable {
    private enum K: String, CodingKey {
        case albumFolder, compilationFolder, noAlbumFolder, playlistFolder,
             singleDiscFile, multiDiscFile, noAlbumFile, playlistFile
    }

    /// Missing values fall back to gamdl's defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        self.init()
        func v(_ k: K, _ fallback: String) -> String { ((try? c.decodeIfPresent(String.self, forKey: k)) ?? nil) ?? fallback }
        albumFolder = v(.albumFolder, albumFolder)
        compilationFolder = v(.compilationFolder, compilationFolder)
        noAlbumFolder = v(.noAlbumFolder, noAlbumFolder)
        playlistFolder = v(.playlistFolder, playlistFolder)
        singleDiscFile = v(.singleDiscFile, singleDiscFile)
        multiDiscFile = v(.multiDiscFile, multiDiscFile)
        noAlbumFile = v(.noAlbumFile, noAlbumFile)
        playlistFile = v(.playlistFile, playlistFile)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(albumFolder, forKey: .albumFolder)
        try c.encode(compilationFolder, forKey: .compilationFolder)
        try c.encode(noAlbumFolder, forKey: .noAlbumFolder)
        try c.encode(playlistFolder, forKey: .playlistFolder)
        try c.encode(singleDiscFile, forKey: .singleDiscFile)
        try c.encode(multiDiscFile, forKey: .multiDiscFile)
        try c.encode(noAlbumFile, forKey: .noAlbumFile)
        try c.encode(playlistFile, forKey: .playlistFile)
    }
}
