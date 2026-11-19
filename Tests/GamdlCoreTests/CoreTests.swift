import Foundation
import Testing
@testable import GamdlCore

@Suite struct LinkParserTests {
    @Test func acceptsAppleMusicLinksAndISRCs() {
        let r = LinkParser.parse("""
        https://music.apple.com/us/album/abbey-road/1441164426
          https://beta.music.apple.com/us/playlist/x/pl.123\thttps://music.apple.com/us/artist/x/1
        usum71703861
        """)
        #expect(r.valid == ["https://music.apple.com/us/album/abbey-road/1441164426",
                            "https://beta.music.apple.com/us/playlist/x/pl.123",
                            "https://music.apple.com/us/artist/x/1",
                            "USUM71703861"])
        #expect(r.invalid.isEmpty)
    }

    @Test func addsMissingSchemeAndTrimsWrapping() {
        let r = LinkParser.parse("music.apple.com/us/song/x/123 <https://music.apple.com/us/album/y/9>, (https://music.apple.com/us/song/z/1)")
        #expect(r.valid == ["https://music.apple.com/us/song/x/123", "https://music.apple.com/us/album/y/9",
                            "https://music.apple.com/us/song/z/1"])
    }

    @Test func rejectsOtherHostsOptionsAndJunk() {
        let r = LinkParser.parse("""
        https://example.com/album/1 --config=/tmp/evil.yml -v https://music.apple.com.evil.com/us/album/1
        https://music.apple.com ftp://music.apple.com/us/album/1 hello https://notmusic.apple.com/x
        """)
        #expect(r.valid.isEmpty)
        #expect(r.invalid.count == 8)
    }

    @Test func removesDuplicates() {
        let r = LinkParser.parse("https://music.apple.com/us/album/a/1\nhttps://music.apple.com/us/album/a/1 music.apple.com/us/album/a/1")
        #expect(r.valid == ["https://music.apple.com/us/album/a/1"])
        #expect(r.duplicates == 2)
    }

    @Test func emptyInput() {
        #expect(LinkParser.parse("  \n\t ") == LinkParser.Result())
    }
}

@Suite struct DownloadOptionsTests {
    @Test func defaultArguments() {
        var o = DownloadOptions()
        o.outputDir = "/tmp/out dir"
        let args = o.arguments(inputs: ["https://music.apple.com/us/album/a/1"])
        #expect(args == ["rip", "--no-progress", "--no-tracebacks", "--output-dir", "/tmp/out dir",
                         "--song-codec", "aac", "--music-video-codec", "h264", "--music-video-container", "m4v",
                         "--max-height", "1080", "--cover-format", "jpg", "--artist-auto-select", "all-albums",
                         "--concurrent-downloads", "2", "--no-save-cover", "--no-save-playlist", "--no-overwrite",
                         "--lyrics-file-format", "lrc",
                         "--album-folder-template", "{album_artist}/{album}",
                         "--compilation-folder-template", "Compilations/{album}",
                         "--no-album-folder-template", "{artist}/Unknown Album",
                         "--playlist-folder-template", "Playlists/{playlist_artist}",
                         "--single-disc-file-template", "{track:02d} {title}",
                         "--multi-disc-file-template", "{disc}-{track:02d} {title}",
                         "--no-album-file-template", "{title}",
                         "--playlist-file-template", "{playlist_title}",
                         "--", "https://music.apple.com/us/album/a/1"])
    }

    @Test func customArgumentsExpandTildeAndAddCookies() {
        var o = DownloadOptions()
        o.outputDir = "~/Music/x"
        o.cookiesPath = " ~/cookies.txt "
        o.saveLyrics = false
        o.saveCover = true
        o.savePlaylist = true
        o.overwrite = true
        o.concurrentDownloads = 99
        let args = o.arguments(inputs: ["USUM71703861"])
        let home = NSHomeDirectory()
        #expect(args.contains("\(home)/Music/x"))
        #expect(args.contains("--no-lyrics-file") && !args.contains("--lyrics-file-format"))
        #expect(args.contains("--save-cover") && args.contains("--save-playlist") && args.contains("--overwrite"))
        #expect(Array(args.suffix(6)) == ["--auth-mode", "cookies", "--cookies-path", "\(home)/cookies.txt", "--", "USUM71703861"])
        let i = args.firstIndex(of: "--concurrent-downloads")!
        #expect(args[i + 1] == "8")
    }

    @Test func blockingIssues() {
        var o = DownloadOptions()
        #expect(o.blockingIssue(fileExists: { _ in false }) == nil)
        o.cookiesPath = "/nope/cookies.txt"
        #expect(o.blockingIssue(fileExists: { _ in false }) == "The cookies file doesn't exist.")
        #expect(o.blockingIssue(fileExists: { $0 == "/nope/cookies.txt" }) == nil)
        o.outputDir = "  "
        #expect(o.blockingIssue(fileExists: { _ in true }) == "Choose an output folder.")
    }

    @Test func persistenceRoundTripAndForwardCompatibility() {
        var o = DownloadOptions()
        o.songCodec = "alac"
        o.maxHeight = 2160
        o.artistSelection = "top-songs"
        #expect(DownloadOptions(rawValue: o.rawValue) == o)

        // Older settings without newer keys, plus values gamdl no longer accepts, fall back to defaults.
        let legacy = DownloadOptions(rawValue: #"{"songCodec":"atmos","maxHeight":123,"coverFormat":"gif","overwrite":true}"#)!
        #expect(legacy.songCodec == "atmos")
        #expect(legacy.maxHeight == 1080)
        #expect(legacy.coverFormat == "jpg")
        #expect(legacy.overwrite)
        #expect(legacy.artistSelection == "all-albums")
        #expect(DownloadOptions(rawValue: "not json") == nil)
    }
}

