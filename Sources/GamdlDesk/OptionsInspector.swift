import AppKit
import GamdlCore
import SwiftUI

/// Download settings, shown in the window's trailing inspector. Changes apply to the next download.
struct OptionsInspector: View {
    @Binding var options: DownloadOptions
    let controller: DownloadController

    private var cookiesMissing: Bool {
        !options.cookiesPath.trimmingCharacters(in: .whitespaces).isEmpty
            && !FileManager.default.fileExists(atPath: options.expandedCookiesPath)
    }

    private var signInButtonTitle: String {
        if controller.signInFlow == .waiting { return "Waiting for Terminal…" }
        if case .mode = controller.savedAuth, !controller.needsSignIn { return "Sign In Again…" }
        return "Sign In with Terminal…"
    }

    var body: some View {
        Form {
            Section {
                PathField(title: "Output folder", path: $options.outputDir, directory: true)
            } header: {
                Text("Output")
            }

            Section {
                SignInStatus(controller: controller, usesCookiesFile: !options.cookiesPath.trimmingCharacters(in: .whitespaces).isEmpty)
                PathField(title: "Cookies file", path: $options.cookiesPath, directory: false,
                          placeholder: "Optional", allowsClear: true)
                if cookiesMissing {
                    Label("This file doesn't exist.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
                Button(signInButtonTitle) { controller.signInInTerminal() }
                    .disabled(controller.gamdlPath == nil || controller.signInFlow == .waiting)
            } header: {
                Text("Account")
            } footer: {
                Footnote("Leave the cookies file empty to use the sign-in saved by `gamdl auth`. A cookies.txt must be exported from music.apple.com while signed in.")
            }

            Section("Songs") {
                Picker("Codec", selection: $options.songCodec) {
                    ForEach(DownloadOptions.songCodecs, id: \.self) { Text($0) }
                }
                Toggle("Save lyrics file", isOn: $options.saveLyrics)
                Picker("Lyrics format", selection: $options.lyricsFormat) {
                    ForEach(DownloadOptions.lyricsFormats, id: \.self) { Text($0) }
                }
                .disabled(!options.saveLyrics)
            }

            Section("Music videos") {
                Picker("Codec", selection: $options.mvCodec) {
                    ForEach(DownloadOptions.mvCodecs, id: \.self) { Text($0) }
                }
                Picker("Container", selection: $options.mvContainer) {
                    ForEach(DownloadOptions.mvContainers, id: \.self) { Text($0) }
                }
                Picker("Max height", selection: $options.maxHeight) {
                    ForEach(DownloadOptions.maxHeights, id: \.self) { Text("\($0)p").tag($0) }
                }
            }

            Section {
                Picker("Download", selection: $options.artistSelection) {
                    ForEach(DownloadOptions.artistSelections, id: \.value) { Text($0.label).tag($0.value) }
                }
            } header: {
                Text("Artist links")
            } footer: {
                Footnote("What to download when you paste an artist's page.")
            }

            Section("Files") {
                Toggle("Save cover art file", isOn: $options.saveCover)
                Picker("Cover format", selection: $options.coverFormat) {
                    ForEach(DownloadOptions.coverFormats, id: \.self) { Text($0) }
                }
                Toggle("Save playlist (.m3u)", isOn: $options.savePlaylist)
                Toggle("Overwrite existing files", isOn: $options.overwrite)
            }

            Section {
                Stepper(value: $options.concurrentDownloads, in: DownloadOptions.concurrencyRange) {
                    LabeledContent("Parallel downloads", value: "\(options.concurrentDownloads)")
                }
            } header: {
                Text("Performance")
            }

            Section {
                HStack {
                    Button("Reset to Defaults") { options = DownloadOptions() }
                    Spacer()
                    let config = "\(NSHomeDirectory())/.gamdl/config.yml"
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
        } else if controller.needsSignIn, usesCookiesFile || controller.savedAuth != SavedAuth.none {
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
