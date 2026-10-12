import Foundation
import AVFoundation
import CoreImage
import Vision

/// Thread-safe holder for the current RenderState. The editor swaps in a new
/// state after every edit; the compositor reads whatever is current, so a
/// paused preview just needs a re-seek to reflect changes.
final class RenderStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _state: RenderState
    private var _highQuality: Bool

    init(_ state: RenderState, highQuality: Bool) {
        _state = state
        _highQuality = highQuality
    }

    var state: RenderState {
        get { lock.lock(); defer { lock.unlock() }; return _state }
        set { lock.lock(); _state = newValue; lock.unlock() }
    }

    var highQuality: Bool {
        lock.lock(); defer { lock.unlock() }
        return _highQuality
    }
}

final class StudioInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let screenTrackID: CMPersistentTrackID
    let cameraTrackID: CMPersistentTrackID?
    let box: RenderStateBox

    init(timeRange: CMTimeRange, screenTrackID: CMPersistentTrackID, cameraTrackID: CMPersistentTrackID?, box: RenderStateBox) {
        self.timeRange = timeRange
        self.screenTrackID = screenTrackID
        self.cameraTrackID = cameraTrackID
        self.box = box
        var ids = [NSNumber(value: screenTrackID)]
        if let cameraTrackID { ids.append(NSNumber(value: cameraTrackID)) }
        self.requiredSourceTrackIDs = ids
    }
}

/// AVFoundation custom compositor: hands each output frame's source frames
/// to `FrameRenderer`. Used identically by the live preview (AVPlayer) and
/// export (AVAssetReaderVideoCompositionOutput).
final class StudioCompositor: NSObject, AVVideoCompositing {
    private static let pixelAttributes: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int](),
    ]

    var sourcePixelBufferAttributes: [String: any Sendable]? { Self.pixelAttributes }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] { Self.pixelAttributes }

    private let queue = DispatchQueue(label: "studio.compositor", qos: .userInitiated)
    private lazy var segmentation: VNGeneratePersonSegmentationRequest = {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }()
    private var cancelled = false
    private lazy var faceRequest = VNDetectFaceRectanglesRequest()
    private var faceFrameCounter = 0
    /// Smoothed face centre (normalized, bottom-left origin) in the camera image.
    private var faceCenter: CGPoint?
    /// Last camera frame seen, reused when the camera track has a gap (it
    /// starts a moment after the screen, or drops a frame) so the bubble
    /// doesn't flicker.
    private var lastCamera: (image: CIImage, mask: CIImage?)?

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { [self] in
            autoreleasepool {
                render(request)
            }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        queue.sync { cancelled = true }
        queue.async { [self] in cancelled = false }
    }

    /// Face detection every few frames, smoothed so the framing glides
    /// rather than jitters.
    private func updateFaceCenter(_ buffer: CVPixelBuffer) {
        faceFrameCounter += 1
        guard faceCenter == nil || faceFrameCounter % 4 == 0 else { return }
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, options: [:])
        guard (try? handler.perform([faceRequest])) != nil,
              let face = faceRequest.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }) else { return }
        let target = CGPoint(x: face.boundingBox.midX, y: face.boundingBox.midY)
        if let current = faceCenter {
            let k: CGFloat = 0.25
            faceCenter = CGPoint(x: current.x + (target.x - current.x) * k, y: current.y + (target.y - current.y) * k)
        } else {
            faceCenter = target
        }
    }

    private func render(_ request: AVAsynchronousVideoCompositionRequest) {
        if cancelled {
            request.finishCancelledRequest()
            return
        }
        guard let instruction = request.videoCompositionInstruction as? StudioInstruction,
              let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: NSError(domain: "StudioCompositor", code: 1))
            return
        }
        let state = instruction.box.state
        let screen = request.sourceFrame(byTrackID: instruction.screenTrackID).map { CIImage(cvPixelBuffer: $0) }
        var camera: CIImage?
        var cameraMask: CIImage?
        if let id = instruction.cameraTrackID, let buffer = request.sourceFrame(byTrackID: id) {
            camera = CIImage(cvPixelBuffer: buffer)
            if state.project.style.cameraAutoFrame {
                updateFaceCenter(buffer)
            }
            if state.project.style.cameraRemoveBackground {
                let handler = VNImageRequestHandler(cvPixelBuffer: buffer, options: [:])
                if (try? handler.perform([segmentation])) != nil, let mask = segmentation.results?.first?.pixelBuffer {
                    cameraMask = CIImage(cvPixelBuffer: mask)
                }
            }
        }
        if let camera {
            lastCamera = (camera, cameraMask)
        } else if instruction.cameraTrackID != nil, let last = lastCamera {
            camera = last.image
            cameraMask = last.mask
        }
        let size = request.renderContext.size
        let t = CMTimeGetSeconds(request.compositionTime)
        let image = FrameRenderer.shared.render(state: state, outputTime: t, screen: screen, camera: camera, cameraMask: cameraMask,
                                                cameraFocus: state.project.style.cameraAutoFrame ? faceCenter : nil,
                                                canvas: size, highQuality: instruction.box.highQuality)
        FrameRenderer.shared.context.render(image, to: output, bounds: CGRect(origin: .zero, size: size), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        request.finish(withComposedVideoFrame: output)
    }
}