@Suite struct OutputParsingTests {
    @Test func splitterKeepsMultibyteCharactersSplitAcrossReads() {
        let s = LineSplitter()
        let bytes = Array("✓ Café: downloaded\n✗ x".utf8)
        var lines: [String] = []
        for b in bytes { lines += s.feed(Data([b])) } // worst case: one byte per read
        lines += s.finish()
        #expect(lines == ["✓ Café: downloaded", "✗ x"])
    }

    @Test func splitterHandlesCRLFAndCarriageReturnRedraws() {
        let s = LineSplitter()
        var lines = s.feed(Data("a\r\nb\r".utf8))
        lines += s.feed(Data("\nprogress 10%\rprogress 90%\rdone\n".utf8))
        lines += s.feed(Data("tail\r".utf8))
        lines += s.finish()
        #expect(lines == ["a", "b", "done", "tail"])
        #expect(s.finish().isEmpty)
    }

    @Test func stripsTerminalEscapes() {
        #expect(TerminalText.strip("\u{1B}[1;31mError\u{1B}[0m \u{1B}]8;;https://x\u{07}link\u{1B}]8;;\u{07}\u{1B}7") == "Error link")
        #expect(TerminalText.strip("plain") == "plain")
    }

    @Test func parsesSavedItemWithColonsInTitleAndPath() {
        #expect(OutputEvent.parse("✓ Song: Part 2: downloaded → /Music/A: B/01 Song.m4a")
            == OutputEvent(kind: .saved, title: "Song: Part 2", detail: "downloaded", path: "/Music/A: B/01 Song.m4a"))
        #expect(OutputEvent.parse("✓ Track: overwritten")
            == OutputEvent(kind: .saved, title: "Track", detail: "overwritten"))
    }

    @Test func parsesSkippedPartialAndFailed() {
        #expect(OutputEvent.parse("↷ Song: skipped (already exists) → /x.m4a")
            == OutputEvent(kind: .skipped, title: "Song", detail: "already exists", path: "/x.m4a"))
        #expect(OutputEvent.parse("↷ Song: skipped")
            == OutputEvent(kind: .skipped, title: "Song", detail: "skipped"))
        #expect(OutputEvent.parse("✓ Song: media saved (finalization incomplete) → /y.m4a")?.kind == .partial)
        #expect(OutputEvent.parse("  ✗ Session: Authentication failed (check cookies or wrapper login)")
            == OutputEvent(kind: .failed, title: "Session", detail: "Authentication failed (check cookies or wrapper login)"))
    }

    @Test func ignoresOtherLines() {
        for line in ["Gamdl 4.0.2", "", "Errors (1):", "Finished: 1 downloaded, 0 overwritten", "! warning", "✓"] {
            #expect(OutputEvent.parse(line) == nil)
        }
    }

    @Test func detectsSignInProblems() {
        #expect(OutputEvent.indicatesSignInProblem("  ✗ Session: Authentication setup requires an interactive terminal"))
        #expect(OutputEvent.indicatesSignInProblem("✗ Session: Authentication failed (check cookies or wrapper login)"))
        #expect(!OutputEvent.indicatesSignInProblem("✓ Authentication Song: downloaded"))
    }
}

@Suite struct SavedAuthTests {
    static let sample = """
    config_version: 1
    auth:
      mode: %@
      cookies_path: /Users/x/.gamdl/cookies.txt
      media_user_token: '[REDACTED]'
    download:
      overwrite: false
      mode: not-this-one
    """

