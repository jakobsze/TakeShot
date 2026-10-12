import Foundation
import QuartzCore
import ScreenCaptureKit
import AVFoundation

/// Orchestrates screen capture, camera/mic capture, cursor-shape sampling
/// and input-event tracking as one recording, writing everything into a
/// single project folder: screen.mov, webcam.mov (if any), events.json,
/// cursors.json + cursors/, project.json.
@MainActor
final class RecordingSession {
    private let screenEngine = ScreenCaptureEngine()
    private let webcamEngine = WebcamCaptureEngine.shared
    private let inputRecorder = InputEventRecorder()
    private let cursorRecorder = CursorShapeRecorder()

    private(set) var folder: URL?
    private var hasWebcam = false
    private var config: RecordingConfiguration?
    private var displayFrame: CGRect = .zero
    private var sessionStart: CFTimeInterval = 0
    private(set) var isPaused = false
    private var pausedTotal: CFTimeInterval = 0
    private var pauseStartedAt: CFTimeInterval?

    /// Seconds recorded so far, excluding pauses.
    var elapsed: Double {
        guard sessionStart > 0 else { return 0 }
        let now = CACurrentMediaTime()
        let currentPause = pauseStartedAt.map { now - $0 } ?? 0
        return now - sessionStart - pausedTotal - currentPause
    }

    func start(config: RecordingConfiguration) async throws {
        let folder = ProjectPaths.newProjectFolder()
        self.folder = folder
        self.config = config
        switch config.source {
        case .display(let display):
            displayFrame = display.frame
        case .window(let window):
            displayFrame = window.frame
        case .area(let display, let rect):
            displayFrame = CGRect(
                x: display.frame.origin.x + rect.origin.x,
                y: display.frame.origin.y + rect.origin.y,
                width: rect.width,
                height: rect.height
            )
        }

        InputEventRecorder.ensureAccessibilityPermission()

        sessionStart = CACurrentMediaTime()
        pausedTotal = 0
        pauseStartedAt = nil
        isPaused = false
        inputRecorder.start(sessionStart: sessionStart, recordKeystrokes: config.recordKeystrokes)
        cursorRecorder.start(folder: folder) { [inputRecorder] in inputRecorder.sessionTime() }

        try await screenEngine.start(source: config.source, config: config, outputURL: folder.appendingPathComponent("screen.mov"))

        hasWebcam = false
        if config.cameraDeviceID != nil || config.microphoneDeviceID != nil {
            do {
                try await webcamEngine.start(cameraID: config.cameraDeviceID, microphoneID: config.microphoneDeviceID,
                                             videoURL: folder.appendingPathComponent("webcam.mov"), audioURL: folder.appendingPathComponent("mic.m4a"))
                hasWebcam = true
            } catch {
                NSLog("Webcam/mic capture unavailable, continuing without: \(error)")
            }
        }
    }

    func pause() {
        guard !isPaused else { return }
        isPaused = true
        pauseStartedAt = CACurrentMediaTime()
        screenEngine.pause()
        webcamEngine.pause()
        inputRecorder.pause()
        cursorRecorder.setPaused(true)
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        if let started = pauseStartedAt { pausedTotal += CACurrentMediaTime() - started }
        pauseStartedAt = nil
        screenEngine.resume()
        webcamEngine.resume()
        inputRecorder.resume()
        cursorRecorder.setPaused(false)
    }

    /// Stops everything and deletes the project folder.
    func cancel() async {
        inputRecorder.stop()
        cursorRecorder.stop()
        await screenEngine.cancel()
        if hasWebcam { await webcamEngine.stop() }
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
    }

    func stop() async throws -> URL {
        guard let folder, let config else { throw NSError(domain: "RecordingSession", code: 1) }
        if isPaused { resume() }

        inputRecorder.stop()
        cursorRecorder.stop()
        try await screenEngine.stop()
        var webcamResult = WebcamCaptureEngine.Result()
        if hasWebcam {
            webcamResult = await webcamEngine.stop()
        }

        let events = inputRecorder.log
        let data = try JSONEncoder().encode(events)
        try data.write(to: folder.appendingPathComponent("events.json"))

        let screenAsset = AVURLAsset(url: folder.appendingPathComponent("screen.mov"))
        let duration = try await CMTimeGetSeconds(screenAsset.load(.duration))

        // Offsets that line the separate clocks up. Events and the camera
        // are both relative to `sessionStart` on the host clock; the screen
        // file's t=0 is its first captured frame.
        let screenOffset = (screenEngine.firstFramePTSSeconds ?? sessionStart) - sessionStart
        let webcamOffset = webcamResult.videoStartHostTime.map { ($0 - sessionStart) - screenOffset } ?? 0
        let micOffset = webcamResult.audioStartHostTime.map { ($0 - sessionStart) - screenOffset } ?? 0
        if config.cameraDeviceID != nil && webcamResult.videoURL == nil {
            NSLog("RecordingSession: camera was selected but no camera video was recorded")
        }

        var project = Project(
            name: ProjectPaths.defaultName(for: config.source),
            webcamFileName: webcamResult.videoURL?.lastPathComponent,
            duration: duration,
            displayFrameX: displayFrame.origin.x,
            displayFrameY: displayFrame.origin.y,
            displayFrameWidth: displayFrame.width,
            displayFrameHeight: displayFrame.height
        )
        project.screenOffset = screenOffset
        project.webcamOffset = webcamOffset
        project.micFileName = webcamResult.audioURL?.lastPathComponent
        project.micOffset = micOffset
        project.hasSystemAudio = screenEngine.hasAudio
        project.hasMicrophone = webcamResult.audioURL != nil
        project.hasCameraVideo = webcamResult.videoURL != nil
        project.style = AppSettings.shared.styleForNewProject()
        project.clips = [Clip(sourceStart: 0, sourceEnd: duration)]
        if AppSettings.shared.createAutomaticZooms {
            project.zoomRanges = AutoZoomGenerator.generate(events: events.events, project: project)
        }
        try project.save(to: folder)

        return folder
    }
}
