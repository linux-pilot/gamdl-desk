import AppKit
import GamdlCore
import SwiftUI

enum ResultsTab: String, CaseIterable {
    case activity = "Activity", log = "Log"
}

enum SettingsKey {
    static let downloadOptions = "downloadOptions"
    static let showOptions = "showOptions"
    static let resultsTab = "resultsTab"
    static let settingsTab = "settingsTab"
}

struct ContentView: View {
    let controller: DownloadController
    @Bindable var setup: SetupController
    let updater: AppUpdater

    @AppStorage(SettingsKey.downloadOptions) private var options = DownloadOptions()
    @AppStorage(SettingsKey.showOptions) private var showOptions = true
    @AppStorage(SettingsKey.resultsTab) private var tab = ResultsTab.activity
    @State private var input = ""
    #if DEBUG
    @Environment(\.openSettings) private var openSettings
    #endif

    private var parsed: LinkParser.Result { LinkParser.parse(input) }
    private var plan: (inputs: [String], skippedVideos: Int) { options.inputsToDownload(parsed.valid) }

    private var blockingReason: String? {
        if controller.gamdlPath == nil { return "gamdl isn't installed. Open Setup to install it." }
        if setup.isRunning { return "Wait for Setup to finish installing." }
        if controller.gamdlIsOutdated { return "gamdl \(controller.gamdlVersion ?? "") is too old. Open Setup to update it." }
        if parsed.valid.isEmpty { return "Paste at least one Apple Music link." }
        if plan.inputs.isEmpty { return "These are all music-video links, and music videos are turned off in Options." }
        return options.blockingIssue()
    }

