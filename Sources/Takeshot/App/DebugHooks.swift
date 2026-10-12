import Foundation
import AppKit
import AVFoundation
import CoreImage

/// Headless self-test, used during development: `TAKESHOT_RENDER_TEST=<project
/// folder>` renders a handful of composited frames to PNGs, runs a full
/// export (plus a GIF when TAKESHOT_RENDER_TEST_GIF=1) and quits.
@MainActor
enum DebugHooks {
    static func runIfRequested() -> Bool {
        guard let path = ProcessInfo.processInfo.environment["TAKESHOT_RENDER_TEST"] else { return false }
        let folder = URL(fileURLWithPath: path)
        Task {
            do {
                try await renderTest(folder: folder)
                NSLog("RENDERTEST: done")
                exit(0)
            } catch {
                NSLog("RENDERTEST: failed \(error)")
                exit(1)
            }
        }
        return true
    }

    private static func renderTest(folder: URL) async throws {
        let model = try await EditorModel.load(folder: folder)
        let env = ProcessInfo.processInfo.environment
        if let styleJSON = env["TAKESHOT_RENDER_TEST_STYLE"], let data = styleJSON.data(using: .utf8),
           let overrides = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(model.project.style)) as? [String: Any] ?? [:]
            let merged = encoded.merging(overrides) { _, new in new }
            let style = try JSONDecoder().decode(StyleConfig.self, from: JSONSerialization.data(withJSONObject: merged))
            model.updateStyle { $0 = style }
            await model.rebuildComposition()
        }
        if env["TAKESHOT_RENDER_TEST_EDITS"] == "1" {
            // Exercise cut/speed/zoom/mask/layout/caption paths.
            model.seek(to: model.duration * 0.3)
            model.splitAtPlayhead()
            if case .clip(let id)? = model.selection { model.updateClip(id) { $0.speed = 2 } }
            model.seek(to: model.duration * 0.15)
            model.addMask(kind: .blur)
            model.addZoom(atOutput: model.duration * 0.6)
            if model.project.hasCameraVideo {
                model.seek(to: model.duration * 0.8)
                model.addLayout(kind: .cameraOnly)
            }
            model.mutate { p in
                p.captions = [CaptionSegment(start: 0.2, end: p.duration, text: "Caption rendering test — Takeshot")]
            }
            await model.rebuildComposition()
        }
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        NSLog("RENDERTEST: waveform bins=\(model.waveform.count) max=\(model.waveform.max() ?? -1)")
        let state = model.renderState
        NSLog("RENDERTEST: project v\(state.project.version) clips=\(state.project.clips.count) zooms=\(state.project.zoomRanges.count) duration=\(state.clipMap.outputDuration) recording=\(state.recordingSize) cursorShapes=\(state.cursorImages.count)")

        let canvas = state.canvasSize(shortSide: 720)
        let built = try await CompositionBuilder.build(state: state, box: RenderStateBox(state, highQuality: true), renderSize: canvas, fps: 30)
        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let out = folder.appendingPathComponent("render-test", isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let fractions = [0.05, 0.25, 0.45, 0.65, 0.85]
        for (i, f) in fractions.enumerated() {
            let t = built.outputDuration * f
            let start = CACurrentMediaTime()
            let image = try await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
            let ms = Int((CACurrentMediaTime() - start) * 1000)
            let url = out.appendingPathComponent("frame-\(i)-\(String(format: "%.1f", t))s.png")
            if let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, image, nil)
                CGImageDestinationFinalize(dest)
            }
            NSLog("RENDERTEST: frame \(i) t=\(t) \(image.width)x\(image.height) in \(ms)ms")
        }

        var settings = state.project.export
        settings.resolution = .p1080
        settings.fps = 60
        let exportStart = CACurrentMediaTime()
        let flag = ExportJob.CancelFlag()
        let url = try await VideoExporter.export(state: state, settings: settings, destination: out.appendingPathComponent("export.mp4"), cancel: flag) { _ in }
        NSLog("RENDERTEST: exported \(url.lastPathComponent) in \(Int(CACurrentMediaTime() - exportStart))s for \(Int(built.outputDuration))s of video")
        if env["TAKESHOT_RENDER_TEST_GIF"] == "1" {
            settings.format = .gif
            settings.gifMaxWidth = 640
            let gif = try await VideoExporter.export(state: state, settings: settings, destination: out.appendingPathComponent("export.gif"), cancel: flag) { _ in }
            NSLog("RENDERTEST: exported \(gif.lastPathComponent)")
        }
    }
}
