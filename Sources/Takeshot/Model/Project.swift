import Foundation
import CoreGraphics

/// A contiguous piece of the source recording that ends up in the output.
/// Clips are kept in source order and never overlap; gaps between them are
/// cuts. All times are seconds in *source* (screen.mov) time.
struct Clip: Codable, Identifiable, Equatable {
    var id = UUID()
    var sourceStart: Double
    var sourceEnd: Double
    var speed: Double = 1
    var volume: Double = 1
    var hideCursor = false

    var sourceDuration: Double { max(0, sourceEnd - sourceStart) }
    var outputDuration: Double { sourceDuration / max(0.05, speed) }
}

enum ZoomMode: String, Codable, CaseIterable {
    /// Follows the (smoothed) cursor, panning when it nears the viewport edge.
    case auto
    /// Fixed point chosen by the user.
    case manual
    var label: String { self == .auto ? "Follow cursor" : "Manual point" }
}

/// A span of time during which the screen is zoomed in. Source time.
struct ZoomRange: Codable, Identifiable, Equatable {
    var id = UUID()
    var start: Double
    var end: Double
    var scale: Double = 2
    var mode: ZoomMode = .auto
    /// Normalized (0...1, top-left origin) point within the recording.
    var targetX: Double = 0.5
    var targetY: Double = 0.5
    var instant = false
    var disabled = false

    var target: CGPoint { CGPoint(x: targetX, y: targetY) }
}

enum MaskKind: String, Codable, CaseIterable {
    case blur, pixelate, highlight
    var label: String {
        switch self {
        case .blur: return "Blur"
        case .pixelate: return "Pixelate"
        case .highlight: return "Spotlight"
        }
    }
}

/// A rectangular blur/pixelate/spotlight region over the recording. Rect is
/// normalized (0...1, top-left origin) in recording space.
struct MaskRange: Codable, Identifiable, Equatable {
    var id = UUID()
    var start: Double
    var end: Double
    var kind: MaskKind = .blur
    var x: Double = 0.35
    var y: Double = 0.35
    var w: Double = 0.3
    var h: Double = 0.3
    /// 0...1
    var intensity: Double = 0.7

    var rect: CGRect {
        get { CGRect(x: x, y: y, width: w, height: h) }
        set { x = newValue.minX; y = newValue.minY; w = newValue.width; h = newValue.height }
    }
}

enum LayoutKind: String, Codable, CaseIterable {
    case cameraOnly, screenOnly, sideBySide
    var label: String {
        switch self {
        case .cameraOnly: return "Camera only"
        case .screenOnly: return "Screen only"
        case .sideBySide: return "Side by side"
        }
    }
}

/// Overrides the default "screen + camera bubble" layout for a span. Source time.
struct LayoutRange: Codable, Identifiable, Equatable {
    var id = UUID()
    var start: Double
    var end: Double
    var kind: LayoutKind = .cameraOnly
}

struct CaptionSegment: Codable, Identifiable, Equatable {
    var id = UUID()
    var start: Double
    var end: Double
    var text: String
}

enum ExportFormat: String, Codable, CaseIterable {
    case mp4, mov, gif
    var label: String { rawValue.uppercased() }
    var fileExtension: String { rawValue }
}

enum ExportCodec: String, Codable, CaseIterable {
    case h264, hevc, prores
    var label: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC (H.265)"
        case .prores: return "ProRes 422"
        }
    }
}

enum ExportResolution: String, Codable, CaseIterable {
    case p720, p1080, p1440, p2160
    var label: String {
        switch self {
        case .p720: return "720p"
        case .p1080: return "1080p"
        case .p1440: return "1440p"
        case .p2160: return "4K"
        }
    }
    /// Length of the canvas's *shorter* side.
    var shortSide: Double {
        switch self {
        case .p720: return 720
        case .p1080: return 1080
        case .p1440: return 1440
        case .p2160: return 2160
        }
    }
}

enum ExportQuality: String, Codable, CaseIterable {
    case web, social, studio
    var label: String {
        switch self {
        case .web: return "Web (smaller file)"
        case .social: return "Social (balanced)"
        case .studio: return "Studio (highest)"
        }
    }
    /// Bits per pixel per frame for the H.264/HEVC encoders.
    var bitsPerPixel: Double {
        switch self {
        case .web: return 0.06
        case .social: return 0.12
        case .studio: return 0.24
        }
    }
}

