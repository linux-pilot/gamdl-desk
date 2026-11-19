import AppKit
import GamdlCore
import SwiftUI

/// Per-download options, shown in the window's trailing inspector. Changes apply to the next download.
/// The output folder, sign-in and parallel downloads are in Settings (⌘,).
struct OptionsInspector: View {
    @Binding var options: DownloadOptions
    let controller: DownloadController

    var body: some View {
        Form {
            FolderLayoutSection(options: $options)

            Section("Songs") {
                Picker("Codec", selection: $options.songCodec) {
                    ForEach(SongCodec.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if options.songCodec.needsWrapper && !options.usesWrapper(savedAuth: controller.savedAuth) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Lossless only works when gamdl signs in through Wrapper v2. With cookies, Apple refuses the key and every song fails.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Link("How to set up Wrapper v2", destination: Gamdl.wrapperURL)
                    }
                    .font(.caption)
                }
                Toggle("Save lyrics file", isOn: $options.saveLyrics)
                Picker("Lyrics format", selection: $options.lyricsFormat) {
                    ForEach(LyricsFormat.allCases, id: \.self) { Text($0.rawValue) }
                }
                .disabled(!options.saveLyrics)
            }

            Section {
                Toggle("Download music videos", isOn: $options.downloadMusicVideos)
                Group {
                    Picker("Codec", selection: $options.mvCodec) {
                        ForEach(MusicVideoCodec.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    Picker("Container", selection: $options.mvContainer) {
                        ForEach(MusicVideoContainer.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    Picker("Max height", selection: $options.maxHeight) {
                        ForEach(DownloadOptions.maxHeights, id: \.self) { Text("\($0)p").tag($0) }
                    }
                }
                .disabled(!options.downloadMusicVideos)
            } header: {
                Text("Music videos")
            } footer: {
                if !options.downloadMusicVideos {
                    Footnote("Music-video links are skipped and artist links download albums only. Videos that are part of an album or playlist still download: gamdl has no way to leave them out.")
                }
            }

            Section {
                Picker("Download", selection: Binding(
                    get: { options.effectiveArtistSelection },
                    set: { options.artistSelection = $0 })) {
                    ForEach(options.availableArtistSelections, id: \.self) { Text($0.label).tag($0) }
                }
            } header: {
                Text("Artist links")
            } footer: {
                Footnote("What to download when you paste an artist's page.")
            }

            Section("Files") {
                Toggle("Save cover art file", isOn: $options.saveCover)
                Picker("Cover format", selection: $options.coverFormat) {
                    ForEach(CoverFormat.allCases, id: \.self) { Text($0.rawValue) }
                }
                Toggle("Save playlist (.m3u)", isOn: $options.savePlaylist)
                Toggle("Overwrite existing files", isOn: $options.overwrite)
            }

            Section {
                HStack {
                    Button("Reset to Defaults") { options = DownloadOptions() }
                        .help("Resets every download option, including the ones in Settings")
                    Spacer()
                    let config = Gamdl.configPath
                    if FileManager.default.fileExists(atPath: config) {
                        Button("Open gamdl Config") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: config)])
                        }
                        .help("Settings not shown here can be set in \(config)")
                    }
                }
            } footer: {
                Footnote("Changes apply to the next download.")
            }
        }
        .formStyle(.grouped)
        .disabled(controller.isRunning)
    }
}

/// A path text field with a Choose… button, laid out vertically so it fits a narrow inspector.
struct PathField: View {
    let title: String
    @Binding var path: String
    let directory: Bool
    var placeholder = ""
    var allowsClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            HStack(spacing: 6) {
                TextField(title, text: $path, prompt: Text(placeholder))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .truncationMode(.head)
                if allowsClear && !path.isEmpty {
                    Button("Clear", systemImage: "xmark.circle.fill") { path = "" }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Clear")
                }
                Button("Choose…", action: choose)
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directory
        panel.canChooseFiles = !directory
        panel.canCreateDirectories = directory
        panel.allowsMultipleSelection = false
        let current = DownloadOptions.expand(path)
        if !current.isEmpty {
            let url = URL(fileURLWithPath: current)
            panel.directoryURL = directory ? url : url.deletingLastPathComponent()
        }
        if panel.runModal() == .OK, let url = panel.url {
            path = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }
}

/// Section footer text: small, secondary and left-aligned regardless of length.
struct Footnote: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One line saying whether gamdl can sign in, and how.
struct SignInStatus: View {
    let controller: DownloadController
    let usesCookiesFile: Bool

