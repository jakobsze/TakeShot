import Foundation
import SwiftUI
import ServiceManagement

enum AfterRecordingAction: String, CaseIterable {
    case openEditor, revealInFinder, nothing
    var label: String {
        switch self {
        case .openEditor: return "Open editor"
        case .revealInFinder: return "Show in Finder"
        case .nothing: return "Do nothing"
        }
    }
}

/// App-wide preferences (as opposed to per-project `StyleConfig`), stored in
/// UserDefaults via @AppStorage-style properties.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    @Published var projectsFolderPath: String { didSet { defaults.set(projectsFolderPath, forKey: "projectsFolderPath") } }
    @Published var countdownSeconds: Int { didSet { defaults.set(countdownSeconds, forKey: "countdownSeconds") } }
    @Published var recordingFps: Int { didSet { defaults.set(recordingFps, forKey: "recordingFps") } }
    @Published var hideDesktopIcons: Bool { didSet { defaults.set(hideDesktopIcons, forKey: "hideDesktopIcons") } }
    @Published var hideDockIconWhileRecording: Bool { didSet { defaults.set(hideDockIconWhileRecording, forKey: "hideDockIconWhileRecording") } }
    @Published var showRecordingWidget: Bool { didSet { defaults.set(showRecordingWidget, forKey: "showRecordingWidget") } }
    @Published var createAutomaticZooms: Bool { didSet { defaults.set(createAutomaticZooms, forKey: "createAutomaticZooms") } }
    @Published var recordKeystrokes: Bool { didSet { defaults.set(recordKeystrokes, forKey: "recordKeystrokes") } }
    @Published var showCameraPreview: Bool { didSet { defaults.set(showCameraPreview, forKey: "showCameraPreview") } }
    @Published var playRecordingSounds: Bool { didSet { defaults.set(playRecordingSounds, forKey: "playRecordingSounds") } }
    @Published var highQualityCapture: Bool { didSet { defaults.set(highQualityCapture, forKey: "highQualityCapture") } }
    @Published var afterRecording: AfterRecordingAction { didSet { defaults.set(afterRecording.rawValue, forKey: "afterRecording") } }
    @Published var defaultPresetName: String? { didSet { defaults.set(defaultPresetName, forKey: "defaultPresetName") } }
    @Published var useLastStyleForNewProjects: Bool { didSet { defaults.set(useLastStyleForNewProjects, forKey: "useLastStyleForNewProjects") } }
    /// Recording pill shows icons only (names appear as tooltips and in the menus).
    @Published var pillCompact: Bool { didSet { defaults.set(pillCompact, forKey: "pillCompact") } }
    /// Where the user dragged the pill (its centre, in screen coordinates);
    /// nil means the default spot: bottom centre of the main display.
    @Published var pillCenter: CGPoint? {
        didSet {
            if let pillCenter {
                defaults.set([Double(pillCenter.x), Double(pillCenter.y)], forKey: "pillCenter")
            } else {
                defaults.removeObject(forKey: "pillCenter")
            }
        }
    }
    /// Edge/corner the pill is docked to (left/right = vertical pill); nil
    /// means it is free (`pillCenter`) or at the default spot.
    @Published var pillDock: PillDock? {
        didSet {
            if let pillDock, let data = try? JSONEncoder().encode(pillDock) {
                defaults.set(data, forKey: "pillDock")
            } else {
                defaults.removeObject(forKey: "pillDock")
            }
        }
    }
    @Published var showInDock: Bool {
        didSet {
            defaults.set(showInDock, forKey: "showInDock")
            NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
        }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("Launch at login change failed: \(error)")
            }
        }
    }

    private init() {
        let moviesDefault = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Takeshot", isDirectory: true).path
        defaults.register(defaults: [
            "projectsFolderPath": moviesDefault,
            "countdownSeconds": 3,
            "recordingFps": 60,
            "hideDesktopIcons": false,
            "hideDockIconWhileRecording": true,
            "showRecordingWidget": true,
            "createAutomaticZooms": true,
            "recordKeystrokes": true,
            "showCameraPreview": true,
            "playRecordingSounds": true,
            "highQualityCapture": true,
            "afterRecording": AfterRecordingAction.openEditor.rawValue,
            "useLastStyleForNewProjects": false,
            "showInDock": true,
        ])
        projectsFolderPath = defaults.string(forKey: "projectsFolderPath") ?? moviesDefault
        countdownSeconds = defaults.integer(forKey: "countdownSeconds")
        recordingFps = defaults.integer(forKey: "recordingFps")
        hideDesktopIcons = defaults.bool(forKey: "hideDesktopIcons")
        hideDockIconWhileRecording = defaults.bool(forKey: "hideDockIconWhileRecording")
        showRecordingWidget = defaults.bool(forKey: "showRecordingWidget")
        createAutomaticZooms = defaults.bool(forKey: "createAutomaticZooms")
        recordKeystrokes = defaults.bool(forKey: "recordKeystrokes")
        showCameraPreview = defaults.bool(forKey: "showCameraPreview")
        playRecordingSounds = defaults.bool(forKey: "playRecordingSounds")
        highQualityCapture = defaults.bool(forKey: "highQualityCapture")
        afterRecording = AfterRecordingAction(rawValue: defaults.string(forKey: "afterRecording") ?? "") ?? .openEditor
        defaultPresetName = defaults.string(forKey: "defaultPresetName")
        useLastStyleForNewProjects = defaults.bool(forKey: "useLastStyleForNewProjects")
        pillCompact = defaults.bool(forKey: "pillCompact")
        if let saved = defaults.array(forKey: "pillCenter") as? [Double], saved.count == 2 {
            pillCenter = CGPoint(x: saved[0], y: saved[1])
        } else {
            pillCenter = nil
        }
        pillDock = defaults.data(forKey: "pillDock").flatMap { try? JSONDecoder().decode(PillDock.self, from: $0) }
        showInDock = defaults.bool(forKey: "showInDock")
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    var projectsFolder: URL {
        let url = URL(fileURLWithPath: projectsFolderPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Style used for new projects

    private var lastStyleURL: URL { PresetStore.supportFolder.appendingPathComponent("last-style.json") }

    func rememberLastStyle(_ style: StyleConfig) {
        guard let data = try? JSONEncoder().encode(style) else { return }
        try? data.write(to: lastStyleURL, options: .atomic)
    }

    /// The style a brand-new recording starts with: the chosen default
    /// preset, else (if enabled) the last edited project's style, else the
    /// built-in defaults.
    func styleForNewProject() -> StyleConfig {
        if let name = defaultPresetName, let preset = PresetStore.load(name: name) {
            return preset
        }
        if useLastStyleForNewProjects, let data = try? Data(contentsOf: lastStyleURL),
           let style = try? StyleConfig.decodeLenient(from: data) {
            var s = style
            s.cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            return s
        }
        return StyleConfig()
    }
}

/// Named style presets saved as JSON files in Application Support.
enum PresetStore {
    static var supportFolder: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Takeshot", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var folder: URL {
        let url = supportFolder.appendingPathComponent("Presets", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func names() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func load(name: String) -> StyleConfig? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("\(name).json")) else { return nil }
        return try? StyleConfig.decodeLenient(from: data)
    }

    static func save(_ style: StyleConfig, name: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(style) else { return }
        try? data.write(to: folder.appendingPathComponent("\(sanitized(name)).json"), options: .atomic)
    }

    static func delete(name: String) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(name).json"))
    }

    static func sanitized(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }
}
