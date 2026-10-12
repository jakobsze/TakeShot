import SwiftUI
import AppKit
import ScreenCaptureKit
import AVFoundation

/// Process-wide (not per-view-instance) guard for the debug auto-open-editor
/// hook. `@State` on the view was NOT sufficient — multiple RecordControlBar
/// view instances were observed appearing (SwiftUI recreating the view /
/// firing onAppear on more than one instance), each with its own fresh
/// @State, so a per-instance flag didn't dedupe. This top-level var is
/// shared across any number of instances since it isn't tied to view identity.
private var hasAutoOpenedEditor = false
private var hasRunAutoRecordTest = false

enum SourceMode: String, CaseIterable {
    case display = "Display"
    case window = "Window"
    case area = "Area"
}

@MainActor
final class RecorderViewModel: ObservableObject {
    @Published var sourceMode: SourceMode = .display
    @Published var displays: [SCDisplay] = []
    @Published var windows: [SCWindow] = []
    @Published var selectedDisplayID: CGDirectDisplayID?
    @Published var selectedWindowID: CGWindowID?
    @Published var selectedAreaDisplay: SCDisplay?
    @Published var selectedAreaRect: CGRect?

    @Published var cameras: [AVCaptureDevice] = []
    @Published var microphones: [AVCaptureDevice] = []
    @Published var selectedCameraID: String? {
        didSet { updateCameraPreview() }
    }
    @Published var selectedMicrophoneID: String?
    @Published var systemAudioEnabled = false

    @Published var isRecording = false
    @Published var isPaused = false
    @Published var elapsed: Double = 0
    /// True while starting or stopping is in flight (stream/writer setup and
    /// teardown both take a moment) — drives a loading state in the UI so
    /// the record button doesn't look unresponsive, and blocks quitting
    /// mid-operation.
    @Published var isBusy = false
    @Published var statusMessage = ""
    @Published var lastRecordingURL: URL?

    /// Called directly (not via SwiftUI's `onChange`, which depends on the
    /// view still being "live" while the bar's window is hidden during
    /// recording) once a recording is saved, so the editor can be opened
    /// reliably.
    var onRecordingFinished: ((URL) -> Void)?

    private var session = RecordingSession()
    private let discoveryEngine = ScreenCaptureEngine()

    func loadDisplays() {
        Task {
            do {
                let displays = try await discoveryEngine.availableDisplays()
                self.displays = displays
                if selectedDisplayID == nil {
                    selectedDisplayID = displays.first?.displayID
                }
            } catch {
                statusMessage = "Failed to list displays: \(error.localizedDescription)"
            }
        }
    }

    func loadWindows() {
        Task {
            do {
                let windows = try await discoveryEngine.availableWindows()
                self.windows = windows
                if selectedWindowID == nil {
                    selectedWindowID = windows.first?.windowID
                }
            } catch {
                statusMessage = "Failed to list windows: \(error.localizedDescription)"
            }
        }
    }

    func loadDevices() {
        cameras = WebcamCaptureEngine.availableCameras()
        microphones = WebcamCaptureEngine.availableMicrophones()
    }

    func pickArea(startImmediately: Bool = false) {
        AreaSelectionOverlay.present { [weak self] result in
            guard let self, let (display, rect) = result else { return }
            self.selectedAreaDisplay = display
            self.selectedAreaRect = rect
            self.sourceMode = .area
            if startImmediately, !self.isRecording, !self.isBusy {
                self.toggleRecording()
            }
        }
    }

    /// Menu-bar "Record Display" quick action.
    func recordDisplayFromMenu() {
        guard !isRecording, !isBusy else { return }
        sourceMode = .display
        if selectedDisplayID == nil {
            selectedDisplayID = displays.first?.displayID
        }
        if canStartRecording {
            toggleRecording()
        }
    }