struct ExportSettings: Codable, Equatable {
    var format: ExportFormat = .mp4
    var codec: ExportCodec = .h264
    var resolution: ExportResolution = .p1080
    var fps: Int = 60
    var quality: ExportQuality = .social
    var gifFps: Int = 15
    var gifMaxWidth: Int = 960
}

struct Project: Codable {
    var version = 2
    var name: String = "Recording"
    var createdAt = Date()
    var screenFileName: String = "screen.mov"
    var webcamFileName: String?
    var duration: Double
    /// The recorded area's frame in global point coordinates, used to
    /// normalize raw CGEvent cursor coordinates into 0...1 video space.
    var displayFrameX: Double
    var displayFrameY: Double
    var displayFrameWidth: Double
    var displayFrameHeight: Double
    /// Input-event time (seconds since session start) of screen.mov's t=0.
    var screenOffset: Double = 0
    /// Screen time at which webcam.mov's t=0 happens.
    var webcamOffset: Double = 0
    /// Separate microphone recording (newer projects); older projects keep
    /// mic audio inside webcam.mov.
    var micFileName: String?
    /// Screen time at which the mic file's t=0 happens.
    var micOffset: Double = 0
    var hasSystemAudio = false
    var hasMicrophone = false
    var hasCameraVideo = false

    var style = StyleConfig()
    var clips: [Clip] = []
    var zoomRanges: [ZoomRange] = []
    var masks: [MaskRange] = []
    var layouts: [LayoutRange] = []
    var captions: [CaptionSegment] = []
    var export = ExportSettings()

    var displayFrame: CGRect {
        CGRect(x: displayFrameX, y: displayFrameY, width: displayFrameWidth, height: displayFrameHeight)
    }

    var clipMap: ClipMap { ClipMap(clips: clips) }

    /// Where the microphone audio lives and how it lines up with the screen.
    var micSource: (fileName: String, offset: Double)? {
        if let micFileName { return (micFileName, micOffset) }
        if hasMicrophone, let webcamFileName { return (webcamFileName, webcamOffset) }
        return nil
    }

    static let fileName = "project.json"

    func save(to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }

    static func load(from folder: URL) throws -> Project {
        let data = try Data(contentsOf: folder.appendingPathComponent(Self.fileName))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let version = object["version"] as? Int ?? 1
        var project: Project
        if version < 2 {
            project = try LegacyProjectV1.migrate(object, folder: folder)
        } else {
            let duration = object["duration"] as? Double ?? 0
            let defaults = Project(duration: duration, displayFrameX: 0, displayFrameY: 0, displayFrameWidth: 1, displayFrameHeight: 1)
            project = try LenientJSON.decode(Project.self, fromObject: object, defaults: defaults)
        }
        if project.clips.isEmpty {
            project.clips = [Clip(sourceStart: 0, sourceEnd: project.duration)]
        }
        return project
    }
}

/// Maps between output (edited timeline) time and source (recording) time
/// across the project's clips, accounting for cuts and per-clip speed.
struct ClipMap {
    struct Entry {
        let clip: Clip
        let outputStart: Double
        var outputEnd: Double { outputStart + clip.outputDuration }
    }

    let entries: [Entry]
    let outputDuration: Double

    init(clips: [Clip]) {
        var t = 0.0
        var entries: [Entry] = []
        for clip in clips.sorted(by: { $0.sourceStart < $1.sourceStart }) where clip.sourceDuration > 0.001 {
            entries.append(Entry(clip: clip, outputStart: t))
            t += clip.outputDuration
        }
        self.entries = entries
        self.outputDuration = t
    }

    func entryIndex(atOutput t: Double) -> Int? {
        guard !entries.isEmpty else { return nil }
        if t <= 0 { return 0 }
        for (i, e) in entries.enumerated() where t < e.outputEnd {
            return i
        }
        return entries.count - 1
    }

    func clip(atOutput t: Double) -> Clip? {
        entryIndex(atOutput: t).map { entries[$0].clip }
    }

