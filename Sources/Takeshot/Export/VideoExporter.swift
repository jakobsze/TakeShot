import Foundation
import AVFoundation
import AppKit
import CoreImage
import UniformTypeIdentifiers

/// Renders the edited project to a file. Uses the very same composition +
/// custom compositor as the live preview (just at export resolution and
/// with high-quality scaling), read sequentially through
/// AVAssetReaderVideoCompositionOutput — sequential decoding is what the
/// hardware decoder is fast at.
@MainActor
final class ExportJob: ObservableObject {
    enum Status: Equatable {
        case idle
        case running
        case finished(URL)
        case failed(String)
        case cancelled
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var progress: Double = 0
    /// True when this export was the user's 10th (shown once, ever).
    @Published var reachedSupportMilestone = false
    private let cancelFlag = CancelFlag()

    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
    }

    var isRunning: Bool { status == .running }

    func start(state: RenderState, settings: ExportSettings, destination: URL) {
        guard status != .running else { return }
        status = .running
        progress = 0
        cancelFlag.set(false)
        let flag = cancelFlag
        Task {
            do {
                let url = try await VideoExporter.export(state: state, settings: settings, destination: destination, cancel: flag) { p in
                    Task { @MainActor in self.progress = p }
                }
                reachedSupportMilestone = Support.recordExportAndCheckMilestone()
                status = .finished(url)
                progress = 1
            } catch VideoExporter.ExportError.cancelled {
                status = .cancelled
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        cancelFlag.set(true)
    }

    func reset() {
        status = .idle
        progress = 0
    }
}

/// Hands AVFoundation reader/writer objects (used from one queue at a
/// time) across concurrency boundaries.
struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

enum VideoExporter {
    enum ExportError: LocalizedError {
        case noVideoTrack
        case writerSetupFailed(String)
        case cancelled
        case readerFailed(String)

        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "The recording has no video."
            case .writerSetupFailed(let s): return "Couldn't set up the encoder: \(s)"
            case .cancelled: return "Cancelled"
            case .readerFailed(let s): return "Rendering failed: \(s)"
            }
        }
    }