    @Test func readsSavedMode() {
        #expect(SavedAuth.parse(configShow: Self.sample.replacingOccurrences(of: "%@", with: "cookies")) == .mode("cookies"))
        #expect(SavedAuth.parse(configShow: Self.sample.replacingOccurrences(of: "%@", with: "'media-user-token'")) == .mode("media-user-token"))
    }

    @Test func nullMeansNotSignedIn() {
        #expect(SavedAuth.parse(configShow: Self.sample.replacingOccurrences(of: "%@", with: "null")) == SavedAuth.none)
    }

    @Test func unreadableOutputIsNil() {
        #expect(SavedAuth.parse(configShow: "Gamdl 4.0.2\n\nError: invalid config") == nil)
        #expect(SavedAuth.parse(configShow: "download:\n  mode: cookies\n") == nil)
    }
}

/// Expected paths come from gamdl 4.0.2's own PathFormatter (gamdl/download/paths.py) rendering the
/// same templates and tags, so the app's preview and validation match what gamdl does.
@Suite struct PathTemplateTests {
    func options(_ layout: FolderLayout, _ naming: FileNaming, dir: String = "/OUT",
                 custom: PathTemplates = PathTemplates(), truncate: Int = 0) -> DownloadOptions {
        var o = DownloadOptions()
        o.outputDir = dir
        o.folderLayout = layout
        o.fileNaming = naming
        o.customTemplates = custom
        o.maxNameLength = truncate
        o.savePlaylist = true
        return o
    }

    func preview(_ o: DownloadOptions) -> [String] { o.previewPaths().map(\.path) }

