import SwiftUI

/// Multi-track timeline in *output* time: ruler, clips (with waveform, trim
/// handles and speed badges), zoom ranges, and overlays (masks, layouts,
/// captions). Click empty zoom track to add a zoom; drag blocks to move;
/// drag block edges to resize. Shift- or ⌘-click adds to the selection,
/// dragging across empty space rubber-band selects, and dragging one of
/// several selected blocks moves them together.
struct EditorTimeline: View {
    @ObservedObject var model: EditorModel
    /// 1 = whole edit fits the visible width.
    @State private var zoomLevel: Double = 1
    @State private var visibleWidth: CGFloat = 800
    @State private var dragOrigin: (start: Double, end: Double)?
    /// Drag-start positions of every selected range item, for group moves.
    @State private var groupOrigins: [EditorSelection: (start: Double, end: Double)] = [:]
    /// Rubber-band selection rectangle, in timeline coordinates.
    @State private var marquee: CGRect?

    private let rulerHeight: CGFloat = 22
    private let clipHeight: CGFloat = 64
    private let zoomHeight: CGFloat = 34
    private let overlayHeight: CGFloat = 28
    private let captionHeight: CGFloat = 22
    private let gutter: CGFloat = 12

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Timeline").inspectorHeader()
                Spacer()
                Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                Slider(value: $zoomLevel, in: 1...30).frame(width: 140)
                Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
                Button("Fit") { zoomLevel = 1 }.controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)

            GeometryReader { geo in
                ScrollViewReader { _ in
                    ScrollView(.horizontal, showsIndicators: true) {
                        let width = max(geo.size.width, CGFloat(model.duration * pixelsPerSecond) + gutter * 2)
                        ZStack(alignment: .topLeading) {
                            VStack(alignment: .leading, spacing: 4) {
                                ruler(width: width)
                                clipsTrack.frame(height: clipHeight)
                                zoomTrack(width: width).frame(height: zoomHeight)
                                overlayTrack.frame(height: overlayHeight)
                                if model.project.hasCameraVideo || !model.project.layouts.isEmpty {
                                    layoutTrack.frame(height: overlayHeight)
                                }
                                captionTrack.frame(height: captionHeight)
                            }
                            if let marquee {
                                Rectangle()
                                    .fill(Color.accentColor.opacity(0.15))
                                    .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: 1))
                                    .frame(width: marquee.width, height: marquee.height)
                                    .offset(x: marquee.minX, y: marquee.minY)
                                    .allowsHitTesting(false)
                            }
                            playheadLine
                        }
                        .frame(width: width, alignment: .leading)
                        .contentShape(Rectangle())
                        .coordinateSpace(name: "timeline")
                        .gesture(DragGesture(minimumDistance: 6, coordinateSpace: .named("timeline"))
                            .onChanged { v in
                                let rect = CGRect(x: min(v.startLocation.x, v.location.x), y: min(v.startLocation.y, v.location.y),
                                                  width: abs(v.location.x - v.startLocation.x), height: abs(v.location.y - v.startLocation.y))
                                marquee = rect
                                model.selectMany(Set(itemFrames().filter { $0.frame.intersects(rect) }.map(\.item)))
                            }
                            .onEnded { _ in marquee = nil })
                        .padding(.vertical, 2)
                    }
                }
                .onAppear { visibleWidth = geo.size.width }
                .onChange(of: geo.size.width) { visibleWidth = $0 }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
    }

    private var pixelsPerSecond: Double {
        Double(max(100, visibleWidth - gutter * 2)) / max(0.1, model.duration) * zoomLevel
    }

    private var extendSelection: Bool {
        !NSEvent.modifierFlags.intersection([.shift, .command]).isEmpty
    }

    /// Frames of every selectable block in timeline coordinates, mirroring
    /// the row layout in `body` (used for rubber-band selection).
    private func itemFrames() -> [(item: EditorSelection, frame: CGRect)] {
        var result: [(EditorSelection, CGRect)] = []
        let spacing: CGFloat = 4
        var y = rulerHeight + spacing
        for entry in model.renderState.clipMap.entries {
            result.append((.clip(entry.clip.id), CGRect(x: x(entry.outputStart), y: y, width: x(entry.outputEnd) - x(entry.outputStart), height: clipHeight)))
        }
        y += clipHeight + spacing
        func span(_ start: Double, _ end: Double, _ height: CGFloat) -> CGRect {
            CGRect(x: outX(source: start), y: y, width: max(10, outX(source: end) - outX(source: start)), height: height)
        }
        for z in model.project.zoomRanges { result.append((.zoom(z.id), span(z.start, z.end, zoomHeight))) }
        y += zoomHeight + spacing
        for m in model.project.masks { result.append((.mask(m.id), span(m.start, m.end, overlayHeight))) }
        y += overlayHeight + spacing
        if model.project.hasCameraVideo || !model.project.layouts.isEmpty {
            for l in model.project.layouts { result.append((.layout(l.id), span(l.start, l.end, overlayHeight))) }
            y += overlayHeight + spacing
        }
        for c in model.project.captions { result.append((.caption(c.id), span(c.start, c.end, captionHeight))) }
        return result
    }

    private func x(_ outputTime: Double) -> CGFloat { gutter + CGFloat(outputTime * pixelsPerSecond) }
    private func time(atX x: CGFloat) -> Double { max(0, min(model.duration, Double(x - gutter) / pixelsPerSecond)) }
    private func outX(source s: Double) -> CGFloat { x(model.renderState.clipMap.outputTimeClamped(atSource: s)) }

    // MARK: - Ruler & playhead

    private func ruler(width: CGFloat) -> some View {
        Canvas { ctx, size in
            let step = tickStep()
            var i = 0
            while Double(i) * step <= model.duration + 0.001 {
                let t = Double(i) * step
                let px = x(t)
                let major = i % 5 == 0
                ctx.fill(Path(CGRect(x: px, y: major ? 10 : 15, width: 1, height: major ? 12 : 7)), with: .color(.secondary.opacity(0.6)))
                if major {
                    ctx.draw(Text(formatTime(t, tenths: step < 1)).font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary),
                             at: CGPoint(x: px + 3, y: 5), anchor: .leading)
                }
                i += 1
            }
        }
        .frame(width: width, height: rulerHeight)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
            model.pause()
            model.seek(to: time(atX: v.location.x))
        })
    }

    private func tickStep() -> Double {
        let candidates = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60]
        return candidates.first { $0 * pixelsPerSecond >= 14 } ?? 60
    }

    private var playheadLine: some View {
        let px = x(model.playhead)
        return ZStack(alignment: .top) {
            Rectangle().fill(TrackColor.playhead).frame(width: 2)
            Path { p in
                // Drawn inside its own 12×8 frame so its tip sits exactly on the line.
                p.move(to: CGPoint(x: 0, y: 0))
                p.addLine(to: CGPoint(x: 12, y: 0))
                p.addLine(to: CGPoint(x: 6, y: 8))
                p.closeSubpath()
            }
            .fill(TrackColor.playhead)
            .frame(width: 12, height: 8)
        }
        .frame(width: 12)
        .offset(x: px - 6)
        .allowsHitTesting(false)
    }

    // MARK: - Clips

    private var clipsTrack: some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.renderState.clipMap.entries, id: \.clip.id) { entry in
                clipBlock(entry)
            }
        }
    }

    private func clipBlock(_ entry: ClipMap.Entry) -> some View {
        let clip = entry.clip
        let x0 = x(entry.outputStart), x1 = x(entry.outputEnd)
        let w = max(4, x1 - x0)
        let selected = model.isSelected(.clip(clip.id))
        let speedColor: Color = clip.speed > 1.01 ? TrackColor.clipFast : (clip.speed < 0.99 ? TrackColor.clipSlow : TrackColor.clip)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 7)
                .fill(speedColor.opacity(0.22))
            Canvas { ctx, size in
                let mid = size.height / 2 + 6
                var px: CGFloat = 0
                while px < size.width {
                    let s = clip.sourceStart + Double(px) / pixelsPerSecond * clip.speed
                    let peak = CGFloat(model.waveformPeak(source: s))
                    let h = max(1, peak * (size.height - 24))
                    ctx.fill(Path(CGRect(x: px, y: mid - h / 2, width: 1.5, height: h)), with: .color(speedColor.opacity(0.75)))
                    px += 3
                }
            }
            HStack(spacing: 4) {
                Image(systemName: "film").font(.system(size: 9))
                if abs(clip.speed - 1) > 0.01 {
                    Text(String(format: "%.2gx", clip.speed)).font(.system(size: 10, weight: .bold))
                }
                if clip.hideCursor { Image(systemName: "cursorarrow.slash").font(.system(size: 9)) }
                Text(formatTime(clip.outputDuration)).font(.system(size: 9, design: .monospaced))
            }
            .foregroundStyle(.primary.opacity(0.8))
            .padding(.horizontal, 7).padding(.top, 4)
            .lineLimit(1)
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(selected ? Color.white : speedColor.opacity(0.7), lineWidth: selected ? 2 : 1)
            edgeHandle(alignment: .leading) { dx in
                let origin = dragOrigin ?? (clip.sourceStart, clip.sourceEnd)
                dragOrigin = origin
                model.trimClip(clip.id, start: origin.start + Double(dx) / pixelsPerSecond * clip.speed)
            }
            edgeHandle(alignment: .trailing) { dx in
                let origin = dragOrigin ?? (clip.sourceStart, clip.sourceEnd)
                dragOrigin = origin
                model.trimClip(clip.id, end: origin.end + Double(dx) / pixelsPerSecond * clip.speed)
            }
            .offset(x: w - 8)
        }
        .frame(width: w, height: clipHeight)
        .offset(x: x0)
        .contentShape(Rectangle())
        .onTapGesture {
            model.select(.clip(clip.id), extend: extendSelection)
        }
        .help("Segment: drag edges to trim, ⌘B to split, ⌫ to delete. Shift-click to select several.")
    }

    private func edgeHandle(alignment: Alignment, onDrag: @escaping (CGFloat) -> Void) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(width: 8)
            .overlay(Capsule().fill(Color.white.opacity(0.7)).frame(width: 3, height: 18))
            .frame(maxHeight: .infinity)
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { v in onDrag(v.translation.width) }
                .onEnded { _ in dragOrigin = nil })
    }

    // MARK: - Zooms

    private func zoomTrack(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(TrackColor.zoom.opacity(0.06))
                .frame(width: width - gutter * 2 + 2)
                .offset(x: gutter)
                .contentShape(Rectangle())
                .onTapGesture(count: 1, coordinateSpace: .local) { location in
                    model.addZoom(atOutput: time(atX: location.x + gutter))
                }
                .help("Click to add a zoom here")
            if model.project.zoomRanges.isEmpty {
                Text("Click to add zoom")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .offset(x: gutter + 8, y: 10)
                    .allowsHitTesting(false)
            }
            ForEach(model.project.zoomRanges) { range in
                rangeBlock(
                    start: range.start, end: range.end, height: zoomHeight,
                    color: range.disabled ? TrackColor.caption : TrackColor.zoom,
                    item: .zoom(range.id),
                    label: "\(String(format: "%.1fx", range.scale)) \(range.mode == .auto ? "Auto" : "Manual")\(range.instant ? " · Instant" : "")",
                    icon: "plus.magnifyingglass",
                    update: { s, e in model.updateZoom(range.id, coalesce: "drag") { $0.start = s; $0.end = e } }
                )
            }
        }
    }

    // MARK: - Overlays

    private var overlayTrack: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6).fill(TrackColor.mask.opacity(0.05))
                .offset(x: gutter)
                .allowsHitTesting(false)
            ForEach(model.project.masks) { mask in
                rangeBlock(start: mask.start, end: mask.end, height: overlayHeight, color: TrackColor.mask,
                           item: .mask(mask.id), label: mask.kind.label, icon: "eye.slash",
                           update: { s, e in model.updateMask(mask.id, coalesce: "drag") { $0.start = s; $0.end = e } })
            }
        }
    }

    private var layoutTrack: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6).fill(TrackColor.layout.opacity(0.05))
                .offset(x: gutter)
                .allowsHitTesting(false)
            ForEach(model.project.layouts) { layout in
                rangeBlock(start: layout.start, end: layout.end, height: overlayHeight, color: TrackColor.layout,
                           item: .layout(layout.id), label: layout.kind.label, icon: "rectangle.split.2x1",
                           update: { s, e in model.updateLayout(layout.id, coalesce: "drag") { $0.start = s; $0.end = e } })
            }
        }
    }

    private var captionTrack: some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.project.captions) { caption in
                let x0 = outX(source: caption.start), x1 = outX(source: caption.end)
                Text(caption.text)
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .frame(width: max(2, x1 - x0 - 1), height: captionHeight, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 4).fill(TrackColor.caption.opacity(model.isSelected(.caption(caption.id)) ? 0.6 : 0.28)))
                    .offset(x: x0)
                    .onTapGesture {
                        model.select(.caption(caption.id), extend: extendSelection)
                        if let t = model.renderState.clipMap.outputTime(atSource: caption.start) { model.seek(to: t) }
                    }
            }
        }
    }

    /// A draggable/resizable block for a source-time range.
    private func rangeBlock(start: Double, end: Double, height: CGFloat, color: Color, item: EditorSelection, label: String, icon: String,
                           update: @escaping (Double, Double) -> Void) -> some View {
        let selected = model.isSelected(item)
        let x0 = outX(source: start), x1 = outX(source: end)
        let w = max(10, x1 - x0)
        let map = model.renderState.clipMap
        func shifted(_ s: Double, by dx: CGFloat) -> Double {
            let out = map.outputTimeClamped(atSource: s) + Double(dx) / pixelsPerSecond
            return map.sourceTime(atOutput: max(0, min(map.outputDuration, out)))
        }
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6).fill(color.opacity(selected ? 0.75 : 0.45))
            RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.white : color, lineWidth: selected ? 2 : 1)
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9))
                Text(label).font(.system(size: 10, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            HStack {
                edgeHandle(alignment: .leading) { dx in
                    let origin = dragOrigin ?? (start, end)
                    dragOrigin = origin
                    update(min(shifted(origin.start, by: dx), origin.end - 0.2), origin.end)
                }
                Spacer()
                edgeHandle(alignment: .trailing) { dx in
                    let origin = dragOrigin ?? (start, end)
                    dragOrigin = origin
                    update(origin.start, max(shifted(origin.end, by: dx), origin.start + 0.2))
                }
            }
        }
        .frame(width: w, height: height)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 3)
            .onChanged { v in
                if dragOrigin == nil {
                    // Dragging an unselected block selects just it; dragging one
                    // of several selected blocks moves the whole group.
                    if !model.isSelected(item) { model.select(item, extend: extendSelection) }
                    var origins: [EditorSelection: (start: Double, end: Double)] = [:]
                    for other in model.multiSelection {
                        if let times = model.rangeTimes(of: other) { origins[other] = times }
                    }
                    groupOrigins = origins
                }
                let origin = dragOrigin ?? (start, end)
                dragOrigin = origin
                let length = origin.end - origin.start
                var s = shifted(origin.start, by: v.translation.width)
                s = max(0, min(model.project.duration - length, s))
                if groupOrigins.count > 1 {
                    model.moveRanges(origins: groupOrigins, delta: s - origin.start)
                } else {
                    update(s, s + length)
                }
            }
            .onEnded { _ in
                dragOrigin = nil
                groupOrigins = [:]
            })
        .simultaneousGesture(TapGesture().onEnded { model.select(item, extend: extendSelection) })
        .offset(x: x0)
    }
}
