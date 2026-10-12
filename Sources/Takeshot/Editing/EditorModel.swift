import Foundation
import AVFoundation
import AppKit
import Combine

enum EditorSelection: Hashable {
    case clip(UUID)
    case zoom(UUID)
    case mask(UUID)
    case layout(UUID)
    case caption(UUID)
}

/// All editor state for one project: the project document with undo/redo,
/// the live AVPlayer preview (driven by the same compositor as export), and
/// every editing operation.
@MainActor
final class EditorModel: ObservableObject {
    @Published private(set) var project: Project
    /// Output (edited timeline) time in seconds.
    @Published private(set) var playhead: Double = 0
    @Published private(set) var isPlaying = false
    /// The primary selection (what the inspector edits). Setting it directly
    /// replaces any multi-selection; use `select(_:extend:)` to add to it.
    @Published var selection: EditorSelection? {
        didSet {
            if !extendingSelection { multiSelection = selection.map { [$0] } ?? [] }
        }
    }
    /// Everything selected on the timeline (always includes `selection`).
    @Published private(set) var multiSelection: Set<EditorSelection> = []
    private var extendingSelection = false
    @Published private(set) var waveform: [Float] = [] {
        didSet { waveformScale = max(0.002, waveform.max() ?? 1) }
    }
    private var waveformScale: Float = 1
    @Published var busyMessage: String?
    @Published var errorMessage: String?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published var loopPlayback = false
    @Published private(set) var renderState: RenderState
    @Published private(set) var previewCanvas: CGSize = CGSize(width: 1280, height: 720)

    let folder: URL
    let events: [InputEvent]
    let player = AVPlayer()
    private let cursorLog: CursorShapeLog?
    private let cursorImages: [Int: CursorImage]
    private let defaultArrow: CursorImage
    private let recordingSize: CGSize
    let box: RenderStateBox

    private var undoStack: [Project] = []
    private var redoStack: [Project] = []
    private var lastCoalesceKey: String?
    private var lastCoalesceTime = Date.distantPast
    private var stateGeneration = 0
    private var compositionGeneration = 0
    private var saveWorkItem: DispatchWorkItem?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    static let previewShortSide: CGFloat = 720