    static func export(state: RenderState, settings: ExportSettings, destination: URL, cancel: ExportJob.CancelFlag,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let box = RenderStateBox(state, highQuality: true)
        var canvas = state.canvasSize(shortSide: CGFloat(settings.resolution.shortSide))
        let isGIF = settings.format == .gif
        if isGIF, canvas.width > CGFloat(settings.gifMaxWidth) {
            let s = CGFloat(settings.gifMaxWidth) / canvas.width
            canvas = CGSize(width: CGFloat(Int(canvas.width * s / 2) * 2), height: CGFloat(Int(canvas.height * s / 2) * 2))
        }
        let fps = isGIF ? settings.gifFps : settings.fps
        let built = try await CompositionBuilder.build(state: state, box: box, renderSize: canvas, fps: fps)
        // Readers get an immutable snapshot of the composition.
        let composition = built.composition.copy() as! AVComposition
        let duration = max(0.001, built.outputDuration)

        try? FileManager.default.removeItem(at: destination)

        let reader = try AVAssetReader(asset: composition)
        let videoTracks = try await composition.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw ExportError.noVideoTrack }
        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        videoOutput.videoComposition = built.videoComposition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw ExportError.readerFailed("video output") }
        reader.add(videoOutput)

        if isGIF {
            return try await writeGIF(reader: reader, output: videoOutput, destination: destination, fps: fps, duration: duration, cancel: cancel, progress: progress)
        }

        // Audio gets its own reader: combining an AVAssetReaderAudioMixOutput
        // with the custom-compositor video output in one reader was observed
        // to fail startReading() with -11800/-12710.
        let audioTracks = try await composition.loadTracks(withMediaType: .audio)
        let audioReader = try AVAssetReader(asset: composition)
        var audioOutput: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
            ])
            output.audioMix = built.audioMix
            output.audioTimePitchAlgorithm = .spectral
            if audioReader.canAdd(output) {
                audioReader.add(output)
                audioOutput = output
            }
        }

        let codec = settings.codec
        let fileType: AVFileType = (settings.format == .mov || codec == .prores) ? .mov : .mp4
        let writer = try AVAssetWriter(outputURL: destination, fileType: fileType)
        let width = Int(canvas.width), height = Int(canvas.height)
        var videoSettings: [String: Any] = [
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        switch codec {
        case .prores:
            videoSettings[AVVideoCodecKey] = AVVideoCodecType.proRes422
        case .h264, .hevc:
            videoSettings[AVVideoCodecKey] = codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264
            let bitrate = Double(width * height * fps) * settings.quality.bitsPerPixel * (codec == .hevc ? 0.7 : 1)
            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: Int(max(2_000_000, min(bitrate, 200_000_000))),
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
            ]
            if codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
            videoSettings[AVVideoCompressionPropertiesKey] = compression
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw ExportError.writerSetupFailed("video input") }
        writer.add(videoInput)

        if audioOutput != nil, !audioReader.startReading() {
            NSLog("VideoExporter: audio startReading failed: \(String(describing: audioReader.error))")
            audioOutput = nil
        }
        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48000,
                AVEncoderBitRateKey: 192_000,
            ])
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        guard reader.startReading() else {
            NSLog("VideoExporter: startReading failed: \(String(describing: reader.error))")
            throw ExportError.readerFailed(reader.error?.localizedDescription ?? "start")
        }
        guard writer.startWriting() else { throw ExportError.writerSetupFailed(writer.error?.localizedDescription ?? "start") }
        writer.startSession(atSourceTime: .zero)

        // Video and audio inputs on a multi-track AVAssetWriter must be fed
        // with roughly interleaved progress — writing one track to
        // completion before starting the other left `isReadyForMoreMediaData`
        // stuck false forever on the first track (it was implicitly waiting
        // on the other track to make comparable progress). Running both
        // loops concurrently via `async let` fixes this.
        let video = UncheckedBox((videoOutput, videoInput))
        let audio = UncheckedBox((audioOutput, audioInput))
        async let videoDone: Void = pump(input: video.value.1, cancel: cancel, label: "export.video") {
            guard let sample = video.value.0.copyNextSampleBuffer() else { return nil }
            let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            progress(min(0.999, t / duration))
            return sample
        }
        async let audioDone: Void = {
            guard let output = audio.value.0, let input = audio.value.1 else { return }
            try await pump(input: input, cancel: cancel, label: "export.audio") { output.copyNextSampleBuffer() }
        }()

        do {
            _ = try await (videoDone, audioDone)
        } catch {
            reader.cancelReading()
            audioReader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }

        if reader.status == .failed {
            writer.cancelWriting()
            NSLog("VideoExporter: reader failed: \(String(describing: reader.error)) underlying: \(String(describing: (reader.error as NSError?)?.userInfo))")
            throw ExportError.readerFailed(reader.error?.localizedDescription ?? "unknown")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw ExportError.writerSetupFailed(writer.error?.localizedDescription ?? "finish")
        }
        return destination
    }

    private static func pump(input: AVAssetWriterInput, cancel: ExportJob.CancelFlag, label: String, next: @escaping () -> CMSampleBuffer?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let queue = DispatchQueue(label: label)
            var finished = false
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData && !finished {
                    if cancel.isCancelled {
                        finished = true
                        input.markAsFinished()
                        continuation.resume(throwing: ExportError.cancelled)
                        return
                    }
                    guard let sample = next() else {
                        finished = true
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                    input.append(sample)
                }
            }
        }
    }

    private static func writeGIF(reader: AVAssetReader, output: AVAssetReaderVideoCompositionOutput, destination: URL, fps: Int,
                                 duration: Double, cancel: ExportJob.CancelFlag, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let frameCount = Int(duration * Double(fps)) + 1
        guard let dest = CGImageDestinationCreateWithURL(destination as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else {
            throw ExportError.writerSetupFailed("GIF destination")
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / Double(fps),
                                                          kCGImagePropertyGIFUnclampedDelayTime: 1.0 / Double(fps)]] as CFDictionary
        guard reader.startReading() else { throw ExportError.readerFailed(reader.error?.localizedDescription ?? "start") }
        let context = CIContext()
        try await Task.detached(priority: .userInitiated) {
            while let sample = output.copyNextSampleBuffer() {
                if cancel.isCancelled {
                    reader.cancelReading()
                    throw ExportError.cancelled
                }
                guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                let image = CIImage(cvPixelBuffer: buffer)
                if let cg = context.createCGImage(image, from: image.extent) {
                    CGImageDestinationAddImage(dest, cg, frameProps)
                }
                let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                progress(min(0.98, t / duration))
            }
        }.value
        guard CGImageDestinationFinalize(dest) else { throw ExportError.writerSetupFailed("GIF finalize") }
        return destination
    }
}
