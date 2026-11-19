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
        let args = o.arguments(inputs: ["USUM71703861"])
        let home = NSHomeDirectory()
        #expect(args.contains("\(home)/Music/x"))
        #expect(args.contains("--no-lyrics-file") && !args.contains("--lyrics-file-format"))
        #expect(args.contains("--save-cover") && args.contains("--save-playlist") && args.contains("--overwrite"))
        #expect(Array(args.suffix(6)) == ["--auth-mode", "cookies", "--cookies-path", "\(home)/cookies.txt", "--", "USUM71703861"])
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

    /// Every stored setting, as text, by name. DownloadOptions' `==` compares encoded JSON, so it
    /// can't see a setting that encoding leaves out.
    static func fields(_ o: DownloadOptions) -> [String: String] {
        Dictionary(uniqueKeysWithValues: Mirror(reflecting: o).children.map { child in
            let text = (child.value as? PathTemplates).map { t in "\(PathTemplates.Slot.allCases.map { t[$0] })" }
            return (child.label!, text ?? "\(child.value)")
        })
    }

    @Test func everySettingSurvivesARoundTrip() {
        var o = DownloadOptions()
        o.outputDir = "/x"; o.cookiesPath = "/c.txt"; o.songCodec = .alac; o.saveLyrics = false
        o.lyricsFormat = .ttml; o.mvCodec = .h265; o.mvContainer = .mp4; o.maxHeight = 2160
        o.saveCover = true; o.coverFormat = .png; o.savePlaylist = true; o.overwrite = true
        o.artistSelection = .topSongs; o.concurrentDownloads = 5; o.downloadMusicVideos = false
        o.folderLayout = .flat; o.fileNaming = .custom; o.customTemplates[.playlistFile] = "{playlist_title} x"
        o.maxNameLength = 120
        let defaults = Self.fields(DownloadOptions())
        // A new setting must be added here (and to DownloadOptions' CodingKeys).
        for (name, value) in Self.fields(o) { #expect(value != defaults[name], "\(name) still has its default") }
        #expect(Self.fields(DownloadOptions(rawValue: o.rawValue)!) == Self.fields(o))
    }

    @Test func oldOrInvalidSettingsFallBackToDefaults() {
        let old = DownloadOptions(rawValue: #"""
            {"songCodec":"atmos","maxHeight":123,"coverFormat":"gif","overwrite":true,"concurrentDownloads":99,
             "folderLayout":"bogus","maxNameLength":7,"customTemplates":{"albumFolder":"X"}}
            """#)!
        #expect(old.songCodec == .atmos && old.overwrite)
        #expect(old.maxHeight == 1080 && old.coverFormat == .jpg && old.folderLayout == .artistAlbum)
        #expect(old.concurrentDownloads == 8 && old.maxNameLength == 40)
        #expect(old.customTemplates[.albumFolder] == "X" && old.customTemplates[.singleDiscFile] == "{track:02d} {title}")
        #expect(Self.fields(DownloadOptions(rawValue: "{}")!) == Self.fields(DownloadOptions()))
        #expect(DownloadOptions(rawValue: "not json") == nil)
    }

    @Test func aCookiesFileOverridesTheSavedWrapperSignIn() {
        var o = DownloadOptions()
        #expect(o.usesWrapper(savedAuth: .mode("wrapper")))
        #expect(!o.usesWrapper(savedAuth: .mode("cookies")) && !o.usesWrapper(savedAuth: nil))
        o.cookiesPath = "~/cookies.txt"
        #expect(!o.usesWrapper(savedAuth: .mode("wrapper")))
    }

    @Test func shellQuotingOnlyWhereNeeded() {
        #expect(Shell.quoted("/usr/bin/gamdl") == "/usr/bin/gamdl")
        #expect(Shell.quoted("a b") == "'a b'")
        #expect(Shell.quoted("it's") == #"'it'\''s'"#)
        #expect(Shell.quoted("") == "''")
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
        #expect(RunIssue.detect(in: "  ✗ Session: Authentication setup requires an interactive terminal", songCodec: .aac) == .signInRejected)
        #expect(RunIssue.detect(in: "✗ Session: Authentication failed (check cookies or wrapper login)", songCodec: .aac) == .signInRejected)
        #expect(RunIssue.detect(in: "✓ Authentication Song: downloaded", songCodec: .aac) == nil)
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
        #expect(options(.flat, .title, dir: "/OUT/my {music}").resolvedPaths.templates[.albumFolder] == "my {{music}}")
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
        c[.albumFolder] = "{album_artist:.3}/{date:%y-%m}"
        c[.singleDiscFile] = "{track:3} {title} [{track_total}] {composer}"
        c[.multiDiscFile] = "{disc:02d}.{track} {title:>5}"
        #expect(preview(options(.custom, .custom, custom: c)) == [
            "/OUT/The/69-09/1 Come Together [17] John Lennon.m4a",
            "/OUT/The/68-11/02.1 Birthday.m4a",
            "/OUT/The Beatles/Unknown Album/Something.m4v",
            "/OUT/Playlists/Apple Music/Road Trip.m3u8"])
    }

    @Test func cleansNamesLikeGamdl() {
        var c = PathTemplates()
        c[.albumFolder] = ".hidden/A: B {{x}}"
        c[.singleDiscFile] = "{title}."
        #expect(preview(options(.custom, .custom, custom: c)).prefix(2) == [
            "/OUT/_hidden/A_ B {x}/Come Together_.m4a", "/OUT/_hidden/A_ B {x}/2-01 Birthday.m4a"])
    }

    @Test func truncatesNamesIncludingExtension() {
        var c = PathTemplates()
        c[.singleDiscFile] = "{track:02d} {title} {title} {title}"
        let o = options(.artistAlbum, .custom, custom: c, truncate: 40)
        #expect(o.arguments(inputs: []).contains("--truncate"))
        // gamdl with --truncate 20 gave these; 20 is below the app's minimum of 40, so render directly.
        #expect(PathTemplate.render(c[.singleDiscFile], values: ["track": .number(1), "title": .text("Come Together")],
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
        c[.multiDiscFile] = "{disc}-{nope}"
        #expect(options(.artistAlbum, .custom, custom: c).pathIssue == "Track on a multi-disc album: {nope} isn't a field gamdl knows.")
        // A broken custom folder template doesn't matter while a preset is selected for folders.
        c = PathTemplates(); c[.albumFolder] = "{bad}"
        #expect(options(.artistAlbum, .trackTitle, custom: c).pathIssue == nil)
    }

    @Test func customStartsFromThePreviousPresetUnlessAlreadyEdited() {
        var o = DownloadOptions()
        o.folderLayout = .artistDashAlbum
        o.folderLayout = .custom
        #expect(o.customTemplates[.albumFolder] == "{album_artist} - {album}")
        o.folderLayout = .albumOnly
        o.folderLayout = .custom
        #expect(o.customTemplates[.albumFolder] == "{album_artist} - {album}")
        o.fileNaming = .title
        o.fileNaming = .custom
        #expect(o.customTemplates[.singleDiscFile] == "{title}")
        #expect(o.resolvedPaths.templates[.singleDiscFile] == "{title}")
    }
}

@Suite struct CodecTests {
    @Test func licenseRefusalMeansLosslessNeedsWrapperOnlyForALAC() {
        // Exact line from gamdl 4.0.2 when ALAC is requested with cookies sign-in.
        let refusal = "  ✗ Come Together (2019 Mix): Unable to acquire or process decryption key (DrmLicenseError)"
        #expect(RunIssue.detect(in: refusal, songCodec: .alacLossless) == .losslessRefused)
        #expect(RunIssue.detect(in: refusal, songCodec: .aac) == nil)
        #expect(RunIssue.detect(in: "✓ Come Together: downloaded", songCodec: .alac) == nil)
    }
}

@Suite struct MusicVideoToggleTests {
    let links = ["https://music.apple.com/us/album/abbey-road/1441164426",
                 "https://music.apple.com/us/music-video/something/1441164700",
                 "https://music.apple.com/us/playlist/x/pl.123",
                 "USUM71703861"]

    @Test func recognisesMusicVideoLinks() {
        #expect(LinkParser.isMusicVideoLink(links[1]))
        #expect(!LinkParser.isMusicVideoLink(links[0]))
        #expect(!LinkParser.isMusicVideoLink("https://music.apple.com/us/album/music-video-hits/1"))
        #expect(!LinkParser.isMusicVideoLink("USUM71703861"))
    }

    @Test func onByDefaultEverythingIsSent() {
        let o = DownloadOptions()
        #expect(o.downloadMusicVideos)
        #expect(o.inputsToDownload(links) == (links, 0))
    }

    @Test func offSkipsVideoLinksAndArtistVideos() {
        var o = DownloadOptions()
        o.downloadMusicVideos = false
        let plan = o.inputsToDownload(links)
        #expect(plan.inputs == [links[0], links[2], links[3]])
        #expect(plan.skippedVideos == 1)
        #expect(Array(o.arguments(inputs: links).drop { $0 != "--" }.dropFirst()) == plan.inputs)
        for choice in [ArtistSelection.musicVideos, .all] {
            o.artistSelection = choice
            #expect(o.effectiveArtistSelection == .allAlbums)
            let args = o.arguments(inputs: plan.inputs)
            #expect(args[args.firstIndex(of: "--artist-auto-select")! + 1] == "all-albums")
        }
        o.artistSelection = .topSongs
        #expect(o.effectiveArtistSelection == .topSongs)
        #expect(!o.availableArtistSelections.contains(.musicVideos) && !o.availableArtistSelections.contains(.all))
        #expect(!o.previewPaths().contains { $0.label == "Music video" })
        // The saved artist choice comes back when videos are turned on again.
        o.artistSelection = .all
        o.downloadMusicVideos = true
        #expect(o.effectiveArtistSelection == .all)
    }
}

@Suite struct ToolVersionTests {
    @Test func findsTheFirstVersionNumber() {
        #expect(ToolVersion.find(in: ["", "Gamdl 4.0.2"]) == "4.0.2")
        #expect(ToolVersion.find(in: ["uv 0.13.6 (329bf9448 2026-10-26 aarch64-apple-darwin)"]) == "0.13.6")
        #expect(ToolVersion.find(in: ["gamdl 2.4"]) == "2.4")
        #expect(ToolVersion.find(in: ["command not found"]) == nil)
    }

    @Test func readsTheMajorVersion() {
        #expect(ToolVersion.major("4.0.2") == 4)
        #expect(ToolVersion.major("12.1") == 12)
        #expect(ToolVersion.major("") == nil)
    }

    @Test func comparesVersions() {
        #expect(ToolVersion.isNewer("v1.3.0", than: "1.2.0"))
        #expect(ToolVersion.isNewer("1.10", than: "1.9.9"))
        #expect(ToolVersion.isNewer("2", than: "1.99"))
        #expect(!ToolVersion.isNewer("1.2", than: "1.2.0"))
        #expect(!ToolVersion.isNewer("v1.2.0", than: "1.2.1"))
        #expect(!ToolVersion.isNewer("latest", than: "1.0"))
    }
}