    static func load(folder: URL) async throws -> EditorModel {
        let project = try Project.load(from: folder)
        let eventsURL = folder.appendingPathComponent("events.json")
        let events = (try? JSONDecoder().decode(InputEventLog.self, from: Data(contentsOf: eventsURL)).events) ?? []
        let (log, images) = RenderAssets.loadRecordedCursors(folder: folder)
        let asset = AVURLAsset(url: folder.appendingPathComponent(project.screenFileName))
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "Editor", code: 1, userInfo: [NSLocalizedDescriptionKey: "screen.mov has no video track"])
        }
        let size = try await track.load(.naturalSize)
        let model = EditorModel(folder: folder, project: project, events: events, cursorLog: log, cursorImages: images, recordingSize: size)
        await model.rebuildComposition()
        model.loadWaveform()
        return model
    }

    private init(folder: URL, project: Project, events: [InputEvent], cursorLog: CursorShapeLog?, cursorImages: [Int: CursorImage], recordingSize: CGSize) {
        self.folder = folder
        self.project = project
        self.events = events
        self.cursorLog = cursorLog
        self.cursorImages = cursorImages
        self.defaultArrow = RenderAssets.defaultArrow
        self.recordingSize = recordingSize
        let state = RenderState(project: project, folder: folder, events: events, cursorLog: cursorLog, cursorImages: cursorImages,
                                defaultArrow: RenderAssets.defaultArrow, recordingSize: recordingSize)
        self.renderState = state
        self.box = RenderStateBox(state, highQuality: false)
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                self.playhead = CMTimeGetSeconds(time)
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
                if self.loopPlayback {
                    self.player.seek(to: .zero)
                    self.player.play()
                } else {
                    self.isPlaying = false
                    self.playhead = self.duration
                }
            }
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    var duration: Double { renderState.clipMap.outputDuration }
    var style: StyleConfig { project.style }
    var sourceTimeAtPlayhead: Double { renderState.clipMap.sourceTime(atOutput: playhead) }

    // MARK: - Playback

    func togglePlay() {
        if isPlaying {
            player.pause()
            isPlaying = false
            playhead = CMTimeGetSeconds(player.currentTime())
        } else {
            if playhead >= duration - 0.05 { seek(to: 0) }
            isPlaying = true
            player.play()
        }
    }

    func pause() {
        guard isPlaying else { return }
        player.pause()
        isPlaying = false
    }

    func seek(to t: Double) {
        let clamped = min(max(0, t), max(0, duration))
        playhead = clamped
        player.seek(to: CompositionBuilder.time(clamped), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func step(frames: Int) {
        pause()
        seek(to: playhead + Double(frames) / 60)
    }

    /// Forces the paused preview to re-render the current frame.
    /// Forces the preview to redraw the current frame with the latest
    /// settings. Seeking to the time the player is already at is a no-op in
    /// AVPlayer (the canvas only updated after scrubbing), so the video
    /// composition is re-assigned instead, which makes AVFoundation request
    /// the frame from our compositor again, paused or playing.
    private func refreshFrame() {
        guard let item = player.currentItem,
              let composition = item.videoComposition?.mutableCopy() as? AVMutableVideoComposition else { return }
        item.videoComposition = composition
        if !isPlaying {
            player.seek(to: CompositionBuilder.time(playhead), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    // MARK: - Document changes

    /// Applies an edit with undo support. Rapid changes sharing a
    /// `coalesce` key (e.g. a slider drag) collapse into one undo step.
    func mutate(_ coalesce: String? = nil, _ change: (inout Project) -> Void) {
        var next = project
        change(&next)
        guard !projectsEqual(next, project) else { return }
        let now = Date()
        if !(coalesce != nil && coalesce == lastCoalesceKey && now.timeIntervalSince(lastCoalesceTime) < 1.0) {
            undoStack.append(project)
            if undoStack.count > 200 { undoStack.removeFirst() }
            redoStack.removeAll()
        }
        lastCoalesceKey = coalesce
        lastCoalesceTime = now
        apply(next)
    }

    func updateStyle(_ coalesce: String? = nil, _ change: (inout StyleConfig) -> Void) {
        mutate(coalesce) { change(&$0.style) }
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(project)
        lastCoalesceKey = nil
        apply(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(project)
        lastCoalesceKey = nil
        apply(next)
    }

    private func projectsEqual(_ a: Project, _ b: Project) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(a)) == (try? encoder.encode(b))
    }

    private func apply(_ next: Project) {
        let previous = project
        project = next
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        if case .clip(let id)? = selection, !next.clips.contains(where: { $0.id == id }) { selection = nil }
        if case .zoom(let id)? = selection, !next.zoomRanges.contains(where: { $0.id == id }) { selection = nil }
        if case .mask(let id)? = selection, !next.masks.contains(where: { $0.id == id }) { selection = nil }
        if case .layout(let id)? = selection, !next.layouts.contains(where: { $0.id == id }) { selection = nil }
        let surviving = multiSelection.filter { exists($0, in: next) }
        if surviving != multiSelection {
            extendingSelection = true
            multiSelection = surviving
            if let current = selection, !surviving.contains(current) { selection = surviving.first }
            extendingSelection = false
        }
        scheduleSave()

        if needsNewComposition(previous, next) {
            Task { await rebuildComposition() }
        } else {
            rebuildRenderState()
        }
    }

    private func needsNewComposition(_ a: Project, _ b: Project) -> Bool {
        let sa = a.style, sb = b.style
        return a.clips != b.clips
            || sa.aspectRatio != sb.aspectRatio || sa.cropRect != sb.cropRect
            || sa.masterVolume != sb.masterVolume || sa.microphoneVolume != sb.microphoneVolume || sa.systemAudioVolume != sb.systemAudioVolume
            || sa.muteMicrophone != sb.muteMicrophone || sa.muteSystemAudio != sb.muteSystemAudio || sa.improveMicrophone != sb.improveMicrophone
            || sa.backgroundMusicPath != sb.backgroundMusicPath || sa.backgroundMusicVolume != sb.backgroundMusicVolume || sa.muteBackgroundMusic != sb.muteBackgroundMusic
            || sa.clickSound != sb.clickSound || sa.clickSoundVolume != sb.clickSoundVolume || sa.hideCursor != sb.hideCursor
            || (sa.clickSound && (sa.removeCursorShake != sb.removeCursorShake))
    }

    private func makeState(_ project: Project) -> RenderState {
        RenderState(project: project, folder: folder, events: events, cursorLog: cursorLog, cursorImages: cursorImages,
                    defaultArrow: defaultArrow, recordingSize: recordingSize)
    }

    /// Recomputes motion tracks off the main thread, then refreshes the preview.
    private func rebuildRenderState() {
        stateGeneration += 1
        let generation = stateGeneration
        let project = self.project
        let folder = self.folder, events = self.events, log = cursorLog, images = cursorImages, arrow = defaultArrow, size = recordingSize
        Task.detached(priority: .userInitiated) {
            let state = RenderState(project: project, folder: folder, events: events, cursorLog: log, cursorImages: images, defaultArrow: arrow, recordingSize: size)
            await MainActor.run {
                guard generation == self.stateGeneration else { return }
                self.renderState = state
                self.box.state = state
                self.refreshFrame()
            }
        }
    }

    func rebuildComposition() async {
        compositionGeneration += 1
        let generation = compositionGeneration
        stateGeneration += 1
        let state = makeState(project)
        renderState = state
        box.state = state
        let canvas = state.canvasSize(shortSide: Self.previewShortSide)
        do {
            let built = try await CompositionBuilder.build(state: state, box: box, renderSize: canvas, fps: 60)
            guard generation == compositionGeneration else { return }
            let item = AVPlayerItem(asset: built.composition)
            item.videoComposition = built.videoComposition
            item.audioMix = built.audioMix
            item.audioTimePitchAlgorithm = .spectral
            let wasPlaying = isPlaying
            player.pause()
            player.replaceCurrentItem(with: item)
            previewCanvas = canvas
            playhead = min(playhead, built.outputDuration)
            await player.seek(to: CompositionBuilder.time(playhead), toleranceBefore: .zero, toleranceAfter: .zero)
            if wasPlaying { player.play() }
        } catch {
            errorMessage = "Couldn't build preview: \(error.localizedDescription)"
        }
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            try? self.project.save(to: self.folder)
            AppSettings.shared.rememberLastStyle(self.project.style)
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    func saveNow() {
        saveWorkItem?.cancel()
        try? project.save(to: folder)
    }

    // MARK: - Waveform

    private func loadWaveform() {
        let project = self.project
        let folder = self.folder
        Task.detached(priority: .utility) {
            var combined: [Float] = []
            if project.hasSystemAudio {
                combined = await AudioTools.peaks(url: folder.appendingPathComponent(project.screenFileName))
            }
            if let source = project.micSource {
                let mic = await AudioTools.peaks(url: folder.appendingPathComponent(source.fileName))
                if (mic.max() ?? 0) < 0.0005 {
                    await MainActor.run {
                        self.errorMessage = "The microphone recorded silence. Check the mic you picked (Bluetooth headsets often send no audio while playing music) and its input level in System Settings › Sound."
                    }
                }
                let shift = Int((source.offset * AudioTools.peaksPerSecond).rounded())
                let count = max(combined.count, mic.count + max(0, shift))
                if combined.count < count { combined += [Float](repeating: 0, count: count - combined.count) }
                for (i, v) in mic.enumerated() {
                    let j = i + shift
                    if j >= 0 && j < count { combined[j] = max(combined[j], v) }
                }
            }
            let result = combined
            await MainActor.run { self.waveform = result }
        }
    }

    /// Display level (0...1) around source time `s`, normalized to the
    /// recording's own loudest moment so quiet mics still show a shape.
    func waveformPeak(source s: Double) -> Float {
        let i = Int(s * AudioTools.peaksPerSecond)
        guard i >= 0, i < waveform.count else { return 0 }
        return sqrt(min(1, waveform[i] / waveformScale))
    }

    // MARK: - Selection

    private func exists(_ item: EditorSelection, in project: Project) -> Bool {
        switch item {
        case .clip(let id): return project.clips.contains { $0.id == id }
        case .zoom(let id): return project.zoomRanges.contains { $0.id == id }
        case .mask(let id): return project.masks.contains { $0.id == id }
        case .layout(let id): return project.layouts.contains { $0.id == id }
        case .caption(let id): return project.captions.contains { $0.id == id }
        }
    }

    func isSelected(_ item: EditorSelection) -> Bool { multiSelection.contains(item) }

    /// Click selection. With `extend` (Shift or ⌘ held) the item is added to
    /// or removed from the current selection instead of replacing it.
    func select(_ item: EditorSelection, extend: Bool) {
        guard extend else {
            selection = item
            return
        }
        extendingSelection = true
        if multiSelection.contains(item), multiSelection.count > 1 {
            multiSelection.remove(item)
            if selection == item { selection = multiSelection.first }
        } else {
            multiSelection.insert(item)
            selection = item
        }
        extendingSelection = false
    }

    /// Replaces the selection with a set of items (marquee selection).
    func selectMany(_ items: Set<EditorSelection>) {
        guard items != multiSelection else { return }
        extendingSelection = true
        multiSelection = items
        if selection == nil || !items.contains(selection!) { selection = items.first }
        if items.isEmpty { selection = nil }
        extendingSelection = false
    }

    func clearSelection() { selection = nil }

    /// Deletes every selected item as one undo step.
    func deleteSelected() {
        let items = multiSelection
        guard !items.isEmpty else { return }
        var blockedLastClip = false
        mutate { p in
            for item in items {
                switch item {
                case .clip(let id):
                    if p.clips.count > 1 { p.clips.removeAll { $0.id == id } } else { blockedLastClip = true }
                case .zoom(let id): p.zoomRanges.removeAll { $0.id == id }
                case .mask(let id): p.masks.removeAll { $0.id == id }
                case .layout(let id): p.layouts.removeAll { $0.id == id }
                case .caption(let id): p.captions.removeAll { $0.id == id }
                }
            }
        }
        if blockedLastClip { errorMessage = "Can't delete the only remaining segment." }
        selection = nil
        seek(to: min(playhead, duration))
    }

    /// Start/end (source time) of a selectable range item; nil for clips.
    func rangeTimes(of item: EditorSelection) -> (start: Double, end: Double)? {
        switch item {
        case .zoom(let id): return project.zoomRanges.first { $0.id == id }.map { ($0.start, $0.end) }
        case .mask(let id): return project.masks.first { $0.id == id }.map { ($0.start, $0.end) }
        case .layout(let id): return project.layouts.first { $0.id == id }.map { ($0.start, $0.end) }
        case .caption(let id): return project.captions.first { $0.id == id }.map { ($0.start, $0.end) }
        case .clip: return nil
        }
    }

    /// Moves several range items together by `delta` seconds from their
    /// drag-start positions (group drag on the timeline).
    func moveRanges(origins: [EditorSelection: (start: Double, end: Double)], delta: Double) {
        guard !origins.isEmpty else { return }
        // Keep the whole group inside the recording.
        let minStart = origins.values.map(\.start).min() ?? 0
        let maxEnd = origins.values.map(\.end).max() ?? 0
        let d = max(-minStart, min(project.duration - maxEnd, delta))
        mutate("group-move") { p in
            for (item, o) in origins {
                switch item {
                case .zoom(let id):
                    if let i = p.zoomRanges.firstIndex(where: { $0.id == id }) { p.zoomRanges[i].start = o.start + d; p.zoomRanges[i].end = o.end + d }
                case .mask(let id):
                    if let i = p.masks.firstIndex(where: { $0.id == id }) { p.masks[i].start = o.start + d; p.masks[i].end = o.end + d }
                case .layout(let id):
                    if let i = p.layouts.firstIndex(where: { $0.id == id }) { p.layouts[i].start = o.start + d; p.layouts[i].end = o.end + d }
                case .caption(let id):
                    if let i = p.captions.firstIndex(where: { $0.id == id }) { p.captions[i].start = o.start + d; p.captions[i].end = o.end + d }
                case .clip: break
                }
            }
        }
    }

    // MARK: - Clips

    func splitAtPlayhead() {
        let s = sourceTimeAtPlayhead
        guard let clip = project.clips.first(where: { s > $0.sourceStart + 0.05 && s < $0.sourceEnd - 0.05 }) else { return }
        mutate {
            guard let i = $0.clips.firstIndex(where: { $0.id == clip.id }) else { return }
            var left = clip
            left.sourceEnd = s
            var right = clip
            right.id = UUID()
            right.sourceStart = s
            $0.clips.replaceSubrange(i...i, with: [left, right])
        }
        if let right = project.clips.first(where: { abs($0.sourceStart - s) < 0.0001 }) {
            selection = .clip(right.id)
        }
    }

    func deleteClip(_ id: UUID) {
        guard project.clips.count > 1 else {
            errorMessage = "Can't delete the only remaining segment."
            return
        }
        mutate { $0.clips.removeAll { $0.id == id } }
        seek(to: min(playhead, duration))
    }

    func updateClip(_ id: UUID, coalesce: String? = nil, _ change: (inout Clip) -> Void) {
        mutate(coalesce.map { "\($0)-\(id)" }) { p in
            guard let i = p.clips.firstIndex(where: { $0.id == id }) else { return }
            change(&p.clips[i])
        }
    }

    /// Moves a clip edge, bounded by its neighbours and the recording.
    func trimClip(_ id: UUID, start: Double? = nil, end: Double? = nil) {
        mutate("trim-\(id)") { p in
            let sorted = p.clips.sorted { $0.sourceStart < $1.sourceStart }
            guard let i = sorted.firstIndex(where: { $0.id == id }), let pi = p.clips.firstIndex(where: { $0.id == id }) else { return }
            let lower = i > 0 ? sorted[i - 1].sourceEnd : 0
            let upper = i + 1 < sorted.count ? sorted[i + 1].sourceStart : p.duration
            if let start { p.clips[pi].sourceStart = min(max(lower, start), p.clips[pi].sourceEnd - 0.1) }
            if let end { p.clips[pi].sourceEnd = max(min(upper, end), p.clips[pi].sourceStart + 0.1) }
        }
    }

    func resetCuts() {
        mutate { $0.clips = [Clip(sourceStart: 0, sourceEnd: $0.duration)] }
    }

    /// Removes source span [a, b] from the edit.
    private func cut(_ p: inout Project, from a: Double, to b: Double) {
        guard b - a > 0.02 else { return }
        var result: [Clip] = []
        for clip in p.clips.sorted(by: { $0.sourceStart < $1.sourceStart }) {
            if b <= clip.sourceStart || a >= clip.sourceEnd {
                result.append(clip)
                continue
            }
            if a > clip.sourceStart + 0.05 {
                var left = clip
                left.sourceEnd = a
                result.append(left)
            }
            if b < clip.sourceEnd - 0.05 {
                var right = clip
                right.id = UUID()
                right.sourceStart = b
                result.append(right)
            }
        }
        if !result.isEmpty { p.clips = result }
    }

    /// Applies `speed` to source span [a, b], splitting clips as needed.
    private func setSpeed(_ p: inout Project, from a: Double, to b: Double, speed: Double) {
        guard b - a > 0.05 else { return }
        var result: [Clip] = []
        for clip in p.clips.sorted(by: { $0.sourceStart < $1.sourceStart }) {
            let lo = max(a, clip.sourceStart), hi = min(b, clip.sourceEnd)
            guard hi - lo > 0.05 else {
                result.append(clip)
                continue
            }
            if lo > clip.sourceStart + 0.05 {
                var left = clip
                left.sourceEnd = lo
                result.append(left)
            }
            var mid = clip
            mid.id = UUID()
            mid.sourceStart = lo
            mid.sourceEnd = hi
            mid.speed = speed
            result.append(mid)
            if hi < clip.sourceEnd - 0.05 {
                var right = clip
                right.id = UUID()
                right.sourceStart = hi
                result.append(right)
            }
        }
        p.clips = result
    }

    func removeSilences(thresholdDb: Double, minDuration: Double) {
        guard !waveform.isEmpty else {
            errorMessage = "No audio waveform available for this recording."
            return
        }
        let spans = AudioTools.silences(peaks: waveform, thresholdDb: thresholdDb, minDuration: minDuration)
        let pad = 0.15
        mutate { p in
            for (a, b) in spans.reversed() {
                self.cut(&p, from: a + pad, to: b - pad)
            }
        }
        seek(to: min(playhead, duration))
        busyMessage = nil
        if spans.isEmpty { errorMessage = "No silences longer than \(String(format: "%.1f", minDuration))s found." }
    }

    func speedUpTyping(factor: Double) {
        let runs = renderState.keys.typingRuns(events: events, offset: project.screenOffset)
        guard !runs.isEmpty else {
            errorMessage = "No sustained typing found in this recording."
            return
        }
        mutate { p in
            for (a, b) in runs {
                self.setSpeed(&p, from: a, to: b + 0.3, speed: factor)
            }
        }
    }

    // MARK: - Zoom ranges

    func addZoom(atOutput t: Double? = nil) {
        let s = renderState.clipMap.sourceTime(atOutput: t ?? playhead)
        if let existing = project.zoomRanges.first(where: { s >= $0.start && s <= $0.end }) {
            selection = .zoom(existing.id)
            return
        }
        let next = project.zoomRanges.filter { $0.start > s }.map(\.start).min() ?? project.duration
        let end = min(next - 0.05, s + 3)
        guard end - s > 0.3 else { return }
        var range = ZoomRange(start: s, end: end, scale: project.style.defaultZoom, mode: .auto)
        if let c = renderState.cursor.position(at: s) {
            range.targetX = c.x
            range.targetY = c.y
        }
        mutate { $0.zoomRanges.append(range); $0.zoomRanges.sort { $0.start < $1.start } }
        selection = .zoom(range.id)
    }

    func updateZoom(_ id: UUID, coalesce: String? = nil, _ change: (inout ZoomRange) -> Void) {
        mutate(coalesce.map { "\($0)-\(id)" }) { p in
            guard let i = p.zoomRanges.firstIndex(where: { $0.id == id }) else { return }
            change(&p.zoomRanges[i])
            p.zoomRanges[i].start = max(0, p.zoomRanges[i].start)
            p.zoomRanges[i].end = min(p.duration, max(p.zoomRanges[i].start + 0.2, p.zoomRanges[i].end))
        }
    }

    func deleteZoom(_ id: UUID) {
        mutate { $0.zoomRanges.removeAll { $0.id == id } }
    }

    func regenerateAutoZooms() {
        mutate { p in p.zoomRanges = AutoZoomGenerator.generate(events: self.events, project: p) }
    }

    func removeAllZooms() {
        mutate { $0.zoomRanges = [] }
    }

    // MARK: - Masks & layouts

    func addMask(kind: MaskKind) {
        let s = sourceTimeAtPlayhead
        let mask = MaskRange(start: s, end: min(project.duration, s + 3), kind: kind)
        mutate { $0.masks.append(mask) }
        selection = .mask(mask.id)
    }

    func updateMask(_ id: UUID, coalesce: String? = nil, _ change: (inout MaskRange) -> Void) {
        mutate(coalesce.map { "\($0)-\(id)" }) { p in
            guard let i = p.masks.firstIndex(where: { $0.id == id }) else { return }
            change(&p.masks[i])
            var r = p.masks[i].rect.standardized
            r.size.width = min(1, max(0.02, r.width))
            r.size.height = min(1, max(0.02, r.height))
            r.origin.x = min(max(0, r.minX), 1 - r.width)
            r.origin.y = min(max(0, r.minY), 1 - r.height)
            p.masks[i].rect = r
            p.masks[i].end = max(p.masks[i].start + 0.2, p.masks[i].end)
        }
    }

    func deleteMask(_ id: UUID) {
        mutate { $0.masks.removeAll { $0.id == id } }
    }

    func addLayout(kind: LayoutKind) {
        let s = sourceTimeAtPlayhead
        let layout = LayoutRange(start: s, end: min(project.duration, s + 4), kind: kind)
        mutate { $0.layouts.append(layout) }
        selection = .layout(layout.id)
    }

    func updateLayout(_ id: UUID, coalesce: String? = nil, _ change: (inout LayoutRange) -> Void) {
        mutate(coalesce.map { "\($0)-\(id)" }) { p in
            guard let i = p.layouts.firstIndex(where: { $0.id == id }) else { return }
            change(&p.layouts[i])
            p.layouts[i].end = max(p.layouts[i].start + 0.3, p.layouts[i].end)
        }
    }

    func deleteLayout(_ id: UUID) {
        mutate { $0.layouts.removeAll { $0.id == id } }
    }

    // MARK: - Captions

    func generateCaptions() {
        busyMessage = "Transcribing audio on this Mac…"
        let project = self.project, folder = self.folder
        Task {
            do {
                let captions = try await Transcriber.transcribe(project: project, folder: folder)
                busyMessage = nil
                if captions.isEmpty {
                    errorMessage = "No speech was recognised."
                } else {
                    mutate { $0.captions = captions; $0.style.showCaptions = true }
                }
            } catch {
                busyMessage = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    func updateCaption(_ id: UUID, text: String) {
        mutate("caption-\(id)") { p in
            guard let i = p.captions.firstIndex(where: { $0.id == id }) else { return }
            p.captions[i].text = text
        }
    }

    func deleteCaption(_ id: UUID) {
        mutate { $0.captions.removeAll { $0.id == id } }
    }

    func clearCaptions() {
        mutate { $0.captions = [] }
    }

    // MARK: - Audio

    func setImproveMicrophone(_ enabled: Bool) {
        guard enabled else {
            updateStyle { $0.improveMicrophone = false }
            return
        }
        guard let name = project.micSource?.fileName else {
            errorMessage = "This recording has no microphone audio."
            return
        }
        let enhanced = folder.appendingPathComponent(AudioTools.enhancedMicFileName)
        if FileManager.default.fileExists(atPath: enhanced.path) {
            updateStyle { $0.improveMicrophone = true }
            return
        }
        busyMessage = "Enhancing microphone audio…"
        let folder = self.folder
        Task {
            do {
                try await AudioTools.enhanceMicrophone(folder: folder, micFileName: name)
                busyMessage = nil
                updateStyle { $0.improveMicrophone = true }
            } catch {
                busyMessage = nil
                errorMessage = "Couldn't enhance audio: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Presets & misc

    func applyPreset(_ name: String) {
        guard let preset = PresetStore.load(name: name) else { return }
        updateStyle { style in
            let crop = style.cropRect
            let music = style.backgroundMusicPath
            style = preset
            style.cropRect = crop
            if preset.backgroundMusicPath == nil { style.backgroundMusicPath = music }
        }
    }

    /// Dev hook: TAKESHOT_TEST_LIVE_REFRESH=1 flips a visible setting a few
    /// seconds after opening so live refresh can be checked by screenshot.
    /// Dev hook: TAKESHOT_TEST_MULTISELECT=1 selects every zoom/mask/layout, then
    /// group-moves them 0.5 s and logs before/after, to verify multi-select.
    func runMultiSelectSelfTest() {
        guard ProcessInfo.processInfo.environment["TAKESHOT_TEST_MULTISELECT"] == "1" else { return }
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            var items = Set<EditorSelection>()
            project.zoomRanges.forEach { items.insert(.zoom($0.id)) }
            project.masks.forEach { items.insert(.mask($0.id)) }
            project.layouts.forEach { items.insert(.layout($0.id)) }
            selectMany(items)
            var origins: [EditorSelection: (start: Double, end: Double)] = [:]
            for item in items { if let t = rangeTimes(of: item) { origins[item] = t } }
            let before = origins.values.map { String(format: "%.2f", $0.start) }.sorted()
            moveRanges(origins: origins, delta: -0.5)
            let after = items.compactMap { rangeTimes(of: $0) }.map { String(format: "%.2f", $0.start) }.sorted()
            NSLog("MULTITEST: selected=\(multiSelection.count) before=\(before) after=\(after)")
            if ProcessInfo.processInfo.environment["TAKESHOT_TEST_MULTISELECT_DELETE"] == "1" {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                NSLog("MULTITEST: before delete selected=\(multiSelection.count) primary=\(String(describing: selection))")
                deleteSelected()
                NSLog("MULTITEST: after delete zooms=\(project.zoomRanges.count) masks=\(project.masks.count) layouts=\(project.layouts.count) undo=\(canUndo)")
                undo()
                NSLog("MULTITEST: after undo zooms=\(project.zoomRanges.count) masks=\(project.masks.count) layouts=\(project.layouts.count)")
            }
        }
    }

    func runLiveRefreshSelfTest() {
        guard ProcessInfo.processInfo.environment["TAKESHOT_TEST_LIVE_REFRESH"] == "1" else { return }
        Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            NSLog("LIVETEST: changing background")
            updateStyle { $0.backgroundType = .color; $0.backgroundColorHex = "FF2D55" }
        }
    }

    func rename(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutate("rename") { $0.name = trimmed }
    }

    /// Current preview geometry (canvas pixels) for overlay hit-testing.
    func previewGeometry() -> (geo: FrameGeometry, viewport: CGRect) {
        let state = renderState
        let geo = state.geometry(canvas: previewCanvas)
        let (scale, focal) = state.viewport.state(at: sourceTimeAtPlayhead)
        return (geo, ViewportTrack.viewportRect(scale: scale, focal: focal))
    }
}
