import Foundation
import ScreenCaptureKit
import AVFoundation

enum CaptureSource {
    case display(SCDisplay)
    case window(SCWindow)
    /// `rect` is in the display's own local point space (top-left origin,
    /// matching `SCDisplay.frame`'s convention), as produced by
    /// `AreaSelectionOverlay`.
    case area(display: SCDisplay, rect: CGRect)
}

/// Captures a display, a single window or an area via ScreenCaptureKit and
/// muxes the frames (plus, optionally, system audio from the same stream)
/// into an .mov file. The system cursor is deliberately excluded
/// (`showsCursor = false`) — we draw our own cursor at render time so it can
/// be smoothed, resized and click-animated. This app's own windows (control
/// bar, recording widget, camera preview) are excluded from display/area
/// captures too.
final class ScreenCaptureEngine: NSObject {
    enum EngineError: Error {
        case noDisplay
        case writerSetupFailed
        case areaCaptureRequiresNewerMacOS
    }

    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var framesAppended = 0
    private var framesDropped = 0
    private let stateLock = NSLock()
    private var paused = false
    /// Host-clock time the current pause began. Pauses are measured on the
    /// clock, not from frame timestamps: with static content ScreenCaptureKit
    /// sends no frames, so frame gaps overstated pauses and shortened video.
    private var pauseHostStart: CMTime?
    /// Most recent screen frame, re-stamped at stop so a static ending isn't cut.
    private var lastScreenBuffer: CMSampleBuffer?
    private var frameInterval = CMTime(value: 1, timescale: 60)
    private var lastAppendedVideoPTS: CMTime = .invalid
    private var lastAppendedAudioPTS: CMTime = .invalid
    private var pausedOffset: CMTime = .zero

    private(set) var outputURL: URL?
    private(set) var hasAudio = false

    /// Host time (CACurrentMediaTime base, seconds) of the first frame written.
    private(set) var firstFramePTSSeconds: Double?

    func availableDisplays() async throws -> [SCDisplay] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return content.displays
    }

    /// On-screen, titled windows from other apps (excludes this app's own
    /// windows and small/system utility windows without a title).
    func availableWindows() async throws -> [SCWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let ownBundleID = Bundle.main.bundleIdentifier
        return content.windows.filter { window in
            guard let app = window.owningApplication, app.bundleIdentifier != ownBundleID else { return false }
            guard let title = window.title, !title.isEmpty else { return false }
            return window.frame.width > 100 && window.frame.height > 100 && window.windowLayer == 0
        }
    }

    /// Full 2x Retina resolution on a 5K+ display (e.g. 5120×2880) means
    /// ~59MB per raw BGRA frame churning through the pipeline at 30fps —
    /// observed to make the encoder fail outright under system memory
    /// pressure (`writer status .failed`, empty output file). Capping the
    /// longer edge trades a bit of sharpness on very high-res displays for
    /// a capture that reliably succeeds regardless of how loaded the Mac is.
    private static func cappedSize(width: Int, height: Int, maxDimension: Int) -> (width: Int, height: Int) {
        let maxDim = max(width, height)
        guard maxDim > maxDimension else { return ((width / 2) * 2, (height / 2) * 2) }
        let scale = Double(maxDimension) / Double(maxDim)
        let newWidth = (Int(Double(width) * scale) / 2) * 2
        let newHeight = (Int(Double(height) * scale) / 2) * 2
        return (max(2, newWidth), max(2, newHeight))
    }

    /// Windows to leave out of display/area captures: our own UI, and
    /// (optionally) Finder's desktop-icon layer.
    private func excludedWindows(hideDesktopIcons: Bool) async -> [SCWindow] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return [] }
        let ownBundleID = Bundle.main.bundleIdentifier
        return content.windows.filter { window in
            let bundle = window.owningApplication?.bundleIdentifier
            if bundle == ownBundleID { return true }
            if hideDesktopIcons, bundle == "com.apple.finder", window.windowLayer < 0 { return true }
            return false
        }
    }

    func start(source: CaptureSource, config recording: RecordingConfiguration, outputURL: URL) async throws {
        self.outputURL = outputURL
        let maxDimension = recording.highQuality ? 3840 : 2560
        let fps = max(15, min(60, recording.fps))
        frameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        lastAppendedVideoPTS = .invalid
        lastAppendedAudioPTS = .invalid

        let filter: SCContentFilter
        let pixelWidth: Int
        let pixelHeight: Int
        var areaSourceRect: CGRect?
        switch source {
        case .display(let display):
            filter = SCContentFilter(display: display, excludingWindows: await excludedWindows(hideDesktopIcons: recording.hideDesktopIcons))
            (pixelWidth, pixelHeight) = Self.cappedSize(width: display.width * 2, height: display.height * 2, maxDimension: maxDimension)
        case .window(let window):
            filter = SCContentFilter(desktopIndependentWindow: window)
            (pixelWidth, pixelHeight) = Self.cappedSize(width: max(2, Int(window.frame.width) * 2), height: max(2, Int(window.frame.height) * 2), maxDimension: maxDimension)
        case .area(let display, let rect):
            guard #available(macOS 14.0, *) else { throw EngineError.areaCaptureRequiresNewerMacOS }
            filter = SCContentFilter(display: display, excludingWindows: await excludedWindows(hideDesktopIcons: recording.hideDesktopIcons))
            (pixelWidth, pixelHeight) = Self.cappedSize(width: max(2, Int(rect.width) * 2), height: max(2, Int(rect.height) * 2), maxDimension: maxDimension)
            areaSourceRect = rect
        }

        let config = SCStreamConfiguration()
        config.width = pixelWidth
        config.height = pixelHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 8
        config.capturesAudio = recording.systemAudioEnabled
        config.excludesCurrentProcessAudio = true
        if let areaSourceRect, #available(macOS 14.0, *) {
            config.sourceRect = areaSourceRect
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let bitsPerPixel = recording.highQuality ? 0.2 : 0.12
        let bitrate = Int(Double(pixelWidth * pixelHeight * min(fps, 60)) * bitsPerPixel)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: pixelWidth,
            AVVideoHeightKey: pixelHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(8_000_000, min(bitrate, 80_000_000)),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw EngineError.writerSetupFailed }
        writer.add(input)

        var audioInput: AVAssetWriterInput?
        if recording.systemAudioEnabled {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48000,
                AVEncoderBitRateKey: 192_000,
            ]
            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            aInput.expectsMediaDataInRealTime = true
            if writer.canAdd(aInput) {
                writer.add(aInput)
                audioInput = aInput
            }
        }
        hasAudio = audioInput != nil

        writer.startWriting()

        self.assetWriter = writer
        self.videoInput = input
        self.audioInput = audioInput
        self.sessionStarted = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "screen.capture.video"))
        if recording.systemAudioEnabled {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "screen.capture.audio"))
        }
        try await stream.startCapture()
        self.stream = stream
    }

    func pause() {
        stateLock.lock()
        if !paused {
            paused = true
            pauseHostStart = CMClockGetTime(CMClockGetHostTimeClock())
        }
        stateLock.unlock()
    }

    func resume() {
        stateLock.lock()
        if paused, let start = pauseHostStart {
            pausedOffset = CMTimeAdd(pausedOffset, CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), start))
        }
        paused = false
        pauseHostStart = nil
        stateLock.unlock()
    }

    func stop() async throws {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        appendClosingFrame()
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        if let writer = assetWriter {
            if sessionStarted {
                await writer.finishWriting()
            } else {
                writer.cancelWriting()
            }
            if writer.status == .failed {
                NSLog("ScreenCaptureEngine: writer finished with FAILED status, error: \(String(describing: writer.error))")
            } else {
                NSLog("ScreenCaptureEngine: writer finished with status \(writer.status.rawValue), framesAppended=\(framesAppended) dropped=\(framesDropped)")
            }
        }
        assetWriter = nil
        videoInput = nil
        audioInput = nil
    }

    /// Repeats the last frame at the stop time so the video lasts as long as
    /// the recording even when the screen didn't change at the end.
    private func appendClosingFrame() {
        stateLock.lock()
        let end = CMTimeSubtract(pauseHostStart ?? CMClockGetTime(CMClockGetHostTimeClock()), pausedOffset)
        let last = lastScreenBuffer
        lastScreenBuffer = nil
        stateLock.unlock()
        guard sessionStarted, let last, let input = videoInput, lastAppendedVideoPTS.isValid,
              CMTimeCompare(end, CMTimeAdd(lastAppendedVideoPTS, frameInterval)) > 0 else { return }
        let shift = CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(last), end)
        guard let closing = Self.retimed(last, by: shift) else { return }
        for _ in 0..<50 where !input.isReadyForMoreMediaData { usleep(10_000) }
        if input.isReadyForMoreMediaData, input.append(closing) {
            framesAppended += 1
            lastAppendedVideoPTS = end
        }
    }

    /// Discards the output (used by Cancel/Restart).
    func cancel() async {
        if let stream { try? await stream.stopCapture() }
        stream = nil
        assetWriter?.cancelWriting()
        assetWriter = nil
        if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
    }
}