    var body: some View {
        VStack(spacing: 0) {
            banners
            GeometryReader { geo in
                VStack(spacing: 0) {
                    linksSection
                        .frame(height: min(max(geo.size.height * 0.36, 170), 320))
                    Divider()
                    resultsSection
                }
            }
            StatusBar(controller: controller)
        }
        .frame(minWidth: 520, minHeight: 460)
        .inspector(isPresented: $showOptions) {
            OptionsInspector(options: $options, controller: controller)
                .inspectorColumnWidth(min: 280, ideal: 320, max: 440)
        }
        .toolbar { toolbar }
        .sheet(isPresented: $setup.isPresented) { SetupView(setup: setup) }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: DebugDriver.inputNotification)) { input = $0.object as? String ?? "" }
        .onReceive(NotificationCenter.default.publisher(for: DebugDriver.downloadNotification)) { _ in download() }
        .onReceive(NotificationCenter.default.publisher(for: DebugDriver.settingsNotification)) { _ in openSettings() }
        #endif
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                openOutputFolder()
            } label: {
                Label("Open Output Folder", systemImage: "folder")
            }
            .help("Open the output folder in Finder (⇧⌘O)")
            .keyboardShortcut("o", modifiers: [.command, .shift])

            Button {
                setup.isPresented = true
            } label: {
                Label("Setup", systemImage: "wrench.and.screwdriver")
            }
            .help("Check and install what gamdl needs")

            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Output folder, account, performance and updates (⌘,)")

            Button {
                withAnimation { showOptions.toggle() }
            } label: {
                Label("Options", systemImage: "sidebar.trailing")
            }
            .help(showOptions ? "Hide options (⌥⌘I)" : "Show options (⌥⌘I)")
            .keyboardShortcut("i", modifiers: [.command, .option])
        }
    }

    // MARK: Banners

    @ViewBuilder private var banners: some View {
        if controller.gamdlPath == nil || controller.gamdlIsOutdated {
            Banner(systemImage: "exclamationmark.triangle.fill", tint: .orange,
                   title: controller.gamdlPath == nil ? "gamdl isn't installed" : "gamdl needs an update",
                   message: controller.gamdlPath == nil
                       ? "Setup installs it, along with what it needs."
                       : "Gamdl Desk needs gamdl \(Gamdl.minimumMajorVersion) or later. Setup can update it.") {
                Button("Open Setup…") { setup.isPresented = true }
                Button("Check Again") { setup.checkAgain() }
            }
        } else if controller.showsBanner(for: .losslessRefused) {
            Banner(systemImage: "waveform.badge.exclamationmark", tint: .orange,
                   title: "Lossless needs gamdl's Wrapper",
                   message: "Apple refused the decryption key for ALAC. Lossless only works through Wrapper v2; AAC and Dolby Atmos work with your current sign-in.") {
                Button("Use AAC") {
                    options.songCodec = .aac
                    controller.dismiss(.losslessRefused)
                }
                Button("About Wrapper") { NSWorkspace.shared.open(Gamdl.wrapperURL) }
                Button("Dismiss") { controller.dismiss(.losslessRefused) }
            }
        } else if controller.signInFlow == .waiting {
            Banner(systemImage: "terminal", tint: .blue,
                   title: "Finish signing in in Terminal",
                   message: "Answer gamdl's questions in the Terminal window. This updates by itself when you're done.",
                   showsProgress: true) {
                Button("Cancel") { controller.cancelSignInWait() }
            }
        } else if case .succeeded(let mode) = controller.signInFlow {
            Banner(systemImage: "checkmark.circle.fill", tint: .green,
                   title: "Signed in to Apple Music",
                   message: "gamdl saved your sign-in (\(SavedAuth.label(for: mode))). You can download now.") {
                Button("OK") { controller.dismissSignInResult() }
            }
        } else if case .failed(let reason) = controller.signInFlow {
            Banner(systemImage: "exclamationmark.triangle.fill", tint: .orange,
                   title: "Sign-in didn't finish", message: reason) {
                Button("Try Again") { controller.signInInTerminal() }
                Button("Dismiss") { controller.dismissSignInResult() }
            }
        } else if controller.showsBanner(for: .signInRejected) {
            Banner(systemImage: "person.crop.circle.badge.exclamationmark", tint: .blue,
                   title: "gamdl needs to sign in to Apple Music",
                   message: "Sign in once in Terminal, or choose a cookies.txt exported from music.apple.com in Settings ▸ Account.") {
                Button("Sign In with Terminal…") { controller.signInInTerminal() }
                Button("Dismiss") { controller.dismiss(.signInRejected) }
            }
        } else if updater.showsBanner {
            updateBanner
        }
    }

    @ViewBuilder private var updateBanner: some View {
        let hide = { updater.showsBanner = false }
        switch updater.state {
        case .available(let release):
            Banner(systemImage: "arrow.down.circle.fill", tint: .blue,
                   title: "Gamdl Desk \(release.version) is available",
                   message: updater.installBlockingReason
                       ?? "You have \(updater.currentVersion ?? "an older version"). Installing replaces the app and reopens it.") {
                Button("Install and Relaunch") { updater.install(release) }
                    .disabled(updater.installBlockingReason != nil)
                Button("What's New") { NSWorkspace.shared.open(release.pageURL) }
                Button("Later", action: hide)
            }
        case .installing(let release):
            Banner(systemImage: "arrow.down.circle", tint: .blue,
                   title: "Installing Gamdl Desk \(release.version)…",
                   message: "Gamdl Desk reopens by itself when it's done.", showsProgress: true) {}
        case .checking:
            Banner(systemImage: "arrow.triangle.2.circlepath", tint: .blue,
                   title: "Checking for updates…", message: "Looking at the latest release on GitHub.",
                   showsProgress: true) {}
        case .upToDate:
            Banner(systemImage: "checkmark.circle.fill", tint: .green,
                   title: "Gamdl Desk is up to date",
                   message: "You have the latest version (\(updater.currentVersion ?? "")).") {
                Button("OK", action: hide)
            }
        case .failed(let reason):
            Banner(systemImage: "exclamationmark.triangle.fill", tint: .orange,
                   title: "Update didn't work", message: reason) {
                Button("Open Releases") { NSWorkspace.shared.open(AppUpdater.releasesURL) }
                Button("Dismiss", action: hide)
            }
        case .idle:
            EmptyView()
        }
    }

    // MARK: Links

    private var linksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Links").font(.headline)
                linkSummary
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
                Spacer(minLength: 8)
                Button("Paste", systemImage: "doc.on.clipboard", action: paste)
                    .help("Add links from the clipboard (⇧⌘V)")
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                Button("Clear", systemImage: "xmark.circle") { input = "" }
                    .disabled(input.isEmpty)
                    .help("Remove all links")
            }
            .labelStyle(.titleAndIcon)
            .controlSize(.small)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $input)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .accessibilityLabel("Apple Music links")
                if input.isEmpty {
                    Text("Paste album, song, playlist, artist or music-video links (or ISRC codes), one per line.")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))

            downloadRow
        }
        .padding(12)
    }

    private var downloadRow: some View {
        HStack(spacing: 8) {
            if !controller.isRunning, let reason = blockingReason {
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(reason)
            }
            Spacer(minLength: 8)
            if controller.isRunning {
                Button(role: .cancel) {
                    controller.stop()
                } label: {
                    Label(controller.phase.isStopping ? "Stopping…" : "Stop", systemImage: "stop.circle.fill")
                        .frame(minWidth: 96)
                }
                .help("Stop the download (⌘.)")
                .keyboardShortcut(".", modifiers: .command)
                .disabled(controller.phase.isStopping)
            } else {
                Button(action: download) {
                    Label(plan.inputs.count > 1 ? "Download \(plan.inputs.count)" : "Download",
                          systemImage: "arrow.down.circle.fill")
                        .frame(minWidth: 96)
                }
                .buttonStyle(.borderedProminent)
                .help(blockingReason ?? "Download \(plan.inputs.count) item\(plan.inputs.count == 1 ? "" : "s") (⌘↩)")
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(blockingReason != nil)
            }
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.large)
    }

    @ViewBuilder private var linkSummary: some View {
        let r = parsed, p = plan
        if !r.valid.isEmpty || !r.invalid.isEmpty {
            HStack(spacing: 6) {
                if !p.inputs.isEmpty {
                    Text("\(p.inputs.count) ready").foregroundStyle(.secondary)
                }
                if p.skippedVideos > 0 {
                    Text("· \(p.skippedVideos) music video\(p.skippedVideos == 1 ? "" : "s") skipped")
                        .foregroundStyle(.secondary)
                        .help("Music videos are turned off in Options.")
                }
                if r.duplicates > 0 {
                    Text("· \(r.duplicates) duplicate\(r.duplicates == 1 ? "" : "s") ignored").foregroundStyle(.secondary)
                }
                if !r.invalid.isEmpty {
                    Label("\(r.invalid.count) not recognized", systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .help("Not Apple Music links:\n" + r.invalid.prefix(20).joined(separator: "\n"))
                }
            }
        }
    }

    // MARK: Results

    private var resultsSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Results", selection: $tab) {
                    Text(controller.items.isEmpty ? "Activity" : "Activity (\(controller.items.count))")
                        .tag(ResultsTab.activity)
                    Text("Log").tag(ResultsTab.log)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Menu {
                    Button("Copy Log") { copy(controller.log.text) }
                    Button("Save Log…", action: saveLog)
                } label: {
                    Label("Log Actions", systemImage: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(controller.log.lines.isEmpty)
                .help("Copy or save the log")
                Button("Clear", systemImage: "trash") { controller.clear() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(controller.isRunning || (controller.log.lines.isEmpty && controller.items.isEmpty))
                    .help("Clear activity and log (⌘K)")
                    .keyboardShortcut("k", modifiers: .command)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            Group {
                switch tab {
                case .activity: ActivityView(controller: controller, showLog: { tab = .log })
                case .log: LogView(store: controller.log)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    // MARK: Actions

    private func download() {
        guard blockingReason == nil else { return }
        controller.start(options: options, inputs: plan.inputs)
    }

    private func paste() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        input += (input.isEmpty || input.hasSuffix("\n") ? "" : "\n") + text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private func openOutputFolder() {
        let path = options.expandedOutputDir
        guard !path.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }

    private func saveLog() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "gamdl-log.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try controller.log.text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

// MARK: - Activity

struct ActivityView: View {
    let controller: DownloadController
    let showLog: () -> Void

    var body: some View {
        if controller.items.isEmpty {
            emptyState
        } else {
            List(controller.items) { item in
                ActivityRow(event: item.event)
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 72, height: 72)
                .opacity(controller.isRunning ? 0.6 : 1)
                .accessibilityHidden(true)
            switch controller.phase {
            case .running, .stopping:
                Text("Working…").font(.title3.weight(.semibold))
                Text("Finished items will appear here. Details are in the Log.")
                    .foregroundStyle(.secondary)
                Button("Show Log", action: showLog)
            case .finished(let t, _):
                Text(t.stoppedByUser ? "Stopped" : t.succeeded ? "Nothing to download" : "Download failed")
                    .font(.title3.weight(.semibold))
                Text("See the log for what gamdl reported.").foregroundStyle(.secondary)
                Button("Show Log", action: showLog)
            case .failedToStart(let reason):
                Text("Couldn't start").font(.title3.weight(.semibold))
                Text(reason).foregroundStyle(.secondary)
            case .idle:
                Text("Gamdl Desk").font(.title3.weight(.semibold))
                Text("Paste Apple Music links above, then press Download (⌘↩).")
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ActivityRow: View {
    let event: OutputEvent

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon.name)
                .foregroundStyle(icon.color)
                .font(.title3)
                .frame(width: 22)
                .accessibilityLabel(icon.label)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).lineLimit(1).truncationMode(.middle)
                Text(event.path.map { "\(event.detail) · \(($0 as NSString).lastPathComponent)" } ?? event.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            if let path = event.path {
                Button("Show in Finder", systemImage: "magnifyingglass.circle") { reveal(path) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .help(event.path ?? event.detail)
        .contextMenu {
            if let path = event.path {
                Button("Show in Finder") { reveal(path) }
                Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                Button("Copy Path") { copy(path) }
            }
            Button("Copy Title") { copy(event.title) }
        }
        .onTapGesture(count: 2) { if let path = event.path { reveal(path) } }
    }

    private var icon: (name: String, color: Color, label: String) {
        switch event.kind {
        case .saved: ("checkmark.circle.fill", .green, "Saved")
        case .skipped: ("arrow.uturn.forward.circle.fill", .secondary, "Skipped")
        case .partial: ("exclamationmark.triangle.fill", .orange, "Partly saved")
        case .failed: ("xmark.octagon.fill", .red, "Failed")
        }
    }

    private func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

// MARK: - Status bar

struct StatusBar: View {
    let controller: DownloadController

    var body: some View {
        HStack(spacing: 12) {
            status
            if !controller.items.isEmpty {
                counts
            }
            Spacer(minLength: 8)
            if let version = controller.gamdlVersion {
                Text("gamdl \(version)").foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder private var status: some View {
        switch controller.phase {
        case .idle:
            Label("Ready", systemImage: "circle.fill").foregroundStyle(.secondary).imageScale(.small)
        case .running(let since), .stopping(let since):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(controller.phase.isStopping ? "Stopping…" : "Downloading…")
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text(Self.duration(context.date.timeIntervalSince(since)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        case .finished(let t, let duration):
            if t.stoppedByUser {
                Label("Stopped after \(Self.duration(duration))", systemImage: "stop.circle.fill")
                    .foregroundStyle(.secondary)
            } else if t.succeeded {
                Label("Finished in \(Self.duration(duration))", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label(t.signaled ? "gamdl crashed (signal \(t.status))" : "Finished with errors (exit code \(t.status))",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        case .failedToStart(let reason):
            Label(reason, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    private var counts: some View {
        HStack(spacing: 10) {
            Label("\(controller.savedCount)", systemImage: "checkmark.circle").help("Saved")
            Label("\(controller.skippedCount)", systemImage: "arrow.uturn.forward.circle").help("Skipped")
            Label("\(controller.failedCount)", systemImage: "xmark.octagon")
                .foregroundStyle(controller.failedCount > 0 ? .red : .secondary)
                .help("Failed")
        }
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Banner

struct Banner<Actions: View>: View {
    let systemImage: String
    let tint: Color
    let title: String
    let message: String
    var showsProgress = false
    @ViewBuilder let actions: Actions

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { icon; text; Spacer(minLength: 8); HStack { actions } }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) { icon; text }
                HStack { actions }.padding(.leading, 30)
            }
        }
        .controlSize(.small)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder private var icon: some View {
        if showsProgress {
            ProgressView().controlSize(.small).frame(width: 20)
        } else {
            Image(systemName: systemImage).foregroundStyle(tint).font(.title3).frame(width: 20)
        }
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).fontWeight(.semibold)
            Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