    /// Menu-bar "Record Window" quick action — brings the app forward so
    /// the user can pick a window if none is already selected, since there's
    /// no sensible way to guess which window they mean.
    func recordWindowFromMenu() {
        guard !isRecording, !isBusy else { return }
        sourceMode = .window
        if canStartRecording {
            toggleRecording()
        }
    }

    var canStartRecording: Bool {
        switch sourceMode {
        case .display: return selectedDisplayID != nil
        case .window: return !windows.isEmpty && selectedWindowID != nil
        case .area: return selectedAreaDisplay != nil && selectedAreaRect != nil
        }
    }

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private var elapsedTimer: Timer?
    private var countdownCancelled = false
    private var isCountingDown = false
    private var lastConfig: RecordingConfiguration?
    private var lastDisplayID: CGDirectDisplayID?

    /// Shows/hides the floating camera bubble so you can frame yourself
    /// before and during recording.
    func updateCameraPreview() {
        let engine = WebcamCaptureEngine.shared
        if let cameraID = selectedCameraID, AppSettings.shared.showCameraPreview {
            engine.configure(cameraID: cameraID, microphoneID: isRecording ? selectedMicrophoneID : nil)
            CameraPreviewWindow.show()
        } else {
            CameraPreviewWindow.hide()
            if !isRecording && !isBusy { engine.shutdown() }
        }
    }

    private func makeConfiguration() -> (RecordingConfiguration, CGDirectDisplayID?)? {
        let source: CaptureSource
        switch sourceMode {
        case .display:
            guard let display = displays.first(where: { $0.displayID == selectedDisplayID }) else {
                statusMessage = "No display selected"
                return nil
            }
            source = .display(display)
        case .window:
            guard let window = windows.first(where: { $0.windowID == selectedWindowID }) else {
                statusMessage = "No window selected"
                return nil
            }
            source = .window(window)
        case .area:
            guard let display = selectedAreaDisplay, let rect = selectedAreaRect else {
                statusMessage = "No area selected"
                return nil
            }
            source = .area(display: display, rect: rect)
        }

        let recordingDisplayID: CGDirectDisplayID?
        switch source {
        case .display(let display): recordingDisplayID = display.displayID
        case .area(let display, _): recordingDisplayID = display.displayID
        case .window: recordingDisplayID = nil
        }

        let settings = AppSettings.shared
        let config = RecordingConfiguration(
            source: source,
            cameraDeviceID: selectedCameraID,
            microphoneDeviceID: selectedMicrophoneID,
            systemAudioEnabled: systemAudioEnabled,
            fps: settings.recordingFps,
            hideDesktopIcons: settings.hideDesktopIcons,
            recordKeystrokes: settings.recordKeystrokes,
            highQuality: settings.highQualityCapture
        )
        return (config, recordingDisplayID)
    }

    /// Set by the debug auto-record hook to skip the countdown.
    var countdownOverride: Int?

    private func startRecording() {
        guard !isCountingDown, let (config, displayID) = makeConfiguration() else { return }
        begin(config: config, displayID: displayID, countdown: countdownOverride ?? AppSettings.shared.countdownSeconds)
    }

