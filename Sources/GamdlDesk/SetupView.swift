import AppKit
import GamdlCore
import SwiftUI

/// Checks what gamdl needs, in order, and installs what's missing.
struct SetupView: View {
    let setup: SetupController
    @Environment(\.dismiss) private var dismiss
    @State private var showsDetails = false

    private var downloads: DownloadController { setup.downloads }

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                Section {
                    uvRow
                    gamdlRow
                    signInRow
                } header: {
                    Text("Required")
                }
                Section {
                    losslessRow
                } header: {
                    Text("Optional")
                }
                if let failure = setup.failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                if !setup.log.lines.isEmpty {
                    DisclosureGroup("Details", isExpanded: $showsDetails) {
                        LogView(store: setup.log)
                            .frame(height: 160)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            footer
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: setup.installing) { _, installing in
            if installing != nil { showsDetails = true }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 48, height: 48)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Set Up Gamdl Desk").font(.title2.weight(.semibold))
                Text("Gamdl Desk downloads with gamdl. Install what's missing, top to bottom.")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding([.horizontal, .top], 20)
    }

    private var footer: some View {
        HStack {
            Button("Check Again") { setup.checkAgain() }
                .disabled(setup.isRunning)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding([.horizontal, .bottom], 20)
    }

    // MARK: Rows

    private var uvRow: some View {
        SetupRow(state: setup.installing == .uv ? .working : setup.uvPath == nil ? .missing : .done,
                 title: "uv",
                 status: setup.uvPath.map { located("uv", version: setup.uvVersion, at: $0) }
                     ?? "Not installed",
                 detail: "Installs gamdl, and downloads the Python (3.10 or later) it needs.") {
            if setup.uvPath == nil { installButton(.uv, title: "Install uv") }
        }
    }

    private var gamdlRow: some View {
        let state: SetupState
        let status: String
        if setup.installing == .gamdl {
            (state, status) = (.working, downloads.gamdlPath == nil ? "Installing…" : "Updating…")
        } else if let path = downloads.gamdlPath {
            let outdated = downloads.gamdlIsOutdated
            state = outdated ? .warning : .done
            status = located("gamdl", version: downloads.gamdlVersion, at: path)
                + (outdated ? ". Gamdl Desk needs version \(Gamdl.minimumMajorVersion) or later." : "")
        } else {
            (state, status) = (.missing, "Not installed")
        }
        return SetupRow(state: state, title: "gamdl", status: status,
                        detail: "The Apple Music downloader, installed with uv.") {
            installButton(.gamdl, title: downloads.gamdlPath == nil ? "Install gamdl" : "Update")
        }
    }

    private var signInRow: some View {
        let state: SetupState
        let status: String
        if downloads.gamdlPath == nil {
            (state, status) = (.pending, "Install gamdl first")
        } else if downloads.signInFlow == .waiting {
            (state, status) = (.working, "Signing in in Terminal…")
        } else {
            switch downloads.savedAuth {
            case .mode(let mode): (state, status) = (.done, "Signed in · \(SavedAuth.label(for: mode))")
            case .none?: (state, status) = (.missing, "Not signed in")
            case nil: (state, status) = (downloads.checkingAuth ? .working : .pending,
                                         downloads.checkingAuth ? "Checking…" : "Unknown")
            }
        }
        return SetupRow(state: state, title: "Apple Music sign-in", status: status,
                        detail: "gamdl asks a few questions in Terminal and saves your sign-in. Needs an Apple Music subscription.") {
            Button(downloads.savedAuth.map { $0 != .none } == true ? "Sign In Again…" : "Sign In…") {
                downloads.signInInTerminal()
            }
            .disabled(downloads.gamdlPath == nil || downloads.signInFlow == .waiting || setup.isRunning)
        }
    }

    private var losslessRow: some View {
        let wrapper = downloads.savedAuth?.isWrapper == true
        return SetupRow(state: wrapper ? .done : .optional, title: "Lossless (ALAC)",
                        status: wrapper ? "Signed in through Wrapper" : "Not set up",
                        detail: "Needs gamdl's Wrapper v2 sign-in, which runs separately in Docker. AAC and Dolby Atmos work without it.") {
            Button("About Wrapper") { NSWorkspace.shared.open(Gamdl.wrapperURL) }
        }
    }

    @ViewBuilder private func installButton(_ install: SetupController.Install, title: String) -> some View {
        if setup.installing == install {
            Button("Stop") { setup.stop() }
        } else {
            let blocked = setup.blockingReason(for: install)
            Button(title) { setup.install(install) }
                .disabled(blocked != nil)
                .help(blocked ?? "Runs: \(install.command)")
        }
    }

    private func located(_ tool: String, version: String?, at path: String) -> String {
        [version.map { "\(tool) \($0)" } ?? "Installed", (path as NSString).abbreviatingWithTildeInPath]
            .joined(separator: " · ")
    }
}

enum SetupState {
    case done, missing, warning, working, pending, optional
}

/// One requirement: whether it's met, what it is, and what you can do about it.
struct SetupRow<Actions: View>: View {
    let state: SetupState
    let title: String
    let status: String
    let detail: String
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon.frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(status).font(.callout).foregroundStyle(statusColor).textSelection(.enabled)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            actions.controlSize(.small)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var icon: some View {
        switch state {
        case .working: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Done")
        case .missing: Image(systemName: "xmark.circle.fill").foregroundStyle(.red).accessibilityLabel("Missing")
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityLabel("Needs attention")
        case .pending: Image(systemName: "circle.dashed").foregroundStyle(.secondary).accessibilityLabel("Waiting")
        case .optional: Image(systemName: "circle").foregroundStyle(.secondary).accessibilityLabel("Optional")
        }
    }

    private var statusColor: Color {
        switch state {
        case .done: .green
        case .missing: .red
        case .warning: .orange
        default: .secondary
        }
    }
}
