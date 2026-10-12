import Foundation
import AVFoundation
import QuartzCore

/// Owns the single AVCaptureSession used for the camera preview bubble *and*
/// for recording camera/microphone to webcam.mov, so the camera is never
/// contended between two sessions.
///
/// Frames are written with our own AVAssetWriter from data outputs rather
/// than AVCaptureMovieFileOutput: the movie output was observed failing
/// with -11805 "Cannot Record" (never starting, or starting many seconds
/// late), which left recordings with no camera at all. Writing samples
/// ourselves also gives exact host-clock timestamps for syncing with the
/// screen, and pause/resume handled the same way as screen capture.
///
/// Session setup and `startRunning()`/`stopRunning()` are dispatched onto a
/// dedicated serial queue rather than the caller's thread — `startRunning()`
/// blocks synchronously, and doing that on the main thread while
/// ScreenCaptureEngine is simultaneously feeding a real-time H.264 encoder
/// starves it of main-run-loop time and reliably makes the screen encoder
/// fail mid-recording (AVFoundationErrorDomain -11800 / OSStatus -16122).
final class WebcamCaptureEngine: NSObject, @unchecked Sendable {
    static let shared = WebcamCaptureEngine()

    enum EngineError: Error {
        case deviceUnavailable
        case setupFailed
    }

    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let sessionQueue = DispatchQueue(label: "webcam.session.queue")
    private let dataQueue = DispatchQueue(label: "webcam.data.queue", qos: .userInitiated)
    private var currentCameraID: String?
    private var currentMicID: String?
    private var outputsAdded = false

    /// One output file (camera video or microphone audio). Camera and mic
    /// are written to separate files so a failing audio encoder (e.g. a
    /// Bluetooth headset switching formats mid-recording) can never take
    /// the camera video down with it.
    private final class TrackWriter {
        let url: URL
        let isVideo: Bool
        var writer: AVAssetWriter?
        var input: AVAssetWriterInput?
        var startPTS: CMTime?
        var startHostTime: CFTimeInterval?
        var samples = 0
        var failed = false
        var lastAppendedPTS: CMTime = .invalid
        init(url: URL, isVideo: Bool) { self.url = url; self.isVideo = isVideo }
    }

    // Recording state — only touched on dataQueue.
    private var videoWriter: TrackWriter?
    private var audioWriter: TrackWriter?
    private var recording = false
    private var paused = false
    /// Capture-clock time when the current pause began. Measured on the
    /// clock (not from the last sample of either track) so camera and mic
    /// shift by exactly the same amount and stay monotonic.
    private var pauseClockStart: CMTime?
    private var pausedOffset: CMTime = .zero

    struct Result {
        var videoURL: URL?
        var videoStartHostTime: CFTimeInterval?
        var audioURL: URL?
        var audioStartHostTime: CFTimeInterval?
    }