    func sourceTime(atOutput t: Double) -> Double {
        guard let i = entryIndex(atOutput: t) else { return t }
        let e = entries[i]
        let local = min(max(0, t - e.outputStart), e.clip.outputDuration)
        return e.clip.sourceStart + local * e.clip.speed
    }

    /// nil if `s` falls inside a cut.
    func outputTime(atSource s: Double) -> Double? {
        for e in entries where s >= e.clip.sourceStart - 0.0005 && s <= e.clip.sourceEnd + 0.0005 {
            return e.outputStart + (min(max(s, e.clip.sourceStart), e.clip.sourceEnd) - e.clip.sourceStart) / e.clip.speed
        }
        return nil
    }

    /// Like `outputTime(atSource:)` but snaps times inside cuts to the next
    /// clip's start — useful for drawing source-time ranges on the timeline.
    func outputTimeClamped(atSource s: Double) -> Double {
        if let t = outputTime(atSource: s) { return t }
        for e in entries where s < e.clip.sourceStart { return e.outputStart }
        return outputDuration
    }

    func clip(atSource s: Double) -> Clip? {
        entries.first { s >= $0.clip.sourceStart && s <= $0.clip.sourceEnd }?.clip
    }
}

/// The original (v1) on-disk format: zoom keyframes, a flat background
/// color and a single trim range. Converted to the v2 model in memory on
/// load; written back as v2 only once the project is edited.
enum LegacyProjectV1 {
    static func migrate(_ object: [String: Any], folder: URL) throws -> Project {
        let duration = object["duration"] as? Double ?? 0
        var project = Project(
            name: folder.lastPathComponent,
            screenFileName: object["screenFileName"] as? String ?? "screen.mov",
            webcamFileName: object["webcamFileName"] as? String,
            duration: duration,
            displayFrameX: object["displayFrameX"] as? Double ?? 0,
            displayFrameY: object["displayFrameY"] as? Double ?? 0,
            displayFrameWidth: object["displayFrameWidth"] as? Double ?? 1,
            displayFrameHeight: object["displayFrameHeight"] as? Double ?? 1
        )
        project.hasCameraVideo = project.webcamFileName != nil
        project.hasMicrophone = project.webcamFileName != nil

        if let bg = object["background"] as? [String: Any] {
            project.style.backgroundType = .color
            project.style.backgroundColorHex = bg["backgroundColorHex"] as? String ?? "1E1E1E"
            if let p = bg["paddingFraction"] as? Double { project.style.padding = p }
            if let r = bg["cornerRadius"] as? Double { project.style.cornerRadius = r }
            if let s = bg["shadowOpacity"] as? Double { project.style.shadowIntensity = s }
        }

        let trimStart = object["trimStart"] as? Double ?? 0
        let trimEnd = object["trimEnd"] as? Double ?? duration
        project.clips = [Clip(sourceStart: trimStart, sourceEnd: max(trimStart + 0.1, trimEnd))]

        // Keyframes → ranges: each run of keyframes with scale > 1 becomes a zoom.
        if let kfs = object["zoomKeyframes"] as? [[String: Any]] {
            let sorted = kfs.compactMap { kf -> (t: Double, s: Double, x: Double, y: Double)? in
                guard let t = kf["time"] as? Double, let s = kf["scale"] as? Double else { return nil }
                let fp = kf["focalPoint"] as? [Double] ?? [0.5, 0.5]
                return (t, s, fp.first ?? 0.5, fp.count > 1 ? fp[1] : 0.5)
            }.sorted { $0.t < $1.t }
            var runStart: (t: Double, s: Double, x: Double, y: Double)?
            for (i, kf) in sorted.enumerated() {
                if kf.s > 1.01 {
                    if runStart == nil { runStart = i > 0 ? sorted[i - 1] : kf }
                    runStart = runStart.map { ($0.t, max($0.s, kf.s), kf.x, kf.y) }
                } else if let start = runStart {
                    project.zoomRanges.append(ZoomRange(start: start.t, end: kf.t, scale: start.s, mode: .manual, targetX: start.x, targetY: start.y))
                    runStart = nil
                }
            }
            if let start = runStart {
                project.zoomRanges.append(ZoomRange(start: start.t, end: duration, scale: start.s, mode: .manual, targetX: start.x, targetY: start.y))
            }
        }
        return project
    }
}
