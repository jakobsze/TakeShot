import Foundation
import AppKit
import AVFoundation
import ImageIO

/// Development QA harness (TAKESHOT_QA=<project folder>, TAKESHOT_QA_PARTS=options,audio,export,edits).
/// Verifies every style option visibly changes the render, audio options
/// change the mix, every export setting produces a valid file, and editing
/// operations behave. Results are logged as "QA: PASS/FAIL ..." lines.
@MainActor
enum TestHarness {
    static func runIfRequested() -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["TAKESHOT_QA"] else { return false }
        let parts = Set((env["TAKESHOT_QA_PARTS"] ?? "options,audio,export,edits").split(separator: ",").map(String.init))
        Task {
            var failures = 0
            do {
                let folder = URL(fileURLWithPath: path)
                if parts.contains("options") { failures += try await optionsTest(folder: folder) }
                if parts.contains("audio") { failures += try await audioTest(folder: folder) }
                if parts.contains("export") { failures += try await exportTest(folder: folder) }
                if parts.contains("edits") { failures += try await editsTest(folder: folder) }
            } catch {
                log("FAIL harness error \(error)")
                failures += 1
            }
            log("DONE failures=\(failures)")
            exit(failures == 0 ? 0 : 2)
        }
        return true
    }

    private static func log(_ s: String) { NSLog("QA: \(s)") }

    // MARK: - Rendering helpers

    private static func makeState(_ base: EditorModel, _ project: Project) -> RenderState {
        let (logFile, images) = RenderAssets.loadRecordedCursors(folder: base.folder)
        return RenderState(project: project, folder: base.folder, events: base.events, cursorLog: logFile, cursorImages: images,
                           defaultArrow: RenderAssets.defaultArrow, recordingSize: base.renderState.recordingSize)
    }

    private static func renderFrames(_ state: RenderState, times: [Double]) async throws -> [CGImage] {
        let canvas = state.canvasSize(shortSide: 360)
        let built = try await CompositionBuilder.build(state: state, box: RenderStateBox(state, highQuality: false), renderSize: canvas, fps: 30)
        let gen = AVAssetImageGenerator(asset: built.composition)
        gen.videoComposition = built.videoComposition
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        var images: [CGImage] = []
        for t in times {
            images.append(try await gen.image(at: CMTime(seconds: min(t, built.outputDuration - 0.05), preferredTimescale: 600)).image)
        }
        return images
    }

    /// Number of pixels (at 320×180) whose colour changed noticeably —
    /// sensitive to small local changes like the cursor, unlike a mean.
    private static func diff(_ a: CGImage, _ b: CGImage) -> Double {
        if a.width != b.width || a.height != b.height { return 99999 }
        let w = 320, h = 180
        func pixels(_ img: CGImage) -> [UInt8] {
            var buf = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return buf
        }
        let pa = pixels(a), pb = pixels(b)
        var changed = 0
        for px in 0..<(w * h) {
            let o = px * 4
            let d = abs(Int(pa[o]) - Int(pb[o])) + abs(Int(pa[o + 1]) - Int(pb[o + 1])) + abs(Int(pa[o + 2]) - Int(pb[o + 2]))
            if d > 36 { changed += 1 }
        }
        return Double(changed)
    }

    // MARK: - Options

    private static func optionsTest(folder: URL) async throws -> Int {
        let model = try await EditorModel.load(folder: folder)
        var base = model.project
        let d = base.duration
        // A known baseline that makes every option observable.
        base.clips = [Clip(sourceStart: 0, sourceEnd: d)]
        base.style = StyleConfig()
        base.style.backgroundType = .gradient
        base.style.motionBlurPan = 0
        base.style.motionBlurZoom = 0
        base.style.motionBlurCursor = 0
        base.style.showCaptions = false
        base.style.cursorSize = 4
        base.zoomRanges = [ZoomRange(start: d * 0.45, end: d * 0.8, scale: 2, mode: .auto)]
        base.masks = []
        base.layouts = []
        base.captions = []
        let baseState = makeState(model, base)
        let clickT = baseState.cursor.clicks.first.map { $0.t + 0.08 }
        let moving = movingTime(baseState, duration: d)
        // Times: plain frame, zoomed frame, moving cursor, (click), near end.
        // plus two mid-transition frames (zoom-in of the main range, and the
        // instant-zoom case's start).
        var times = [d * 0.2, d * 0.65, moving, d - 0.25, d * 0.45 + 0.2, d * 0.6 + 0.12]
        if let clickT { times.append(clickT) }
        let baseline = try await renderFrames(baseState, times: times)
        log("INFO options baseline duration=\(String(format: "%.1f", d)) camera=\(base.hasCameraVideo) clicks=\(baseState.cursor.clicks.count) keys=\(model.events.filter { $0.kind == .keyDown }.count) movingAt=\(String(format: "%.2f", moving))")

        typealias Mut = (inout Project) -> Void
        var cases: [(String, Mut)] = [
            ("bg.color", { $0.style.backgroundType = .color; $0.style.backgroundColorHex = "FF0000" }),
            ("bg.gradientPreset", { $0.style.gradient = GradientSpec.presets[3] }),
            ("bg.gradientAngle", { $0.style.gradient.angle = 200 }),
            ("bg.wallpaper", { $0.style.backgroundType = .wallpaper; $0.style.wallpaperPath = Wallpaper.all.first?.path }),
            ("bg.image", { $0.style.backgroundType = .image; $0.style.backgroundImagePath = Wallpaper.all.last?.path }),
            ("bg.blur", { $0.style.backgroundType = .wallpaper; $0.style.wallpaperPath = Wallpaper.all.first?.path; $0.style.backgroundBlur = 1 }),
            ("frame.padding", { $0.style.padding = 0.25 }),
            ("frame.cornerRadius", { $0.style.cornerRadius = 80 }),
            ("frame.inset", { $0.style.insetPadding = 40; $0.style.insetColorHex = "FF0000" }),
            ("frame.insetAlpha", { $0.style.insetPadding = 40; $0.style.insetColorHex = "FFFFFF"; $0.style.insetAlpha = 0.2 }),
            ("frame.macLight", { $0.style.windowFrame = .macLight }),
            ("frame.macDark", { $0.style.windowFrame = .macDark }),
            ("frame.glass", { $0.style.windowFrame = .glass }),
            ("frame.aspect9x16", { $0.style.aspectRatio = .r9x16 }),
            ("frame.aspect1x1", { $0.style.aspectRatio = .r1x1 }),
            ("frame.crop", { $0.style.cropRect = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5) }),
            ("shadow.off", { $0.style.shadowIntensity = 0 }),
            ("shadow.angle", { $0.style.shadowAngle = 0; $0.style.shadowDistance = 60 }),
            ("shadow.distance", { $0.style.shadowDistance = 80 }),
            ("shadow.blur", { $0.style.shadowBlur = 120 }),
            ("cursor.hide", { $0.style.hideCursor = true }),
            ("cursor.arrowVsTouch", { $0.style.cursorStyle = .touch }),
            ("cursor.small", { $0.style.cursorSize = 1.5 }),
            ("cursor.large", { $0.style.cursorSize = 7 }),
            ("cursor.tilt", { $0.style.cursorTilt = 1 }),
            ("cursor.noSmoothing", { $0.style.smoothCursor = false }),
            ("cursor.springRapid", { $0.style.cursorSpring = SpringConfig.cursorPresets[3].1 }),
            ("cursor.hideIdle", { $0.style.hideIdleCursor = true; $0.style.idleCursorDelay = 0.5 }),
            ("cursor.loopAtEnd", { $0.style.loopCursorAtEnd = true }),
            ("cursor.motionBlur", { $0.style.motionBlurCursor = 1 }),
            ("zoom.alwaysZoomedIn", { $0.style.alwaysKeepZoomedIn = true; $0.zoomRanges.insert(ZoomRange(start: 0.05, end: d * 0.1, scale: 2), at: 0) }),
            ("zoom.scale", { $0.zoomRanges[$0.zoomRanges.count - 1].scale = 3.5 }),
            ("zoom.manualTarget", { $0.zoomRanges[$0.zoomRanges.count - 1].mode = .manual; $0.zoomRanges[$0.zoomRanges.count - 1].targetX = 0.05; $0.zoomRanges[$0.zoomRanges.count - 1].targetY = 0.95 }),
            ("zoom.disabled", { $0.zoomRanges[$0.zoomRanges.count - 1].disabled = true }),
            ("zoom.instant", { $0.zoomRanges = [ZoomRange(start: d * 0.6, end: d * 0.8, scale: 2, instant: true)] }),
            ("zoom.springSlow", { $0.style.zoomSpring = SpringConfig.cameraPresets[0].1 }),
            ("mask.blur", { $0.masks = [MaskRange(start: 0, end: d, kind: .blur, x: 0.2, y: 0.2, w: 0.6, h: 0.6, intensity: 1)] }),
            ("mask.pixelate", { $0.masks = [MaskRange(start: 0, end: d, kind: .pixelate, x: 0.2, y: 0.2, w: 0.6, h: 0.6, intensity: 1)] }),
            ("mask.spotlight", { $0.masks = [MaskRange(start: 0, end: d, kind: .highlight, x: 0.4, y: 0.4, w: 0.2, h: 0.2, intensity: 1)] }),
            ("captions.show", { $0.captions = [CaptionSegment(start: 0, end: d, text: "QA caption line")]; $0.style.showCaptions = true }),
            ("captions.size", { $0.captions = [CaptionSegment(start: 0, end: d, text: "QA caption line")]; $0.style.showCaptions = true; $0.style.captionsSize = 2.2 }),
            ("clip.hideCursor", { $0.clips[0].hideCursor = true }),
            ("clip.speed", { $0.clips[0].speed = 2 }),
        ]
        if clickT != nil {
            cases.append(("click.noEffect", { $0.style.clickEffect = .none }))
            cases.append(("click.rippleColor", { $0.style.rippleColorHex = "FF0000" }))
        }
        if model.events.contains(where: { $0.kind == .keyDown }) {
            cases.append(("keys.showShortcuts", { $0.style.showShortcuts = true; $0.style.shortcutsSingleLetters = true; $0.style.shortcutsSize = 2 }))
        }
        if base.hasCameraVideo {
            cases += [
                ("camera.hide", { $0.style.hideCamera = true }),
                ("camera.mirror", { $0.style.mirrorCamera = false }),
                ("camera.square", { $0.style.cameraRoundness = 0 }),
                ("camera.size", { $0.style.cameraSize = 0.55 }),
                ("camera.topLeft", { $0.style.cameraCorner = .topLeft }),
                ("camera.custom", { $0.style.cameraCorner = .custom; $0.style.cameraCustomX = 0.3; $0.style.cameraCustomY = 0.3 }),
                ("camera.scaleOnZoom", { $0.style.cameraScaleDuringZoom = 0.3 }),
                ("camera.aspectLandscape", { $0.style.cameraAspect = .landscape }),
                ("camera.aspectPortrait", { $0.style.cameraAspect = .portrait }),
                ("camera.removeBackground", { $0.style.cameraRemoveBackground = true }),
                ("camera.autoFrameOff", { $0.style.cameraAutoFrame = false; $0.style.cameraZoom = 1.8 }),
                ("camera.zoom", { $0.style.cameraZoom = 2.5 }),
                ("camera.shadowOff", { $0.style.cameraShadow = 0; $0.style.backgroundType = .color; $0.style.backgroundColorHex = "FFFFFF" }),
                ("camera.border", { $0.style.cameraBorderWidth = 12 }),
                ("layout.cameraOnly", { $0.layouts = [LayoutRange(start: 0, end: d, kind: .cameraOnly)] }),
                ("layout.screenOnly", { $0.layouts = [LayoutRange(start: 0, end: d, kind: .screenOnly)] }),
                ("layout.sideBySide", { $0.layouts = [LayoutRange(start: 0, end: d, kind: .sideBySide)] }),
            ]
        }

        var failures = 0
        for (name, mutate) in cases {
            var p = base
            mutate(&p)
            do {
                let frames = try await renderFrames(makeState(model, p), times: times)
                let scores = zip(baseline, frames).map { diff($0, $1) }
                let best = scores.max() ?? 0
                let ok = best >= 3
                if !ok { failures += 1 }
                log("\(ok ? "PASS" : "FAIL") option \(name) changedPixels=\(Int(best)) perFrame=\(scores.map { Int($0) })")
            } catch {
                failures += 1
                log("FAIL option \(name) error=\(error)")
            }
        }
        return failures
    }

    private static func movingTime(_ state: RenderState, duration: Double) -> Double {
        var best = (t: duration * 0.3, v: 0.0)
        var t = 0.1
        while t < duration - 0.1 {
            let v = state.cursor.velocity(at: t)
            let speed = hypot(v.dx, v.dy)
            if speed > best.v { best = (t, speed) }
            t += 0.05
        }
        return best.t
    }

    // MARK: - Audio

    private static func audioLevel(_ state: RenderState) async throws -> Double {
        let built = try await CompositionBuilder.build(state: state, box: RenderStateBox(state, highQuality: false), renderSize: CGSize(width: 64, height: 36), fps: 10)
        let tracks = try await built.composition.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return 0 }
        let reader = try AVAssetReader(asset: built.composition)
        let out = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false, AVSampleRateKey: 24000, AVNumberOfChannelsKey: 1,
        ])
        out.audioMix = built.audioMix
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? NSError(domain: "QA", code: 1) }
        var sum = 0.0, n = 0
        while let b = out.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(b) {
            let len = CMBlockBufferGetDataLength(block)
            var a = [Float](repeating: 0, count: len / 4)
            a.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
            for v in a { sum += Double(v * v) }
            n += a.count
        }
        return n > 0 ? sqrt(sum / Double(n)) : 0
    }

    private static func audioTest(folder: URL) async throws -> Int {
        let model = try await EditorModel.load(folder: folder)
        var base = model.project
        base.style = StyleConfig()
        base.clips = [Clip(sourceStart: 0, sourceEnd: base.duration)]
        // Measure mic/music changes with system audio muted, so a loud
        // system track can't mask them.
        if base.hasSystemAudio && base.micSource != nil && ProcessInfo.processInfo.environment["TAKESHOT_QA_MIC_ONLY"] == "1" {
            base.style.muteSystemAudio = true
        }
        let baseLevel = try await audioLevel(makeState(model, base))
        log("INFO audio baseline rms=\(String(format: "%.5f", baseLevel)) mic=\(base.micSource != nil) system=\(base.hasSystemAudio)")
        let music = "/System/Library/Sounds/Submarine.aiff"
        typealias Mut = (inout Project) -> Void
        // (name, mutation, expectation: "lower" | "higher" | "silent" | "differs")
        var cases: [(String, Mut, String)] = [
            ("master.zero", { $0.style.masterVolume = 0 }, "silent"),
            ("master.double", { $0.style.masterVolume = 2 }, "higher"),
            ("music.add", { $0.style.backgroundMusicPath = music; $0.style.backgroundMusicVolume = 1 }, "higher"),
            ("music.muted", { $0.style.backgroundMusicPath = music; $0.style.muteBackgroundMusic = true }, "same"),
            ("clip.volumeZero", { $0.clips[0].volume = 0 }, "lower"),
        ]
        if base.micSource != nil {
            cases.append(("mic.mute", { $0.style.muteMicrophone = true }, "lower"))
            cases.append(("mic.volumeDouble", { $0.style.microphoneVolume = 2 }, "higher"))
        }
        if base.hasSystemAudio {
            cases.append(("system.mute", { $0.style.muteSystemAudio = true }, "lower"))
            cases.append(("system.volumeHalf", { $0.style.systemAudioVolume = 0.5 }, "lower"))
        }
        if model.renderState.cursor.clicks.count > 0 {
            cases.append(("clickSound.on", { $0.style.clickSound = true; $0.style.clickSoundVolume = 1 }, "higher"))
        }
        var failures = 0
        for (name, mutate, expect) in cases {
            var p = base
            mutate(&p)
            let level = try await audioLevel(makeState(model, p))
            let ok: Bool
            switch expect {
            case "silent": ok = level < 1e-5
            case "higher": ok = level > baseLevel * 1.05 + 1e-6
            case "lower": ok = level < baseLevel * 0.95 || (baseLevel < 1e-5 && level < 1e-5)
            default: ok = abs(level - baseLevel) <= max(1e-6, baseLevel * 0.02)
            }
            if !ok { failures += 1 }
            log("\(ok ? "PASS" : "FAIL") audio \(name) rms=\(String(format: "%.5f", level)) expected=\(expect)")
        }
        // Improve microphone: offline processing must produce a file and change the mix.
        if let mic = base.micSource {
            do {
                try await AudioTools.enhanceMicrophone(folder: folder, micFileName: mic.fileName)
                var p = base
                p.style.improveMicrophone = true
                let level = try await audioLevel(makeState(model, p))
                let ok = abs(level - baseLevel) > baseLevel * 0.02
                if !ok { failures += 1 }
                log("\(ok ? "PASS" : "FAIL") audio improveMicrophone rms=\(String(format: "%.5f", level))")
            } catch {
                failures += 1
                log("FAIL audio improveMicrophone error=\(error)")
            }
        }
        return failures
    }

    // MARK: - Export

    private static func exportTest(folder: URL) async throws -> Int {
        let model = try await EditorModel.load(folder: folder)
        var p = model.project
        p.style = StyleConfig()
        p.clips = [Clip(sourceStart: 0, sourceEnd: min(p.duration, 3))]
        let state = makeState(model, p)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("takeshot-qa-export", isDirectory: true)
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let hasAudio = p.micSource != nil || p.hasSystemAudio

        func settings(_ f: ExportFormat = .mp4, _ c: ExportCodec = .h264, _ r: ExportResolution = .p1080, _ fps: Int = 60, _ q: ExportQuality = .social, gifFps: Int = 15, gifWidth: Int = 960) -> ExportSettings {
            var s = ExportSettings()
            s.format = f; s.codec = c; s.resolution = r; s.fps = fps; s.quality = q; s.gifFps = gifFps; s.gifMaxWidth = gifWidth
            return s
        }
        let cases: [(String, ExportSettings)] = [
            ("mp4-h264-1080-60-social", settings()),
            ("mp4-h264-720-30-web", settings(.mp4, .h264, .p720, 30, .web)),
            ("mp4-h264-1440-24-studio", settings(.mp4, .h264, .p1440, 24, .studio)),
            ("mp4-h264-2160-60-studio", settings(.mp4, .h264, .p2160, 60, .studio)),
            ("mp4-hevc-1080-60-social", settings(.mp4, .hevc)),
            ("mp4-hevc-2160-30-web", settings(.mp4, .hevc, .p2160, 30, .web)),
            ("mov-h264-1080-30", settings(.mov, .h264, .p1080, 30)),
            ("mov-prores-1080-30", settings(.mov, .prores, .p1080, 30)),
            ("mp4-prores(→mov)-720-24", settings(.mp4, .prores, .p720, 24)),
            ("gif-15-640", settings(.gif, gifFps: 15, gifWidth: 640)),
            ("gif-30-960", settings(.gif, gifFps: 30, gifWidth: 960)),
        ]
        var failures = 0
        var sizes: [String: Int] = [:]
        for (name, s) in cases {
            let ext = (s.format == .gif) ? "gif" : ((s.format == .mov || s.codec == .prores) ? "mov" : "mp4")
            let url = out.appendingPathComponent("\(name).\(ext)")
            let start = CACurrentMediaTime()
            do {
                _ = try await VideoExporter.export(state: state, settings: s, destination: url, cancel: ExportJob.CancelFlag()) { _ in }
                let secs = CACurrentMediaTime() - start
                let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                sizes[name] = bytes
                var expected = state.canvasSize(shortSide: CGFloat(s.resolution.shortSide))
                var problems: [String] = []
                var facts = ""
                if s.format == .gif {
                    if expected.width > CGFloat(s.gifMaxWidth) {
                        let k = CGFloat(s.gifMaxWidth) / expected.width
                        expected = CGSize(width: CGFloat(Int(expected.width * k / 2) * 2), height: CGFloat(Int(expected.height * k / 2) * 2))
                    }
                    let src = CGImageSourceCreateWithURL(url as CFURL, nil)
                    let count = src.map { CGImageSourceGetCount($0) } ?? 0
                    let first = src.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
                    facts = "frames=\(count) size=\(first?.width ?? 0)x\(first?.height ?? 0)"
                    let expectedFrames = Int(state.clipMap.outputDuration * Double(s.gifFps))
                    if abs(count - expectedFrames) > 2 { problems.append("frames \(count)≠\(expectedFrames)") }
                    if first?.width != Int(expected.width) { problems.append("width") }
                } else {
                    let asset = AVURLAsset(url: url)
                    let dur = try await CMTimeGetSeconds(asset.load(.duration))
                    guard let v = try await asset.loadTracks(withMediaType: .video).first else { throw NSError(domain: "QA", code: 3) }
                    let size = try await v.load(.naturalSize)
                    let fps = try await v.load(.nominalFrameRate)
                    let sub = try await v.load(.formatDescriptions).first.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
                    let codec = String(bytes: withUnsafeBytes(of: sub.bigEndian, Array.init), encoding: .ascii) ?? "?"
                    let audio = try await asset.loadTracks(withMediaType: .audio).count
                    facts = "\(Int(size.width))x\(Int(size.height)) \(codec) \(String(format: "%.1f", fps))fps dur=\(String(format: "%.2f", dur)) audio=\(audio)"
                    if Int(size.width) != Int(expected.width) || Int(size.height) != Int(expected.height) { problems.append("size≠\(Int(expected.width))x\(Int(expected.height))") }
                    if abs(Double(fps) - Double(s.fps)) > 1.5 { problems.append("fps") }
                    let expectCodec = s.codec == .prores ? "apcn" : (s.codec == .hevc ? "hvc1" : "avc1")
                    if codec != expectCodec { problems.append("codec≠\(expectCodec)") }
                    if abs(dur - state.clipMap.outputDuration) > 0.2 { problems.append("duration") }
                    if hasAudio && audio == 0 { problems.append("no audio") }
                }
                if bytes == 0 { problems.append("empty") }
                if !problems.isEmpty { failures += 1 }
                log("\(problems.isEmpty ? "PASS" : "FAIL") export \(name) \(facts) \(bytes / 1024)KB in \(String(format: "%.1f", secs))s \(problems.joined(separator: ","))")
            } catch {
                failures += 1
                log("FAIL export \(name) error=\(error)")
            }
        }
        if let web = sizes["mp4-h264-720-30-web"], let social = sizes["mp4-h264-1080-60-social"], let studio = sizes["mp4-h264-2160-60-studio"] {
            let ok = web < social && social < studio
            if !ok { failures += 1 }
            log("\(ok ? "PASS" : "FAIL") export quality ordering web<social<studio \(web / 1024)<\(social / 1024)<\(studio / 1024)KB")
        }
        // Cancel mid-export.
        let flag = ExportJob.CancelFlag()
        let cancelURL = out.appendingPathComponent("cancel.mp4")
        Task { try? await Task.sleep(nanoseconds: 300_000_000); flag.set(true) }
        do {
            _ = try await VideoExporter.export(state: state, settings: settings(.mp4, .h264, .p2160, 60, .studio), destination: cancelURL, cancel: flag) { _ in }
            log("FAIL export cancel (completed instead of cancelling)")
            failures += 1
        } catch VideoExporter.ExportError.cancelled {
            let leftover = FileManager.default.fileExists(atPath: cancelURL.path)
            log("\(leftover ? "FAIL" : "PASS") export cancel leftoverFile=\(leftover)")
            if leftover { failures += 1 }
        } catch {
            failures += 1
            log("FAIL export cancel error=\(error)")
        }
        return failures
    }

    // MARK: - Editing operations

    private static func editsTest(folder: URL) async throws -> Int {
        let model = try await EditorModel.load(folder: folder)
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failures += 1 }
            log("\(ok ? "PASS" : "FAIL") edit \(name) \(detail)")
        }
        func settle() async { try? await Task.sleep(nanoseconds: 400_000_000) }
        let original = model.project
        model.resetCuts()
        let fullDuration = model.duration

        model.seek(to: model.duration * 0.5)
        model.splitAtPlayhead()
        check("split", model.project.clips.count == 2, "clips=\(model.project.clips.count)")
        if case .clip(let id)? = model.selection {
            model.updateClip(id) { $0.speed = 2 }
            await model.rebuildComposition()
            let expected = fullDuration * 0.5 + fullDuration * 0.5 / 2
            check("speed2x", abs(model.duration - expected) < 0.1, "duration=\(String(format: "%.2f", model.duration)) expected=\(String(format: "%.2f", expected))")
            model.trimClip(id, end: model.project.clips.first { $0.id == id }!.sourceEnd - 1)
            check("trimEnd", abs((model.project.clips.first { $0.id == id }!.sourceEnd) - (model.project.duration - 1)) < 0.01)
            model.deleteClip(id)
            await model.rebuildComposition()
            check("deleteClip", model.project.clips.count == 1 && abs(model.duration - fullDuration * 0.5) < 0.1, "duration=\(String(format: "%.2f", model.duration))")
        } else {
            check("split selection", false)
        }
        model.undo(); model.undo(); model.undo(); model.undo()
        check("undo x4", model.project.clips.count == 1 && model.project.clips[0].sourceEnd == model.project.duration, "clips=\(model.project.clips.count)")
        model.redo()
        check("redo", model.project.clips.count == 2)
        model.resetCuts()

        model.addZoom(atOutput: model.duration * 0.2)
        let zoomCount = model.project.zoomRanges.count
        check("addZoom", zoomCount >= 1, "zooms=\(zoomCount)")
        model.regenerateAutoZooms()
        check("regenerateAutoZooms", true, "zooms=\(model.project.zoomRanges.count) clicks=\(model.renderState.cursor.clicks.count)")
        model.removeAllZooms()
        check("removeAllZooms", model.project.zoomRanges.isEmpty)
        model.addMask(kind: .pixelate)
        check("addMask", model.project.masks.count == 1)
        if case .mask(let id)? = model.selection {
            model.updateMask(id) { $0.rect = CGRect(x: 0.9, y: 0.9, width: 0.5, height: 0.5) }
            let r = model.project.masks[0].rect
            check("maskClamped", r.maxX <= 1.0001 && r.maxY <= 1.0001, "\(r)")
        }
        if model.project.hasCameraVideo {
            model.addLayout(kind: .sideBySide)
            check("addLayout", model.project.layouts.count == 1)
        }
        await settle()
        let waveformBins = model.waveform.count
        model.errorMessage = nil
        model.removeSilences(thresholdDb: -20, minDuration: 0.4)
        check("removeSilences", model.project.clips.count >= 1, "clips=\(model.project.clips.count) waveform=\(waveformBins) msg=\(model.errorMessage ?? "-")")
        model.resetCuts()
        model.errorMessage = nil
        model.speedUpTyping(factor: 3)
        check("speedUpTyping", true, "clips=\(model.project.clips.count) msg=\(model.errorMessage ?? "-")")
        model.resetCuts()
        model.rename("QA renamed")
        check("rename", model.project.name == "QA renamed")
        PresetStore.save(model.project.style, name: "QA preset")
        model.updateStyle { $0.padding = 0.2 }
        model.applyPreset("QA preset")
        check("presetRoundTrip", model.project.style.padding == original.style.padding || model.project.style.padding == StyleConfig().padding, "padding=\(model.project.style.padding)")
        PresetStore.delete(name: "QA preset")
        check("presetDelete", !PresetStore.names().contains("QA preset"))
        model.saveNow()
        let reloaded = try Project.load(from: folder)
        check("saveReload", reloaded.name == "QA renamed" && reloaded.version == 2)

        if ProcessInfo.processInfo.environment["TAKESHOT_QA_CAPTIONS"] == "1" {
            model.generateCaptions()
            for _ in 0..<120 where model.busyMessage != nil { try? await Task.sleep(nanoseconds: 500_000_000) }
            check("captions", !model.project.captions.isEmpty, "count=\(model.project.captions.count) first=\(model.project.captions.first?.text ?? "-") msg=\(model.errorMessage ?? "-")")
        }
        return failures
    }
}