    @Test func defaultMatchesGamdlDefaults() {
        let o = options(.artistAlbum, .trackTitle)
        #expect(o.resolvedPaths.templates == PathTemplates())
        #expect(preview(o) == ["/OUT/The Beatles/Abbey Road/01 Come Together.m4a",
                               "/OUT/The Beatles/The Beatles (White Album)/2-01 Birthday.m4a",
                               "/OUT/The Beatles/Unknown Album/Something.m4v",
                               "/OUT/Playlists/Apple Music/Road Trip.m3u8"])
    }

    @Test func presets() {
        #expect(preview(options(.artistYearAlbum, .trackTitle)).prefix(2) == [
            "/OUT/The Beatles/1969 - Abbey Road/01 Come Together.m4a",
            "/OUT/The Beatles/1968 - The Beatles (White Album)/2-01 Birthday.m4a"])
        #expect(preview(options(.artistDashAlbum, .artistTitle)) == [
            "/OUT/The Beatles - Abbey Road/The Beatles - Come Together.m4a",
            "/OUT/The Beatles - The Beatles (White Album)/The Beatles - Birthday.m4a",
            "/OUT/The Beatles - Unknown Album/The Beatles - Something.m4v",
            "/OUT/Playlists/Apple Music/Road Trip.m3u8"])
        #expect(preview(options(.albumOnly, .trackArtistTitle)).prefix(3) == [
            "/OUT/Abbey Road/01 The Beatles - Come Together.m4a",
            "/OUT/The Beatles (White Album)/2-01 The Beatles - Birthday.m4a",
            "/OUT/Unknown Album/The Beatles - Something.m4v"])
    }

    @Test func flatPutsEverythingInTheOutputFolder() {
        let o = options(.flat, .trackTitle, dir: "/OUT/gamdl")
        #expect(preview(o) == ["/OUT/gamdl/01 Come Together.m4a", "/OUT/gamdl/2-01 Birthday.m4a",
                               "/OUT/gamdl/Something.m4v", "/OUT/gamdl/Road Trip.m3u8"])
        let args = o.arguments(inputs: ["x"])
        let i = args.firstIndex(of: "--output-dir")!
        #expect(args[i + 1] == "/OUT")
        #expect(args[args.firstIndex(of: "--album-folder-template")! + 1] == "gamdl")
        #expect(o.pathIssue == nil)
        // Braces in the folder name are escaped so gamdl renders them literally.
        #expect(options(.flat, .title, dir: "/OUT/my {music}").resolvedPaths.templates.albumFolder == "my {{music}}")
    }

    @Test func flatRejectsFolderNamesGamdlWouldChange() {
        #expect(options(.flat, .title, dir: "/").pathIssue != nil)
        #expect(options(.flat, .title, dir: "/OUT/.hidden").pathIssue != nil)
        #expect(options(.flat, .title, dir: "/OUT/a:b").pathIssue != nil)
        #expect(options(.flat, .title, dir: "/OUT/" + String(repeating: "x", count: 60), truncate: 40).pathIssue != nil)
        #expect(options(.flat, .title, dir: "~/Music/gamdl").pathIssue == nil)
    }

    @Test func customTemplatesWithFormatSpecs() {
        var c = PathTemplates()
        c.albumFolder = "{album_artist:.3}/{date:%y-%m}"
        c.singleDiscFile = "{track:3} {title} [{track_total}] {composer}"
        c.multiDiscFile = "{disc:02d}.{track} {title:>5}"
        #expect(preview(options(.custom, .custom, custom: c)) == [
            "/OUT/The/69-09/1 Come Together [17] John Lennon.m4a",
            "/OUT/The/68-11/02.1 Birthday.m4a",
            "/OUT/The Beatles/Unknown Album/Something.m4v",
            "/OUT/Playlists/Apple Music/Road Trip.m3u8"])
    }

    @Test func cleansNamesLikeGamdl() {
        var c = PathTemplates()
        c.albumFolder = ".hidden/A: B {{x}}"
        c.singleDiscFile = "{title}."
        #expect(preview(options(.custom, .custom, custom: c)).prefix(2) == [
            "/OUT/_hidden/A_ B {x}/Come Together_.m4a", "/OUT/_hidden/A_ B {x}/2-01 Birthday.m4a"])
    }

    @Test func truncatesNamesIncludingExtension() {
        var c = PathTemplates()
        c.singleDiscFile = "{track:02d} {title} {title} {title}"
        let o = options(.artistAlbum, .custom, custom: c, truncate: 40)
        #expect(o.arguments(inputs: []).contains("--truncate"))
        // gamdl with --truncate 20 gave these; 20 is below the app's minimum of 40, so render directly.
        #expect(PathTemplate.render(c.singleDiscFile, values: ["track": .number(1), "title": .text("Come Together")],
                                    fileExtension: ".m4a", truncate: 20) == ["01 Come Together.m4a"])
        #expect(PathTemplate.render("{album}", values: ["album": .text("The Beatles (White Album)")], truncate: 20)
                == ["The Beatles (White A"])
    }

    @Test func rejectsTemplatesGamdlRejects() {
        #expect(PathTemplate.problem(in: "{foo}") != nil)          // unknown field
        #expect(PathTemplate.problem(in: "{album}//x") != nil)     // empty component
        #expect(PathTemplate.problem(in: "{title!r}") != nil)      // conversion
        #expect(PathTemplate.problem(in: "{album") != nil)
        #expect(PathTemplate.problem(in: "a}b") != nil)
        #expect(PathTemplate.problem(in: "{}") != nil)
        #expect(PathTemplate.problem(in: "{album:{x}}") != nil)
        #expect(PathTemplate.problem(in: "/abs/{album}") != nil)
        #expect(PathTemplate.problem(in: "") != nil)
        #expect(PathTemplate.problem(in: "{album_artist}/{date:%Y} - {album} {{live}}") == nil)
        var c = PathTemplates()
        c.multiDiscFile = "{disc}-{nope}"
        #expect(options(.artistAlbum, .custom, custom: c).pathIssue == "Multi-disc file template: {nope} isn't a field gamdl knows.")
        // A broken custom folder template doesn't matter while a preset is selected for folders.
        c = PathTemplates(); c.albumFolder = "{bad}"
        #expect(options(.artistAlbum, .trackTitle, custom: c).pathIssue == nil)
    }

    @Test func templatesAreAlwaysPassedToGamdl() {
        let args = DownloadOptions().arguments(inputs: ["x"])
        for flag in PathTemplates().arguments where flag.hasPrefix("--") { #expect(args.contains(flag)) }
        #expect(!args.contains("--truncate"))
        #expect(args.last == "x" && args[args.count - 2] == "--")
    }

    @Test func persistsLayoutChoices() {
        var o = DownloadOptions()
        o.folderLayout = .custom
        o.fileNaming = .artistTitle
        o.customTemplates.albumFolder = "{artist}/{album}"
        o.maxNameLength = 120
        #expect(DownloadOptions(rawValue: o.rawValue) == o)
        let old = DownloadOptions(rawValue: #"{"folderLayout":"bogus","maxNameLength":7,"customTemplates":{"albumFolder":"X"}}"#)!
        #expect(old.folderLayout == .artistAlbum)
        #expect(old.maxNameLength == 40)
        #expect(old.customTemplates.albumFolder == "X" && old.customTemplates.singleDiscFile == "{track:02d} {title}")
    }
}
