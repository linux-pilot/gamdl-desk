import AppKit
import GamdlCore
import SwiftUI

/// The Settings window (⌘,): where downloads go, sign-in, performance, requirements and app updates.
/// Download options share their stored value with the main window's Options inspector.
struct SettingsView: View {
    let controller: DownloadController
    let setup: SetupController
    let updater: AppUpdater

    @AppStorage(SettingsKey.downloadOptions) private var options = DownloadOptions()
    @AppStorage(SettingsKey.settingsTab) private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            SettingsForm {
                Section {
                    PathField(title: "Output folder", path: $options.outputDir, directory: true)
                } header: {
                    Text("Output")
                } footer: {
                    Footnote("How folders and files inside it are named is in Options, in the main window.")
                }
                Section("Performance") {
                    Stepper(value: $options.concurrentDownloads, in: DownloadOptions.concurrencyRange) {
                        LabeledContent("Parallel downloads", value: "\(options.concurrentDownloads)")
                    }
                }
            }
            .disabled(controller.isRunning)
            .tabItem { Label("General", systemImage: "gearshape") }
            .tag("general")

            SettingsForm { AccountSection(options: $options, controller: controller) }
                .disabled(controller.isRunning)
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
                .tag("account")

            SettingsForm {
                RequirementsSection(setup: setup)
                AppUpdateSection(updater: updater)
            }
            .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
            .tag("updates")
        }
        .frame(width: 500)
    }
}

/// A grouped form that's as tall as its content, so each Settings tab sizes the window to fit.
private struct SettingsForm<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct AccountSection: View {
    @Binding var options: DownloadOptions
    let controller: DownloadController

    private var signInButtonTitle: String {
        if controller.signInFlow == .waiting { return "Waiting for Terminal…" }
        if case .mode = controller.savedAuth, !controller.issues.contains(.signInRejected) { return "Sign In Again…" }
        return "Sign In with Terminal…"
    }

    var body: some View {
        Section {
            SignInStatus(controller: controller, usesCookiesFile: options.cookiesFile != nil)
            PathField(title: "Cookies file", path: $options.cookiesPath, directory: false,
                      placeholder: "Optional", allowsClear: true)
            if options.cookiesFileIsMissing() {
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
    }
}

/// What gamdl needs, at a glance, with a way back into Setup.
private struct RequirementsSection: View {
    let setup: SetupController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Section {
            requirement("uv", path: setup.uvPath, version: setup.uvVersion)
            requirement("gamdl", path: setup.downloads.gamdlPath, version: setup.downloads.gamdlVersion,
                        outdated: setup.downloads.gamdlIsOutdated)
            HStack {
                Button("Check Again") { setup.checkAgain() }
                    .disabled(setup.isRunning)
                Spacer()
                Button("Open Setup…") {
                    NSApp.keyWindow?.close()
                    openWindow(id: "main")
                    setup.isPresented = true
                }
            }
        } header: {
            Text("Requirements")
        } footer: {
            Footnote("Setup installs or updates uv and gamdl, and signs in to Apple Music.")
        }
    }

    private func requirement(_ name: String, path: String?, version: String?, outdated: Bool = false) -> some View {
        LabeledContent(name) {
            if path == nil {
                Label("Not installed", systemImage: "xmark.circle.fill").foregroundStyle(.red)
            } else if outdated {
                Label("\(version ?? "") · too old", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else {
                Label(version ?? "Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
    }
}

private struct AppUpdateSection: View {
    let updater: AppUpdater
    @AppStorage(AppUpdater.automaticKey) private var checksAutomatically = true

    var body: some View {
        Section {
            LabeledContent("Gamdl Desk", value: updater.currentVersion ?? "Development build")
            AppUpdateStatus(updater: updater)
            Toggle("Check for updates when Gamdl Desk opens", isOn: $checksAutomatically)
        } header: {
            Text("App updates")
        } footer: {
            Footnote("Updates come from the DMG attached to the latest release on [GitHub](\(AppUpdater.releasesURL.absoluteString)).")
        }
    }
}

/// The updater's state with the action that fits it.
struct AppUpdateStatus: View {
    let updater: AppUpdater

    var body: some View {
        HStack(spacing: 8) {
            switch updater.state {
            case .idle:
                Text("Not checked yet").foregroundStyle(.secondary)
            case .checking:
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
            case .upToDate:
                Label("Up to date", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .available(let release):
                Label("Version \(release.version) is available", systemImage: "arrow.down.circle.fill")
                    .foregroundStyle(.blue)
            case .installing(let release):
                ProgressView().controlSize(.small)
                Text("Installing \(release.version)…").foregroundStyle(.secondary)
            case .failed(let reason):
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            if case .available(let release) = updater.state {
                Button("Install and Relaunch") { updater.install(release) }
                    .disabled(updater.installBlockingReason != nil)
                    .help(updater.installBlockingReason ?? "Download \(release.version), replace this app and reopen it")
            } else {
                Button("Check Now") { updater.check(userInitiated: false) }
                    .disabled(updater.isBusy)
            }
        }
    }
}