/// Everything AVFoundation needs to play or export the edited project.
struct BuiltComposition {
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    let audioMix: AVMutableAudioMix
    let outputDuration: Double
}

enum CompositionBuilder {
    static let timescale: CMTimeScale = 60000

    static func time(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: timescale) }

    static func build(state: RenderState, box: RenderStateBox, renderSize: CGSize, fps: Int) async throws -> BuiltComposition {
        let project = state.project
        let folder = state.folder
        let style = project.style
        let composition = AVMutableComposition()

        let screenAsset = AVURLAsset(url: folder.appendingPathComponent(project.screenFileName))
        guard let screenVideo = try await screenAsset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "CompositionBuilder", code: 1, userInfo: [NSLocalizedDescriptionKey: "Recording has no video track"])
        }
        let screenAudio = try await screenAsset.loadTracks(withMediaType: .audio).first
        let screenRange = try await screenVideo.load(.timeRange)

        // AVAssetTrack doesn't retain its asset: the assets must outlive the
        // inserts below, or every insert fails with -12780.
        var webcamAsset: AVURLAsset?
        var micAsset: AVURLAsset?
        var cameraVideo: AVAssetTrack?
        var micAudio: AVAssetTrack?
        var webcamDuration = 0.0
        var micDuration = 0.0
        if let name = project.webcamFileName {
            let asset = AVURLAsset(url: folder.appendingPathComponent(name))
            webcamAsset = asset
            cameraVideo = try await asset.loadTracks(withMediaType: .video).first
            webcamDuration = try await CMTimeGetSeconds(asset.load(.duration))
        }
        if let mic = project.micSource {
            let enhanced = folder.appendingPathComponent(AudioTools.enhancedMicFileName)
            let useEnhanced = style.improveMicrophone && FileManager.default.fileExists(atPath: enhanced.path)
            let asset = AVURLAsset(url: useEnhanced ? enhanced : folder.appendingPathComponent(mic.fileName))
            micAsset = asset
            micAudio = try await asset.loadTracks(withMediaType: .audio).first
            micDuration = try await CMTimeGetSeconds(asset.load(.duration))
        }
        defer { withExtendedLifetime((screenAsset, webcamAsset, micAsset)) {} }

        let invalid = kCMPersistentTrackID_Invalid
        guard let compScreen = composition.addMutableTrack(withMediaType: .video, preferredTrackID: invalid) else {
            throw NSError(domain: "CompositionBuilder", code: 2)
        }
        let compSystem = screenAudio != nil ? composition.addMutableTrack(withMediaType: .audio, preferredTrackID: invalid) : nil
        let compCamera = cameraVideo != nil ? composition.addMutableTrack(withMediaType: .video, preferredTrackID: invalid) : nil
        let compMic = micAudio != nil ? composition.addMutableTrack(withMediaType: .audio, preferredTrackID: invalid) : nil

        let screenStart = CMTimeGetSeconds(screenRange.start)
        let screenEnd = CMTimeGetSeconds(screenRange.end)
        var cursor = 0.0
        var clipOutputStarts: [(Double, Clip)] = []

        // Every track gets explicit empty edits so it spans each clip range
        // exactly. Scaling a time range that runs past a track's last edit
        // (e.g. the mic stopping a few ms before the screen) leaves an
        // invalid edit list that later fails audio reads with -12710.
        var trackEnds: [CMPersistentTrackID: Double] = [:]
        func pad(_ track: AVMutableCompositionTrack?, to t: Double) {
            guard let track else { return }
            let end = trackEnds[track.trackID] ?? 0
            if t - end > 0.0005 {
                track.insertEmptyTimeRange(CMTimeRange(start: time(end), end: time(t)))
            }
            trackEnds[track.trackID] = max(end, t)
        }
        func insert(_ source: AVAssetTrack?, into track: AVMutableCompositionTrack?, from s0: Double, to s1: Double, at out: Double, limit: ClosedRange<Double>) {
            guard let source, let track else { return }
            let a = max(s0, limit.lowerBound), b = min(s1, limit.upperBound)
            guard b - a > 0.001 else { return }
            let at = out + (a - s0)
            pad(track, to: at)
            do {
                try track.insertTimeRange(CMTimeRange(start: time(a), end: time(b)), of: source, at: time(at))
                trackEnds[track.trackID] = at + (b - a)
            } catch {
                NSLog("CompositionBuilder: insert \(track.mediaType.rawValue) \(a)..\(b) at \(at) failed: \(error)")
            }
        }
        let allTracks = [compScreen, compSystem, compCamera, compMic]

        for entry in state.clipMap.entries {
            let clip = entry.clip
            let s0 = clip.sourceStart, s1 = clip.sourceEnd
            let dur = s1 - s0
            guard dur > 0.001 else { continue }
            clipOutputStarts.append((cursor, clip))
            insert(screenVideo, into: compScreen, from: s0 + screenStart, to: s1 + screenStart, at: cursor, limit: screenStart...screenEnd)
            insert(screenAudio, into: compSystem, from: s0 + screenStart, to: s1 + screenStart, at: cursor, limit: screenStart...screenEnd)
            let w0 = s0 - project.webcamOffset, w1 = s1 - project.webcamOffset
            // The camera usually starts a fraction of a second after the
            // screen; hold its first frame over that gap so the bubble is
            // there from the very first frame.
            if let cameraVideo, let compCamera, w0 < 0, w1 > 0.05 {
                let gap = min(-w0, dur)
                // Not the very first frame: cameras often deliver black frames
                // while exposure settles.
                let still = CMTimeRange(start: time(min(0.3, max(0, webcamDuration - 0.05))), duration: time(0.04))
                if (try? compCamera.insertTimeRange(still, of: cameraVideo, at: time(cursor))) != nil {
                    compCamera.scaleTimeRange(CMTimeRange(start: time(cursor), duration: time(0.04)), toDuration: time(gap))
                    trackEnds[compCamera.trackID] = cursor + gap
                }
            }
            insert(cameraVideo, into: compCamera, from: w0, to: w1, at: cursor, limit: 0...max(0, webcamDuration))
            let micOffset = project.micSource?.offset ?? 0
            insert(micAudio, into: compMic, from: s0 - micOffset, to: s1 - micOffset, at: cursor, limit: 0...max(0, micDuration))
            for track in allTracks { pad(track, to: cursor + dur) }
            if abs(clip.speed - 1) > 0.001 {
                let scaled = dur / clip.speed
                composition.scaleTimeRange(CMTimeRange(start: time(cursor), duration: time(dur)), toDuration: time(scaled))
                for track in allTracks { if let track { trackEnds[track.trackID] = cursor + scaled } }
                cursor += scaled
            } else {
                cursor += dur
            }
        }
        let outputDuration = cursor

        // Background music, looped to fill the edit.
        var musicTrack: AVMutableCompositionTrack?
        if let path = style.backgroundMusicPath, !style.muteBackgroundMusic, outputDuration > 0 {
            let musicAsset = AVURLAsset(url: URL(fileURLWithPath: path))
            if let source = try? await musicAsset.loadTracks(withMediaType: .audio).first,
               let musicDuration = try? await CMTimeGetSeconds(musicAsset.load(.duration)), musicDuration > 0.5,
               let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: invalid) {
                var at = 0.0
                while at < outputDuration - 0.01 {
                    let len = min(musicDuration, outputDuration - at)
                    try? track.insertTimeRange(CMTimeRange(start: .zero, duration: time(len)), of: source, at: time(at))
                    at += len
                }
                musicTrack = track
            }
        }

        // Synthetic click sounds at each (visible) click.
        var clickTracks: [AVMutableCompositionTrack] = []
        if style.clickSound, !style.hideCursor {
            let clickAsset = AVURLAsset(url: RenderAssets.clickSoundURL)
            if let source = try? await clickAsset.loadTracks(withMediaType: .audio).first,
               let clickDuration = try? await CMTimeGetSeconds(clickAsset.load(.duration)) {
                var trackEnds: [Double] = []
                for click in state.cursor.clicks {
                    guard let clip = state.clipMap.clip(atSource: click.t), !clip.hideCursor,
                          let out = state.clipMap.outputTime(atSource: click.t), out + clickDuration < outputDuration else { continue }
                    var index = trackEnds.firstIndex(where: { $0 <= out })
                    if index == nil, let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: invalid) {
                        clickTracks.append(track)
                        trackEnds.append(0)
                        index = clickTracks.count - 1
                    }
                    guard let i = index else { continue }
                    try? clickTracks[i].insertTimeRange(CMTimeRange(start: .zero, duration: time(clickDuration)), of: source, at: time(out))
                    trackEnds[i] = out + clickDuration + 0.005
                }
            }
        }

        // Audio mix.
        let master = style.masterVolume
        var params: [AVMutableAudioMixInputParameters] = []
        func perClip(_ track: AVMutableCompositionTrack?, base: Double) {
            guard let track else { return }
            let p = AVMutableAudioMixInputParameters(track: track)
            for (start, clip) in clipOutputStarts {
                p.setVolume(Float(base * clip.volume * master), at: time(start))
            }
            params.append(p)
        }
        perClip(compSystem, base: style.muteSystemAudio ? 0 : style.systemAudioVolume)
        perClip(compMic, base: style.muteMicrophone ? 0 : style.microphoneVolume)
        if let musicTrack {
            let p = AVMutableAudioMixInputParameters(track: musicTrack)
            p.setVolume(Float(style.backgroundMusicVolume * master), at: .zero)
            let fade = min(2.0, outputDuration / 4)
            p.setVolumeRamp(fromStartVolume: Float(style.backgroundMusicVolume * master), toEndVolume: 0,
                            timeRange: CMTimeRange(start: time(outputDuration - fade), duration: time(fade)))
            params.append(p)
        }
        for track in clickTracks {
            let p = AVMutableAudioMixInputParameters(track: track)
            p.setVolume(Float(style.clickSoundVolume * master), at: .zero)
            params.append(p)
        }
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = params

        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = StudioCompositor.self
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        let fullRange = CMTimeRange(start: .zero, duration: composition.duration)
        videoComposition.instructions = [StudioInstruction(timeRange: fullRange, screenTrackID: compScreen.trackID,
                                                           cameraTrackID: compCamera?.trackID, box: box)]

        return BuiltComposition(composition: composition, videoComposition: videoComposition, audioMix: audioMix, outputDuration: outputDuration)
    }
}