    var body: some View {
        HStack(spacing: 8) {
            status
            Spacer(minLength: 4)
            if controller.checkingAuth { ProgressView().controlSize(.small) }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var status: some View {
        if controller.gamdlPath == nil {
            Label("gamdl isn't installed", systemImage: "xmark.circle.fill").foregroundStyle(.secondary)
        } else if controller.signInFlow == .waiting {
            Label("Signing in in Terminal…", systemImage: "terminal").foregroundStyle(.secondary)
        } else if controller.issues.contains(.signInRejected), usesCookiesFile || controller.savedAuth != SavedAuth.none {
            Label(usesCookiesFile ? "The cookies file was rejected" : "The saved sign-in was rejected",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else if usesCookiesFile {
            Label("Using the cookies file below", systemImage: "doc.text.fill").foregroundStyle(.secondary)
        } else {
            switch controller.savedAuth {
            case .mode(let mode):
                Label("Signed in · \(SavedAuth.label(for: mode))", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .none?:
                Label("Not signed in", systemImage: "person.crop.circle.badge.exclamationmark")
                    .foregroundStyle(.orange)
            case nil:
                Label(controller.checkingAuth ? "Checking sign-in…" : "Sign-in status unknown",
                      systemImage: "questionmark.circle").foregroundStyle(.secondary)
            }
        }
    }
}

struct FolderLayoutSection: View {
    @Binding var options: DownloadOptions
    @State private var showFields = false

    var body: some View {
        Section {
            PresetPicker(title: "Folders", selection: $options.folderLayout, custom: $options.customTemplates)
            PresetPicker(title: "File names", selection: $options.fileNaming, custom: $options.customTemplates)

            Toggle("Limit name length", isOn: Binding(
                get: { options.maxNameLength > 0 },
                set: { options.maxNameLength = $0 ? DownloadOptions.suggestedNameLength : 0 }))
            if options.maxNameLength > 0 {
                Stepper(value: $options.maxNameLength, in: DownloadOptions.nameLengthRange, step: 10) {
                    LabeledContent("Longest name", value: "\(options.maxNameLength) bytes")
                }
            }

            preview
        } header: {
            Text("Folders & file names")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if options.folderLayout == .custom || options.fileNaming == .custom {
                    DisclosureGroup("Template fields", isExpanded: $showFields) {
                        Footnote(LocalizedStringKey(Self.fieldHelp))
                            .textSelection(.enabled)
                    }
                    .font(.caption)
                }
                Footnote(options.folderLayout == .flat
                    ? "Everything is saved directly in the output folder."
                    : "Use / in a template to make subfolders.")
            }
        }
    }

    @ViewBuilder private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preview").font(.subheadline.weight(.semibold))
            if let issue = options.pathIssue {
                Label(issue, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(options.previewPaths(), id: \.label) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.label).font(.caption).foregroundStyle(.secondary)
                        Text(item.path)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    static let fieldHelp = PathTemplate.fields.map { "`{\($0)}`" }.joined(separator: " ") + """

    Formats: `{track:02d}` → 01, `{date:%Y}` → 1969, `{title:.30}` → first 30 characters. \
    Write `{{` or `}}` for a literal brace. Characters like : and / inside values become _.
    """
}

/// Picks a preset for one group of templates; Custom shows a field per template.
struct PresetPicker<Preset: PathPreset>: View {
    let title: String
    @Binding var selection: Preset
    @Binding var custom: PathTemplates

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(Preset.presets, id: \.self) { Text($0.label).tag($0) }
            Divider()
            Text(Preset.custom.label).tag(Preset.custom)
        }
        if selection == Preset.custom {
            ForEach(Preset.slots, id: \.self) { slot in
                TemplateField(title: slot.title, text: $custom[slot])
            }
        }
    }
}

struct TemplateField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            TextField(title, text: $text)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
            if let problem = PathTemplate.problem(in: text) {
                Label(problem, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