    private func begin(config: RecordingConfiguration, displayID: CGDirectDisplayID?, countdown: Int) {
        let settings = AppSettings.shared
        lastConfig = config
        lastDisplayID = displayID
        session = RecordingSession()
        isBusy = true
        countdownCancelled = false
        Task {
            AppDelegate.shared.hideMainWindow()
            isCountingDown = true
            let proceed = await CountdownOverlay.run(seconds: countdown, displayID: displayID, playSounds: settings.playRecordingSounds) { [weak self] in
                self?.countdownCancelled ?? true
            }
            isCountingDown = false
            guard proceed else {
                isBusy = false
                AppDelegate.shared.exitRecordingMode()
                return
            }
            do {
                try await session.start(config: config)
                if settings.playRecordingSounds { NSSound(named: "Pop")?.play() }
                isRecording = true
                isPaused = false
                elapsed = 0
                statusMessage = "Recording to \(session.folder?.path ?? "?")"
                switch config.source {
                case .display(let display):
                    NonRecordedDisplayOverlay.show(recordingDisplayID: display.displayID)
                case .area(let display, let rect):
                    NonRecordedDisplayOverlay.show(display: display, area: rect)
                case .window(let window):
                    NonRecordedDisplayOverlay.show(window: window)
                }
                if settings.showRecordingWidget {
                    RecordingWidget.show(recorder: self, displayID: displayID)
                }
                elapsedTimer?.invalidate()
                let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.elapsed = self.session.elapsed
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                elapsedTimer = timer
                AppDelegate.shared.enterRecordingMode(hideDock: settings.hideDockIconWhileRecording) { [weak self] in
                    self?.toggleRecording()
                }
            } catch {
                statusMessage = "Failed to start: \(error.localizedDescription)"
                AppDelegate.shared.exitRecordingMode()
            }
            isBusy = false
        }
    }

    private func tearDownRecordingUI() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        NonRecordedDisplayOverlay.hide()
        RecordingWidget.hide()
    }

    func togglePause() {
        guard isRecording, !isBusy else { return }
        if session.isPaused {
            session.resume()
        } else {
            session.pause()
        }
        isPaused = session.isPaused
    }

    /// Discards the current take.
    func cancelRecording() {
        if isCountingDown {
            countdownCancelled = true
            return
        }
        guard isRecording, !isBusy else { return }
        isBusy = true
        tearDownRecordingUI()
        Task {
            await session.cancel()
            isRecording = false
            isPaused = false
            isBusy = false
            statusMessage = "Recording discarded"
            AppDelegate.shared.exitRecordingMode()
            updateCameraPreview()
        }
    }

    /// Discards the current take and immediately starts a fresh one with the
    /// same settings (no countdown).
    func restartRecording() {
        guard isRecording, !isBusy, let config = lastConfig else { return }
        isBusy = true
        tearDownRecordingUI()
        let displayID = lastDisplayID
        Task {
            await session.cancel()
            isRecording = false
            isPaused = false
            isBusy = false
            begin(config: config, displayID: displayID, countdown: 0)
        }
    }

    private func stopRecording() {
        if isCountingDown {
            countdownCancelled = true
            return
        }
        isBusy = true
        tearDownRecordingUI()
        Task {
            do {
                let folder = try await session.stop()
                if AppSettings.shared.playRecordingSounds { NSSound(named: "Pop")?.play() }
                isRecording = false
                isPaused = false
                lastRecordingURL = folder
                statusMessage = "Saved to \(folder.path)"
                AppDelegate.shared.exitRecordingMode()
                isBusy = false
                updateCameraPreview()
                switch AppSettings.shared.afterRecording {
                case .openEditor: onRecordingFinished?(folder)
                case .revealInFinder: NSWorkspace.shared.activateFileViewerSelecting([folder])
                case .nothing: break
                }
            } catch {
                statusMessage = "Failed to stop cleanly: \(error.localizedDescription)"
                isRecording = false
                AppDelegate.shared.exitRecordingMode()
                isBusy = false
            }
        }
    }
}

@MainActor
enum ProjectPaths {
    static func moviesRoot() -> URL {
        AppSettings.shared.projectsFolder
    }

    static func latestProjectFolder() -> URL? {
        let root = moviesRoot()
        guard let folders = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        return folders
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent(Project.fileName).path) }
            .max(by: { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) })
    }

    static func newProjectFolder() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let folder = moviesRoot().appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @MainActor
    static func defaultName(for source: CaptureSource) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let stamp = formatter.string(from: Date())
        switch source {
        case .window(let window):
            return "\(window.owningApplication?.applicationName ?? "Window") \(stamp)"
        case .display:
            return "Screen \(stamp)"
        case .area:
            return "Area \(stamp)"
        }
    }
}

