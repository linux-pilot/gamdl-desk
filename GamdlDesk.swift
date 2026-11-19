import SwiftUI
import AppKit

// MARK: - Runner: owns the gamdl child process and its log

@MainActor
final class GamdlRunner: ObservableObject {
    @Published var log = ""
    @Published var isRunning = false
    private var process: Process?

    static let searchPaths = [
        "\(NSHomeDirectory())/.local/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]

    static func findGamdl() -> String? {
        searchPaths.map { "\($0)/gamdl" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func run(arguments: [String]) {
        guard !isRunning else { return }
        guard let exe = Self.findGamdl() else {
            append("gamdl not found. Install it in Terminal with:\n  uv tool install \"gamdl[widevine]\"\n")
            return
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Self.searchPaths.joined(separator: ":")
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        env["PYTHONUNBUFFERED"] = "1"
        p.environment = env
        // No stdin: interactive prompts fail fast instead of hanging the app.
        p.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.append(Self.stripANSI(s)) }
        }
        p.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            let rest = pipe.fileHandleForReading.readDataToEndOfFile()
            let tail = String(data: rest, encoding: .utf8) ?? ""
            Task { @MainActor in
                guard let self else { return }
                self.append(Self.stripANSI(tail))
                self.append("\n— finished (exit code \(proc.terminationStatus)) —\n")
                self.isRunning = false
                self.process = nil
            }
        }

        append("$ gamdl " + arguments.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ") + "\n")
        do {
            try p.run()
            process = p
            isRunning = true
        } catch {
            append("Failed to start gamdl: \(error.localizedDescription)\n")
        }
    }

    func stop() { process?.interrupt() }

    func append(_ s: String) {
        log += s
        if log.count > 200_000 { log = String(log.suffix(150_000)) }
    }

    nonisolated static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "\n")
    }
}

// MARK: - UI

struct ContentView: View {
    @StateObject private var runner = GamdlRunner()

    @State private var urls = ""
    @AppStorage("outputDir") private var outputDir = "\(NSHomeDirectory())/Music/gamdl"
    @AppStorage("cookiesPath") private var cookiesPath = ""
    @AppStorage("songCodec") private var songCodec = "aac"
    @AppStorage("mvCodec") private var mvCodec = "h264"
    @AppStorage("mvContainer") private var mvContainer = "m4v"
    @AppStorage("maxHeight") private var maxHeight = 1080
    @AppStorage("lyricsFormat") private var lyricsFormat = "lrc"
    @AppStorage("saveLyrics") private var saveLyrics = true
    @AppStorage("saveCover") private var saveCover = false
    @AppStorage("coverFormat") private var coverFormat = "jpg"
    @AppStorage("overwrite") private var overwrite = false
    @AppStorage("savePlaylist") private var savePlaylist = false

    static let songCodecs = ["aac", "aac-he", "aac-binaural", "aac-downmix", "aac-he-binaural",
                             "aac-he-downmix", "aac-web", "aac-he-web", "atmos", "ac3",
                             "alac", "alac-lossless", "alac-hires"]
    static let lyricsFormats = ["lrc", "enhanced-lrc", "srt", "ttml", "enhanced-ttml", "text"]

    var urlList: [String] {
        urls.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { !$0.isEmpty }
    }

    var body: some View {
        HSplitView {
            Form {
                Section("Apple Music URLs (one per line)") {
                    TextEditor(text: $urls)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 110)
                        .accessibilityLabel("Apple Music URLs")
                }
                Section("Locations") {
                    pathRow("Output folder", path: $outputDir, directory: true)
                    pathRow("Cookies file", path: $cookiesPath, directory: false,
                            placeholder: "Optional — uses `gamdl auth` setup if empty")
                }
                Section("Songs") {
                    Picker("Codec", selection: $songCodec) {
                        ForEach(Self.songCodecs, id: \.self) { Text($0) }
                    }
                    Toggle("Save lyrics file", isOn: $saveLyrics)
                    Picker("Lyrics format", selection: $lyricsFormat) {
                        ForEach(Self.lyricsFormats, id: \.self) { Text($0) }
                    }.disabled(!saveLyrics)
                }
                Section("Music videos") {
                    Picker("Codec", selection: $mvCodec) { Text("h264").tag("h264"); Text("h265").tag("h265") }
                    Picker("Container", selection: $mvContainer) { Text("m4v").tag("m4v"); Text("mp4").tag("mp4") }
                    Picker("Max height", selection: $maxHeight) {
                        ForEach([480, 720, 1080, 1440, 2160], id: \.self) { Text("\($0)p").tag($0) }
                    }
                }
                Section("Extras") {
                    Toggle("Save cover art file", isOn: $saveCover)
                    Picker("Cover format", selection: $coverFormat) { Text("jpg").tag("jpg"); Text("png").tag("png") }
                    Toggle("Save playlist (.m3u)", isOn: $savePlaylist)
                    Toggle("Overwrite existing files", isOn: $overwrite)
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 380, idealWidth: 420)

            VStack(spacing: 8) {
                HStack {
                    Button {
                        runner.run(arguments: arguments())
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle.fill")
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(runner.isRunning || urlList.isEmpty || outputDir.isEmpty)

                    Button("Stop", role: .destructive) { runner.stop() }
                        .disabled(!runner.isRunning)

                    if runner.isRunning { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Open Output") {
                        try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(URL(fileURLWithPath: outputDir))
                    }
                    Button("Clear Log") { runner.log = "" }.disabled(runner.isRunning)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(runner.log.isEmpty ? "Paste album, song, playlist, artist or music-video links, then press Download (⌘↩)." : runner.log)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(runner.log.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .onChange(of: runner.log) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            .padding(12)
            .frame(minWidth: 420)
        }
        .frame(minWidth: 860, minHeight: 560)
    }

    func arguments() -> [String] {
        var a = ["rip", "--no-progress", "--no-tracebacks",
                 "--output-dir", (outputDir as NSString).expandingTildeInPath,
                 "--song-codec", songCodec,
                 "--music-video-codec", mvCodec,
                 "--music-video-container", mvContainer,
                 "--max-height", String(maxHeight),
                 "--cover-format", coverFormat,
                 saveCover ? "--save-cover" : "--no-save-cover",
                 savePlaylist ? "--save-playlist" : "--no-save-playlist",
                 overwrite ? "--overwrite" : "--no-overwrite"]
        if saveLyrics { a += ["--lyrics-file-format", lyricsFormat] } else { a.append("--no-lyrics-file") }
        if !cookiesPath.isEmpty {
            a += ["--auth-mode", "cookies", "--cookies-path", (cookiesPath as NSString).expandingTildeInPath]
        }
        return a + urlList
    }

    @ViewBuilder
    func pathRow(_ title: String, path: Binding<String>, directory: Bool, placeholder: String = "") -> some View {
        LabeledContent(title) {
            HStack {
                TextField(title, text: path, prompt: Text(placeholder))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = directory
                    panel.canChooseFiles = !directory
                    panel.canCreateDirectories = directory
                    if panel.runModal() == .OK, let url = panel.url { path.wrappedValue = url.path }
                }
            }
        }
    }
}

@main
struct GamdlDeskApp: App {
    var body: some Scene {
        WindowGroup("Gamdl Desk") { ContentView() }
            .windowResizability(.contentMinSize)
    }
}
