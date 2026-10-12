import SwiftUI
import AppKit
import Sparkle

/// Automatic updates via Sparkle (https://sparkle-project.org).
///
/// The app checks the "appcast" feed named by `SUFeedURL` in Info.plist,
/// verifies each download against `SUPublicEDKey` (the private half lives
/// only in the developer's Keychain), and installs it. Until a feed URL is
/// configured the updater stays off and "Check for Updates…" explains why.
/// Releases are produced by `scripts/release.sh` (see AGENTS.md).
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    private var controller: SPUStandardUpdaterController?

    /// True once both the feed URL and the public signing key are set.
    static var isConfigured: Bool {
        func value(_ key: String) -> String {
            (Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "").trimmingCharacters(in: .whitespaces)
        }
        return !value("SUFeedURL").isEmpty && !value("SUPublicEDKey").isEmpty
    }

    /// Starts background update checks. Call once at launch (not in headless test modes).
    func start() {
        guard controller == nil, Self.isConfigured else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        objectWillChange.send()
    }

    func checkForUpdates() {
        guard let controller else {
            let alert = NSAlert()
            alert.messageText = "Updates aren't set up yet"
            alert.informativeText = "This build has no update feed. Set SUFeedURL in Resources/Info.plist to where appcast.xml is hosted, then publish a release with scripts/release.sh."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    var isRunning: Bool { controller != nil }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue; objectWillChange.send() }
    }

    var automaticallyDownloads: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue; objectWillChange.send() }
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
}

/// Settings rows for updates (General tab).
struct UpdateSettingsSection: View {
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        Section("Updates") {
            LabeledContent("Version") {
                HStack {
                    Text(updater.currentVersion).foregroundStyle(.secondary)
                    Button("Check for Updates…") { updater.checkForUpdates() }
                }
            }
            if updater.isRunning {
                Toggle("Check for updates automatically", isOn: Binding(get: { updater.automaticallyChecks }, set: { updater.automaticallyChecks = $0 }))
                Toggle("Download and install updates automatically", isOn: Binding(get: { updater.automaticallyDownloads }, set: { updater.automaticallyDownloads = $0 }))
                    .disabled(!updater.automaticallyChecks)
            } else {
                Text("Automatic updates aren't configured in this build yet.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