struct RecordControlBar: View {
    @StateObject private var recorder = RecorderViewModel()
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        captureBar
            .fixedSize()
            .modifier(SettingsOpenerInstaller())
            .onAppear {
                recorder.loadDisplays()
                recorder.loadWindows()
                recorder.loadDevices()
                AppDelegate.shared.configureMenuActions(MenuBarActions(
                    showMainWindow: {},
                    recordDisplay: { recorder.recordDisplayFromMenu() },
                    recordWindow: { recorder.recordWindowFromMenu() },
                    recordArea: { recorder.pickArea(startImmediately: true) },
                    showPreviousRecordings: { openWindow(id: "projects"); NSApp.activate(ignoringOtherApps: true) },
                    showSettings: { openAppSettings() }
                ))
                GlobalHotKeys.register { action in
                    switch action {
                    case .toggleRecording:
                        if recorder.isRecording || recorder.canStartRecording { recorder.toggleRecording() }
                    case .togglePause: recorder.togglePause()
                    case .cancel: recorder.cancelRecording()
                    }
                }
                recorder.updateCameraPreview()
                let env = ProcessInfo.processInfo.environment
                if let id = env["TAKESHOT_OPEN_WINDOW"] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        if id == "settings" { openAppSettings() } else { openWindow(id: id) }
                    }
                }
                if !hasAutoOpenedEditor,
                   env["TAKESHOT_AUTO_OPEN_EDITOR"] == "1",
                   let latest = env["TAKESHOT_AUTO_OPEN_EDITOR_PATH"].map({ URL(fileURLWithPath: $0) }) ?? ProjectPaths.latestProjectFolder() {
                    hasAutoOpenedEditor = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { openWindow(value: latest) }
                }
                if !hasRunAutoRecordTest, env["TAKESHOT_AUTO_RECORD_TEST"] == "1" {
                    hasRunAutoRecordTest = true
                    Task { await runRecordingSelfTest(env: env) }
                }
                // Nothing else in the UI surfaces a finished recording (the
                // bar is intentionally just the pill, no status text/buttons),
                // so jump straight to the editor once a recording is saved.
                // Called directly rather than via `onChange` since the bar's
                // window is hidden (ordered out) while recording, and a
                // hidden view's `onChange` firing reliably isn't something
                // to depend on.
                recorder.onRecordingFinished = { url in
                    openWindow(value: url)
                }
            }
    }

    /// Development self-test driven by environment variables:
    /// TAKESHOT_TEST_SOURCE=display|window|area, TAKESHOT_TEST_DISPLAY=<index>,
    /// TAKESHOT_TEST_CAMERA_NAME / TAKESHOT_TEST_MIC_NAME (substring), TAKESHOT_TEST_SYSAUDIO=1,
    /// TAKESHOT_TEST_KEYS=1 (posts a harmless F19 key), TAKESHOT_TEST_QUIT=1.
    @MainActor
    private func runRecordingSelfTest(env: [String: String]) async {
        recorder.countdownOverride = 0
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        recorder.loadDevices()
        if let name = env["TAKESHOT_TEST_CAMERA_NAME"] { recorder.selectedCameraID = recorder.cameras.first { $0.localizedName.contains(name) }?.uniqueID }
        if let name = env["TAKESHOT_TEST_MIC_NAME"] { recorder.selectedMicrophoneID = recorder.microphones.first { $0.localizedName.contains(name) }?.uniqueID }
        recorder.systemAudioEnabled = env["TAKESHOT_TEST_SYSAUDIO"] == "1"
        let displayIndex = Int(env["TAKESHOT_TEST_DISPLAY"] ?? "0") ?? 0
        let display = recorder.displays.indices.contains(displayIndex) ? recorder.displays[displayIndex] : recorder.displays.first
        switch env["TAKESHOT_TEST_SOURCE"] ?? "display" {
        case "window":
            recorder.sourceMode = .window
            recorder.selectedWindowID = recorder.windows.first?.windowID
        case "area":
            recorder.sourceMode = .area
            recorder.selectedAreaDisplay = display
            recorder.selectedAreaRect = CGRect(x: 200, y: 150, width: 960, height: 600)
        default:
            recorder.sourceMode = .display
            recorder.selectedDisplayID = display?.displayID
        }
        NSLog("AUTOTEST: config source=\(recorder.sourceMode.rawValue) display=\(display.map { "\($0.displayID) \($0.width)x\($0.height) \($0.frame)" } ?? "nil") window=\(recorder.windows.first.map { "\($0.owningApplication?.applicationName ?? "?") \($0.frame)" } ?? "nil") camera=\(recorder.cameras.first { $0.uniqueID == recorder.selectedCameraID }?.localizedName ?? "none") mic=\(recorder.microphones.first { $0.uniqueID == recorder.selectedMicrophoneID }?.localizedName ?? "none") sysAudio=\(recorder.systemAudioEnabled) displays=\(recorder.displays.count)")
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        NSLog("AUTOTEST: starting recording")
        recorder.toggleRecording()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        // Move the cursor across the recorded area (moves only, no clicks).
        var origin = CGEvent(source: nil)?.location ?? .zero
        if let display {
            origin = CGPoint(x: display.frame.midX - 120, y: display.frame.midY - 40)
            if recorder.sourceMode == .area { origin = CGPoint(x: display.frame.minX + 400, y: display.frame.minY + 300) }
            if recorder.sourceMode == .window, let w = recorder.windows.first { origin = CGPoint(x: w.frame.midX - 120, y: w.frame.midY) }
        }
        for i in 0..<50 {
            let p = CGPoint(x: origin.x + CGFloat(i) * 5, y: origin.y + CGFloat(i % 10) * 4)
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        if env["TAKESHOT_TEST_KEYS"] == "1" {
            for down in [true, false] {
                CGEvent(keyboardEventSource: nil, virtualKey: 80, keyDown: down)?.post(tap: .cghidEventTap)
            }
        }
        try? await Task.sleep(nanoseconds: 800_000_000)
        NSLog("AUTOTEST: pausing")
        recorder.togglePause()
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        NSLog("AUTOTEST: resuming")
        recorder.togglePause()
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        NSLog("AUTOTEST: stopping recording")
        recorder.toggleRecording()
        if env["TAKESHOT_TEST_QUIT"] == "1" {
            for _ in 0..<40 where recorder.isRecording || recorder.isBusy {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            NSLog("AUTOTEST: finished folder=\(recorder.lastRecordingURL?.path ?? "nil") status=\(recorder.statusMessage)")
            NSApp.terminate(nil)
        }
    }

    private var captureBar: some View {
        HStack(spacing: 0) {
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(recorder.isBusy)
            .help(recorder.isBusy ? "Please wait…" : "Quit Takeshot")
            .accessibilityLabel("Quit")
            .padding(.trailing, 6)

            // Grip: drag here (or any empty part of the pill) to move it.
            Image(systemName: "circle.grid.2x3.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 24)
                .contentShape(Rectangle())
                .help("Drag to move")
                .padding(.trailing, 6)

            Group {
                sourceMenuButton(mode: .display, systemImage: "display")
                sourceMenuButton(mode: .window, systemImage: "macwindow")
                areaButton

                barDivider

                deviceMenu(
                    systemImage: recorder.selectedCameraID == nil ? "video.slash" : "video",
                    label: recorder.cameras.first(where: { $0.uniqueID == recorder.selectedCameraID })?.localizedName ?? "No camera"
                ) {
                    ForEach(recorder.cameras, id: \.uniqueID) { device in
                        Button(device.localizedName) { recorder.selectedCameraID = device.uniqueID }
                    }
                    if !recorder.cameras.isEmpty { Divider() }
                    Button("Don't record camera") { recorder.selectedCameraID = nil }
                }
                deviceMenu(
                    systemImage: recorder.selectedMicrophoneID == nil ? "mic.slash" : "mic",
                    label: recorder.microphones.first(where: { $0.uniqueID == recorder.selectedMicrophoneID })?.localizedName ?? "No microphone"
                ) {
                    ForEach(recorder.microphones, id: \.uniqueID) { device in
                        Button(device.localizedName) { recorder.selectedMicrophoneID = device.uniqueID }
                    }
                    if !recorder.microphones.isEmpty { Divider() }
                    Button("Don't record microphone") { recorder.selectedMicrophoneID = nil }
                }
                deviceMenu(
                    systemImage: recorder.systemAudioEnabled ? "speaker.wave.2" : "speaker.slash",
                    label: recorder.systemAudioEnabled ? "System audio" : "No system audio"
                ) {
                    Button("Record system audio") { recorder.systemAudioEnabled = true }
                    Divider()
                    Button("Don't record system audio") { recorder.systemAudioEnabled = false }
                }

                barDivider

                Menu {
                    Picker("Countdown", selection: $settings.countdownSeconds) {
                        Text("No countdown").tag(0)
                        Text("3 seconds").tag(3)
                        Text("5 seconds").tag(5)
                        Text("10 seconds").tag(10)
                    }
                    Picker("Frame rate", selection: $settings.recordingFps) {
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                    }
                    Toggle("Hide desktop icons", isOn: $settings.hideDesktopIcons)
                    Toggle("Show camera preview", isOn: Binding(get: { settings.showCameraPreview }, set: { settings.showCameraPreview = $0; recorder.updateCameraPreview() }))
                    Toggle("Record keystrokes", isOn: $settings.recordKeystrokes)
                    Toggle("Automatic zooms", isOn: $settings.createAutomaticZooms)
                    Divider()
                    Toggle("Compact (icons only)", isOn: $settings.pillCompact)
                    Button("Reset position to bottom centre") { AppDelegate.shared.resetBarPosition() }
                        .disabled(settings.pillCenter == nil)
                    Divider()
                    Button("Recordings…") { openWindow(id: "projects"); NSApp.activate(ignoringOtherApps: true) }
                    Button("Settings…") { openAppSettings() }
                    Button("Check for Updates…") { AppUpdater.shared.checkForUpdates() }
                    Divider()
                    SupportButton()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .help("Recording options")
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .disabled(recorder.isRecording || recorder.isBusy)
            .opacity((recorder.isRecording || recorder.isBusy) ? 0.5 : 1)

            barDivider

            Button {
                recorder.toggleRecording()
            } label: {
                ZStack {
                    Image(systemName: recorder.isRecording ? "stop.circle.fill" : "record.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color(nsColor: .systemRed), Color.primary.opacity(0.14))
                        .font(.system(size: 28))
                        .opacity(recorder.isBusy ? 0 : 1)
                    if recorder.isBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(recorder.isRecording ? "Stop recording" : "Start recording")
            .disabled(recorder.isBusy || (!recorder.isRecording && !recorder.canStartRecording))
            .help(recorder.isBusy ? "Please wait…" : (recorder.isRecording ? "Stop Recording" : "Start Recording"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .floatingSurface(Capsule())
    }

    private var barDivider: some View {
        Divider()
            .frame(height: 22)
            .padding(.horizontal, 10)
    }

    /// Selected sources get the standard accent-tinted highlight.
    private func sourceLabel(_ title: String, systemImage: String, selected: Bool) -> some View {
        Label(title, systemImage: systemImage)
            .pillLabel(compact: settings.pillCompact)
            .lineLimit(1)
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .help(title)
    }

    /// The monitor's real name (e.g. "Built-in Retina Display", "DELL
    /// U2720Q") when macOS can tell us one, via the matching NSScreen —
    /// SCDisplay itself only exposes an opaque numeric ID. Falls back to a
    /// positional "Display N" if no NSScreen matches.
    private func displayLabel(_ display: SCDisplay) -> String {
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  CGDirectDisplayID(number.uint32Value) == display.displayID else { continue }
            let name = screen.localizedName
            if !name.isEmpty { return name }
        }
        if let index = recorder.displays.firstIndex(where: { $0.displayID == display.displayID }) {
            return "Display \(index + 1)"
        }
        return "Display"
    }

    private func windowLabel(_ window: SCWindow) -> String {
        window.owningApplication?.applicationName ?? window.title ?? "Window"
    }

    /// Display/Window: a menu when there's more than one option, otherwise a
    /// plain toggle button that just switches the capture mode. The label
    /// shows the specific chosen display/window once that mode is active,
    /// not just the generic mode name.
    private func sourceMenuButton(mode: SourceMode, systemImage: String) -> some View {
        let isSelected = recorder.sourceMode == mode
        let title: String = {
            guard isSelected else { return mode.rawValue }
            switch mode {
            case .display:
                if let display = recorder.displays.first(where: { $0.displayID == recorder.selectedDisplayID }) {
                    return displayLabel(display)
                }
            case .window:
                if let window = recorder.windows.first(where: { $0.windowID == recorder.selectedWindowID }) {
                    return windowLabel(window)
                }
            case .area:
                break
            }
            return mode.rawValue
        }()

        let stack = sourceLabel(title, systemImage: systemImage, selected: isSelected)

        return Group {
            if mode == .display {
                Menu {
                    ForEach(recorder.displays, id: \.displayID) { display in
                        Button {
                            recorder.sourceMode = .display
                            recorder.selectedDisplayID = display.displayID
                        } label: {
                            if display.displayID == recorder.selectedDisplayID && recorder.sourceMode == .display {
                                Label("\(displayLabel(display)) — \(display.width)×\(display.height)", systemImage: "checkmark")
                            } else {
                                Text("\(displayLabel(display)) — \(display.width)×\(display.height)")
                            }
                        }
                    }
                } label: { stack }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .sourceHighlight(isSelected)
            } else {
                Menu {
                    if recorder.windows.isEmpty {
                        Text("No windows found")
                    }
                    ForEach(recorder.windows, id: \.windowID) { window in
                        Button {
                            recorder.sourceMode = .window
                            recorder.selectedWindowID = window.windowID
                        } label: {
                            if window.windowID == recorder.selectedWindowID && recorder.sourceMode == .window {
                                Label(windowLabel(window), systemImage: "checkmark")
                            } else {
                                Text(windowLabel(window))
                            }
                        }
                    }
                } label: { stack }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .sourceHighlight(isSelected)
            }
        }
    }

    private var areaButton: some View {
        let isSelected = recorder.sourceMode == .area
        return Button {
            recorder.pickArea()
        } label: {
            sourceLabel("Area", systemImage: "rectangle.dashed", selected: isSelected)
        }
        .buttonStyle(.plain)
        .sourceHighlight(isSelected)
        .help(isSelected ? "Selected area — click to reselect" : "Drag to select a region to record")
    }

    @ViewBuilder
    private func deviceMenu<Content: View>(systemImage: String, label: String, @ViewBuilder items: () -> Content) -> some View {
        Menu {
            items()
        } label: {
            Label(label, systemImage: systemImage)
                .pillLabel(compact: settings.pillCompact)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(label)
        .padding(.trailing, settings.pillCompact ? 6 : 10)
    }
}

private extension View {
    /// Full "icon + name" label, or icon only in compact mode.
    @ViewBuilder
    func pillLabel(compact: Bool) -> some View {
        if compact {
            self.labelStyle(.iconOnly).font(.body)
        } else {
            self.labelStyle(.titleAndIcon).font(.callout)
        }
    }

    /// Accent-tinted capsule behind the selected capture source.
    func sourceHighlight(_ selected: Bool) -> some View {
        padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(selected ? Color.accentColor.opacity(0.22) : .clear))
            .overlay(Capsule().strokeBorder(selected ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1))
    }
}