    override init() {
        super.init()
        NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { note in
            NSLog("WebcamCaptureEngine: session runtime error \(String(describing: note.userInfo?[AVCaptureSessionErrorKey]))")
        }
        NotificationCenter.default.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: nil) { _ in
            NSLog("WebcamCaptureEngine: session interrupted")
        }
    }

    static func availableCameras() -> [AVCaptureDevice] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) {
            types += [.continuityCamera, .external]
        }
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
    }

    static func availableMicrophones() -> [AVCaptureDevice] {
        if #available(macOS 14.0, *) {
            return AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
        } else {
            return AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInMicrophone], mediaType: .audio, position: .unspecified).devices
        }
    }

    /// (Re)configures inputs and makes sure the session is running. Safe to
    /// call repeatedly; only changes what differs.
    func configure(cameraID: String?, microphoneID: String?, completion: (() -> Void)? = nil) {
        sessionQueue.async { [self] in
            defer { completion?() }
            let unchanged = cameraID == currentCameraID && microphoneID == currentMicID
            if unchanged && (session.isRunning || (cameraID == nil && microphoneID == nil)) { return }
            session.beginConfiguration()
            if !unchanged {
                for input in session.inputs { session.removeInput(input) }
                if let cameraID, let device = AVCaptureDevice(uniqueID: cameraID) {
                    do {
                        let input = try AVCaptureDeviceInput(device: device)
                        if session.canAddInput(input) { session.addInput(input) }
                    } catch {
                        NSLog("WebcamCaptureEngine: camera input failed: \(error)")
                    }
                }
                if let microphoneID, let device = AVCaptureDevice(uniqueID: microphoneID) {
                    do {
                        let input = try AVCaptureDeviceInput(device: device)
                        if session.canAddInput(input) { session.addInput(input) }
                    } catch {
                        NSLog("WebcamCaptureEngine: microphone input failed: \(error)")
                    }
                }
            }
            if !outputsAdded {
                videoOutput.alwaysDiscardsLateVideoFrames = false
                videoOutput.setSampleBufferDelegate(self, queue: dataQueue)
                audioOutput.setSampleBufferDelegate(self, queue: dataQueue)
                // Deliver every mic as 48 kHz float. Letting the AAC writer
                // resample e.g. a 16 kHz Bluetooth headset produced audio
                // files twice as long as the recording.
                audioOutput.audioSettings = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 48000,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsNonInterleaved: false,
                ]
                if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
                if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }
                outputsAdded = true
            }
            if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
            session.commitConfiguration()
            currentCameraID = cameraID
            currentMicID = microphoneID
            if cameraID == nil && microphoneID == nil {
                if session.isRunning { session.stopRunning() }
            } else if !session.isRunning {
                session.startRunning()
            }
        }
    }

    func shutdown() {
        sessionQueue.async { [self] in
            let isRecording = dataQueue.sync { recording }

            guard !isRecording else { return }
            if session.isRunning { session.stopRunning() }
            currentCameraID = nil
            currentMicID = nil
        }
    }

    /// - Parameters:
    ///   - cameraID: `uniqueID` of the camera to record, or nil to skip video.
    ///   - microphoneID: `uniqueID` of the mic to record, or nil to skip audio.
    /// Doesn't wait for devices to come up: the screen recording starts
    /// right away and camera/mic files begin with their first sample (a
    /// Continuity Camera iPhone can take seconds to wake). Their start times
    /// are recorded, so they still line up with the screen.
    func start(cameraID: String?, microphoneID: String?, videoURL: URL, audioURL: URL) async throws {
        guard cameraID != nil || microphoneID != nil else { throw EngineError.deviceUnavailable }
        try? FileManager.default.removeItem(at: videoURL)
        try? FileManager.default.removeItem(at: audioURL)
        dataQueue.sync {
            videoWriter = cameraID != nil ? TrackWriter(url: videoURL, isVideo: true) : nil
            audioWriter = microphoneID != nil ? TrackWriter(url: audioURL, isVideo: false) : nil
            paused = false
            pauseClockStart = nil
            pausedOffset = .zero
            recording = true
        }
        configure(cameraID: cameraID, microphoneID: microphoneID)
    }

    func pause() {
        dataQueue.async { [self] in
            guard recording, !paused else { return }
            paused = true
            pauseClockStart = clockNow()
        }
    }

    func resume() {
        dataQueue.async { [self] in
            guard paused else { return }
            if let start = pauseClockStart {
                pausedOffset = CMTimeAdd(pausedOffset, CMTimeSubtract(clockNow(), start))
            }
            pauseClockStart = nil
            paused = false
        }
    }

    private func clockNow() -> CMTime {
        CMClockGetTime(CMClockGetHostTimeClock())
    }

    /// Finishes the files; only files that completed successfully are returned.
    func stop() async -> Result {
        let (video, audio): (TrackWriter?, TrackWriter?) = dataQueue.sync {
            recording = false
            defer { videoWriter = nil; audioWriter = nil }
            return (videoWriter, audioWriter)
        }
        var result = Result()
        if let video, await finish(video) {
            result.videoURL = video.url
            result.videoStartHostTime = video.startHostTime
        }
        if let audio, await finish(audio) {
            result.audioURL = audio.url
            result.audioStartHostTime = audio.startHostTime
        }
        return result
    }

    private func finish(_ track: TrackWriter) async -> Bool {
        let kind = track.isVideo ? "camera" : "microphone"
        guard let writer = track.writer, writer.status == .writing, track.samples > 0 else {
            NSLog("WebcamCaptureEngine: \(kind) not recorded (status \(track.writer?.status.rawValue ?? -1), samples \(track.samples), error \(String(describing: track.writer?.error)))")
            try? FileManager.default.removeItem(at: track.url)
            return false
        }
        track.input?.markAsFinished()
        await writer.finishWriting()
        NSLog("WebcamCaptureEngine: \(kind) finished status=\(writer.status.rawValue) samples=\(track.samples) error=\(String(describing: writer.error))")
        return writer.status == .completed
    }

    // MARK: - Writing (dataQueue)

    /// A sample's timestamp on the Mac's host clock (the clock the screen
    /// and input events use). Continuity Camera iPhones were observed
    /// stamping frames on their own clock (days off), so implausible
    /// timestamps fall back to arrival time.
    private func hostPTS(_ pts: CMTime) -> CMTime {
        let host = CMClockGetHostTimeClock()
        let now = CMClockGetTime(host)
        var converted = pts
        if #available(macOS 12.3, *), let clock = session.synchronizationClock {
            converted = CMSyncConvertTime(pts, from: clock, to: host)
        }
        let drift = abs(CMTimeGetSeconds(CMTimeSubtract(now, converted)))
        return drift < 1.0 ? converted : now
    }

    private func openWriter(_ track: TrackWriter, first: CMSampleBuffer) -> Bool {
        let fileType: AVFileType = track.isVideo ? .mov : .m4a
        guard let writer = try? AVAssetWriter(outputURL: track.url, fileType: fileType) else { return false }
        let input: AVAssetWriterInput
        if track.isVideo {
            guard let format = CMSampleBufferGetFormatDescription(first) else { return false }
            let dims = CMVideoFormatDescriptionGetDimensions(format)
            input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(dims.width),
                AVVideoHeightKey: Int(dims.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: max(4_000_000, Int(dims.width) * Int(dims.height) * 4),
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ],
            ])
        } else {
            input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 48000,
                AVEncoderBitRateKey: 128_000,
            ])
        }
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { return false }
        writer.add(input)
        guard writer.startWriting() else {
            NSLog("WebcamCaptureEngine: startWriting failed \(String(describing: writer.error))")
            return false
        }
        track.writer = writer
        track.input = input
        return true
    }

    private func handle(_ buffer: CMSampleBuffer, isVideo: Bool) {
        guard recording, CMSampleBufferDataIsReady(buffer), let track = isVideo ? videoWriter : audioWriter, !track.failed else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        if paused { return }
        // Shift onto the host clock and remove paused time in one retime.
        let target = CMTimeSubtract(hostPTS(pts), pausedOffset)
        let shift = CMTimeSubtract(pts, target)
        let sample = shift == .zero ? buffer : (Self.retimed(buffer, by: shift) ?? buffer)
        let samplePTS = CMSampleBufferGetPresentationTimeStamp(sample)

        if track.writer == nil {
            guard openWriter(track, first: sample), let writer = track.writer else {
                track.failed = true
                return
            }
            writer.startSession(atSourceTime: samplePTS)
            track.startPTS = samplePTS
            track.startHostTime = CMTimeGetSeconds(samplePTS)
        }
        guard let writer = track.writer, let input = track.input else { return }
        if writer.status == .failed {
            if !track.failed {
                track.failed = true
                NSLog("WebcamCaptureEngine: \(isVideo ? "camera" : "microphone") writer failed: \(String(describing: writer.error))")
            }
            return
        }
        guard writer.status == .writing, input.isReadyForMoreMediaData else { return }
        // Never hand the encoder a non-increasing timestamp (frames captured
        // just before a pause can land after the shifted resume point).
        if track.lastAppendedPTS.isValid, CMTimeCompare(samplePTS, track.lastAppendedPTS) <= 0 { return }
        if input.append(sample) {
            track.samples += 1
            track.lastAppendedPTS = samplePTS
        }
    }

    private static func retimed(_ buffer: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return nil }
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for i in 0..<count {
            timing[i].presentationTimeStamp = CMTimeSubtract(timing[i].presentationTimeStamp, offset)
            if timing[i].decodeTimeStamp.isValid {
                timing[i].decodeTimeStamp = CMTimeSubtract(timing[i].decodeTimeStamp, offset)
            }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: buffer, sampleTimingEntryCount: count, sampleTimingArray: &timing, sampleBufferOut: &out)
        return out
    }
}

extension WebcamCaptureEngine: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        handle(sampleBuffer, isVideo: output === videoOutput)
    }
}