extension ScreenCaptureEngine: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        if type == .screen {
            // Skip status-only frames (idle/blank) that carry no image.
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let statusRaw = attachments.first?[.status] as? Int,
                  let status = SCFrameStatus(rawValue: statusRaw), status == .complete else { return }
        }
        if let writer = assetWriter, writer.status == .failed {
            NSLog("ScreenCaptureEngine: writer status .failed mid-stream: \(String(describing: writer.error))")
            return
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        stateLock.lock()
        if paused {
            stateLock.unlock()
            return
        }
        let offset = pausedOffset
        if type == .screen { lastScreenBuffer = sampleBuffer }
        stateLock.unlock()

        if !sessionStarted {
            guard type == .screen else { return }
            assetWriter?.startSession(atSourceTime: pts)
            sessionStarted = true
            firstFramePTSSeconds = CMTimeGetSeconds(pts)
        }

        let buffer = offset == .zero ? sampleBuffer : (Self.retimed(sampleBuffer, by: offset) ?? sampleBuffer)
        switch type {
        case .screen:
            let outPTS = CMSampleBufferGetPresentationTimeStamp(buffer)
            guard let input = videoInput, input.isReadyForMoreMediaData,
                  !lastAppendedVideoPTS.isValid || CMTimeCompare(outPTS, lastAppendedVideoPTS) > 0 else {
                framesDropped += 1
                return
            }
            if input.append(buffer) {
                framesAppended += 1
                lastAppendedVideoPTS = outPTS
            } else {
                framesDropped += 1
            }
        case .audio:
            let outPTS = CMSampleBufferGetPresentationTimeStamp(buffer)
            guard let input = audioInput, input.isReadyForMoreMediaData,
                  !lastAppendedAudioPTS.isValid || CMTimeCompare(outPTS, lastAppendedAudioPTS) > 0 else { return }
            if input.append(buffer) { lastAppendedAudioPTS = outPTS }
        default:
            break
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

extension ScreenCaptureEngine: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("ScreenCaptureEngine stream stopped with error: \(error)")
    }
}
