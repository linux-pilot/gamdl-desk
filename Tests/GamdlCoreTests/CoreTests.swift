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
                         "--lyrics-file-format", "lrc", "--", "https://music.apple.com/us/album/a/1"])
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
