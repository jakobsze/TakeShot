import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum InspectorTab: String, CaseIterable {
    case selection, background, frame, cursor, zoom, camera, audio, captions

    var icon: String {
        switch self {
        case .selection: return "cursorarrow.click.2"
        case .background: return "photo"
        case .frame: return "macwindow"
        case .cursor: return "cursorarrow"
        case .zoom: return "plus.magnifyingglass"
        case .camera: return "video"
        case .audio: return "speaker.wave.2"
        case .captions: return "captions.bubble"
        }
    }

    var title: String {
        switch self {
        case .selection: return "Selected"
        case .background: return "Background"
        case .frame: return "Frame & shadow"
        case .cursor: return "Cursor"
        case .zoom: return "Zoom & motion"
        case .camera: return "Camera"
        case .audio: return "Audio"
        case .captions: return "Captions & keys"
        }
    }
}

struct InspectorPanel: View {
    @ObservedObject var model: EditorModel
    @Binding var tab: InspectorTab

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $tab) {
                ForEach(InspectorTab.allCases, id: \.self) { t in
                    Image(systemName: t.icon)
                        .help(t.title)
                        .accessibilityLabel(t.title)
                        .tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Text(tab.title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
            Form {
                switch tab {
                case .selection: SelectionInspector(model: model)
                case .background: BackgroundInspector(model: model)
                case .frame: FrameInspector(model: model)
                case .cursor: CursorInspector(model: model)
                case .zoom: ZoomInspector(model: model)
                case .camera: CameraInspector(model: model)
                case .audio: AudioInspector(model: model)
                case .captions: CaptionsInspector(model: model)
                }
            }
            .formStyle(.grouped)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// A titled group in the inspector — a native grouped-form Section.
private struct Group2<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        Section(title) { content }
    }
}

// MARK: - Background

private struct BackgroundInspector: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        let style = model.project.style
        Group {
            Picker("", selection: styleBinding(model, \.backgroundType)) {
                ForEach(BackgroundType.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch style.backgroundType {
            case .wallpaper:
                if Wallpaper.all.isEmpty {
                    Text("No macOS wallpapers found on this Mac.").foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                        ForEach(Wallpaper.all) { wp in
                            WallpaperThumb(wallpaper: wp, selected: (style.wallpaperPath ?? Wallpaper.all.first?.path) == wp.path)
                                .onTapGesture { model.updateStyle { $0.wallpaperPath = wp.path } }
                        }
                    }
                }
            case .gradient:
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(GradientSpec.presets, id: \.self) { g in
                        LinearGradient(colors: [Color(hex: g.startHex), Color(hex: g.endHex)],
                                       startPoint: UnitPoint(x: 0.5 - cos(g.angle * .pi / 180) / 2, y: 0.5 - sin(g.angle * .pi / 180) / 2),
                                       endPoint: UnitPoint(x: 0.5 + cos(g.angle * .pi / 180) / 2, y: 0.5 + sin(g.angle * .pi / 180) / 2))
                            .frame(height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(style.gradient == g ? Color.accentColor : .clear, lineWidth: 2.5))
                            .onTapGesture { model.updateStyle { $0.gradient = g } }
                    }
                }
                HStack {
                    ColorPicker("From", selection: Binding(get: { Color(hex: style.gradient.startHex) },
                                                           set: { c in model.updateStyle("gstart") { $0.gradient.startHex = c.toHex() } }))
                    ColorPicker("To", selection: Binding(get: { Color(hex: style.gradient.endHex) },
                                                         set: { c in model.updateStyle("gend") { $0.gradient.endHex = c.toHex() } }))
                }
                LabeledSlider(label: "Angle", value: Binding(get: { style.gradient.angle }, set: { v in model.updateStyle("gangle") { $0.gradient.angle = v } }),
                              range: 0...360, format: "%.0f", suffix: "°")
            case .color:
                ColorPicker("Color", selection: styleColorBinding(model, \.backgroundColorHex))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 6) {
                    ForEach(["000000", "1E1E1E", "FFFFFF", "F2F2F7", "FF3B30", "FF9500", "FFCC00", "34C759", "00C7BE", "007AFF", "5856D6", "AF52DE", "FF2D55", "A2845E", "8E8E93", "5E5CE6"], id: \.self) { hex in
                        RoundedRectangle(cornerRadius: 5).fill(Color(hex: hex)).frame(height: 24)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(style.backgroundColorHex == hex ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: style.backgroundColorHex == hex ? 2.5 : 1))
                            .onTapGesture { model.updateStyle { $0.backgroundColorHex = hex } }
                    }
                }
            case .image:
                HStack {
                    Text(style.backgroundImagePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "No image chosen")
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.image]
                        if panel.runModal() == .OK, let url = panel.url {
                            model.updateStyle { $0.backgroundImagePath = url.path }
                        }
                    }
                }
            }

            LabeledSlider(label: "Blur", value: styleBinding(model, \.backgroundBlur), range: 0...1)
        }
    }
}

// MARK: - Frame

private struct FrameInspector: View {
    @ObservedObject var model: EditorModel
    @State private var frame: CGImage?

    var body: some View {
        let style = model.project.style
        Group {
            Group2(title: "Layout") {
                LabeledSlider(label: "Padding", value: styleBinding(model, \.padding), range: 0...0.3)
                LabeledSlider(label: "Roundness", value: styleBinding(model, \.cornerRadius), range: 0...80, format: "%.0f")
                Picker("Window frame", selection: styleBinding(model, \.windowFrame)) {
                    ForEach(WindowFrameStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Aspect ratio", selection: styleBinding(model, \.aspectRatio)) {
                    ForEach(AspectRatioOption.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
            Group2(title: "Inset") {
                LabeledSlider(label: "Size", value: styleBinding(model, \.insetPadding), range: 0...80, format: "%.0f")
                ColorPicker("Color", selection: styleColorBinding(model, \.insetColorHex))
                LabeledSlider(label: "Opacity", value: styleBinding(model, \.insetAlpha), range: 0...1)
            }
            Group2(title: "Shadow") {
                LabeledSlider(label: "Intensity", value: styleBinding(model, \.shadowIntensity), range: 0...1)
                LabeledSlider(label: "Angle", value: styleBinding(model, \.shadowAngle), range: 0...360, format: "%.0f", suffix: "°")
                LabeledSlider(label: "Distance", value: styleBinding(model, \.shadowDistance), range: 0...80, format: "%.0f")
                LabeledSlider(label: "Blur", value: styleBinding(model, \.shadowBlur), range: 0...120, format: "%.0f")
            }
            Group2(title: "Crop recording") {
                RectEditorView(image: frame, aspect: aspect, rect: Binding(
                    get: { style.cropRect },
                    set: { r in model.updateStyle("crop") { $0.cropRect = r } }
                ))
                HStack {
                    Text(String(format: "%.0f%% × %.0f%%", style.cropW * 100, style.cropH * 100)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset crop") { model.updateStyle { $0.cropRect = CGRect(x: 0, y: 0, width: 1, height: 1) } }
                        .disabled(style.cropRect == CGRect(x: 0, y: 0, width: 1, height: 1))
                }
            }
        }
        .task {
            frame = await FrameGrabber(url: model.folder.appendingPathComponent(model.project.screenFileName)).frame(at: min(1, model.project.duration / 2))
        }
    }

    private var aspect: CGFloat {
        let s = model.renderState.recordingSize
        return s.height > 0 ? s.width / s.height : 16 / 9
    }
}

// MARK: - Cursor

private struct CursorInspector: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        let style = model.project.style
        Group {
            Toggle("Hide cursor", isOn: styleBinding(model, \.hideCursor))
            Group2(title: "Appearance") {
                Picker("Style", selection: styleBinding(model, \.cursorStyle)) {
                    ForEach(CursorStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                LabeledSlider(label: "Size", value: styleBinding(model, \.cursorSize), range: 0.5...5, format: "%.1fx")
                LabeledSlider(label: "Tilt on move", value: styleBinding(model, \.cursorTilt), range: 0...1)
                LabeledSlider(label: "Motion blur", value: styleBinding(model, \.motionBlurCursor), range: 0...1)
            }
            Group2(title: "Movement") {
                Toggle("Smooth movement", isOn: styleBinding(model, \.smoothCursor))
                if style.smoothCursor {
                    springPicker(binding: styleBinding(model, \.cursorSpring), presets: SpringConfig.cursorPresets)
                }
                Toggle("Remove cursor shake", isOn: styleBinding(model, \.removeCursorShake))
                Toggle("Hide when idle", isOn: styleBinding(model, \.hideIdleCursor))
                if style.hideIdleCursor {
                    LabeledSlider(label: "After", value: styleBinding(model, \.idleCursorDelay), range: 0.5...10, format: "%.1f", suffix: "s")
                }
                Toggle("Return to start at end (loop)", isOn: styleBinding(model, \.loopCursorAtEnd))
            }
            Group2(title: "Clicks") {
                Picker("Effect", selection: styleBinding(model, \.clickEffect)) {
                    ForEach(ClickEffect.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if style.clickEffect.ripple {
                    ColorPicker("Ripple color", selection: styleColorBinding(model, \.rippleColorHex))
                }
                Toggle("Click sound", isOn: styleBinding(model, \.clickSound))
                if style.clickSound {
                    LabeledSlider(label: "Volume", value: styleBinding(model, \.clickSoundVolume), range: 0...1)
                }
            }
        }
    }
}

@MainActor
private func springPicker(binding: Binding<SpringConfig>, presets: [(String, SpringConfig)]) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        Picker("Feel", selection: Binding(
            get: { presets.first(where: { $0.1 == binding.wrappedValue })?.0 ?? "Custom" },
            set: { name in if let p = presets.first(where: { $0.0 == name }) { binding.wrappedValue = p.1 } }
        )) {
            ForEach(presets, id: \.0) { Text($0.0).tag($0.0) }
            Text("Custom").tag("Custom")
        }
        DisclosureGroup("Spring physics") {
            LabeledSlider(label: "Stiffness", value: Binding(get: { binding.wrappedValue.stiffness }, set: { binding.wrappedValue.stiffness = $0 }), range: 20...1200, format: "%.0f")
            LabeledSlider(label: "Damping", value: Binding(get: { binding.wrappedValue.damping }, set: { binding.wrappedValue.damping = $0 }), range: 2...150, format: "%.0f")
            LabeledSlider(label: "Mass", value: Binding(get: { binding.wrappedValue.mass }, set: { binding.wrappedValue.mass = $0 }), range: 0.2...8, format: "%.1f")
        }
        .font(.callout)
    }
}

// MARK: - Zoom

private struct ZoomInspector: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        Group {
            Group2(title: "Zooms") {
                Text("\(model.project.zoomRanges.count) zoom\(model.project.zoomRanges.count == 1 ? "" : "s") in this project. Click the purple track on the timeline to add one; select one to edit it.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Regenerate from clicks") { model.regenerateAutoZooms() }
                    Button("Remove all", role: .destructive) { model.removeAllZooms() }
                        .disabled(model.project.zoomRanges.isEmpty)
                }
                LabeledSlider(label: "Default zoom", value: styleBinding(model, \.defaultZoom), range: 1.2...5, format: "%.1fx")
                Toggle("Always keep zoomed in", isOn: styleBinding(model, \.alwaysKeepZoomedIn))
                LabeledSlider(label: "Follow margin", value: styleBinding(model, \.followEdgeMargin), range: 0...0.45)
            }
            Group2(title: "Camera movement") {
                springPicker(binding: styleBinding(model, \.zoomSpring), presets: SpringConfig.cameraPresets)
            }
            Group2(title: "Motion blur") {
                LabeledSlider(label: "Panning", value: styleBinding(model, \.motionBlurPan), range: 0...1)
                LabeledSlider(label: "Zooming", value: styleBinding(model, \.motionBlurZoom), range: 0...1)
                LabeledSlider(label: "Cursor", value: styleBinding(model, \.motionBlurCursor), range: 0...1)
            }
        }
    }
}

// MARK: - Camera

private struct CameraInspector: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        let style = model.project.style
        Group {
            if !model.project.hasCameraVideo {
                Text("This recording has no camera video. Pick a camera in the recording bar before recording to add a camera bubble.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Section {
                    Toggle("Show camera", isOn: Binding(get: { !style.hideCamera }, set: { v in model.updateStyle { $0.hideCamera = !v } }))
                } footer: {
                    if style.hideCamera {
                        Label("The camera is hidden, so the settings below have no effect until you show it again.", systemImage: "eye.slash")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
                Group2(title: "Position") {
                    Picker("Corner", selection: Binding(
                        get: { style.cameraCorner },
                        set: { v in model.updateStyle { $0.cameraCorner = v } }
                    )) {
                        Image(systemName: "arrow.up.left").help("Top left").tag(CameraCorner.topLeft)
                        Image(systemName: "arrow.up.right").help("Top right").tag(CameraCorner.topRight)
                        Image(systemName: "arrow.down.left").help("Bottom left").tag(CameraCorner.bottomLeft)
                        Image(systemName: "arrow.down.right").help("Bottom right").tag(CameraCorner.bottomRight)
                        Text("Custom").tag(CameraCorner.custom)
                    }
                    .pickerStyle(.segmented)
                    if style.cameraCorner == .custom {
                        LabeledSlider(label: "Horizontal", value: styleBinding(model, \.cameraCustomX), range: 0...1)
                        LabeledSlider(label: "Vertical", value: styleBinding(model, \.cameraCustomY), range: 0...1)
                    }
                }
                .disabled(style.hideCamera)
                Group2(title: "Shape") {
                    LabeledSlider(label: "Size", value: styleBinding(model, \.cameraSize), range: 0.1...0.6)
                    LabeledSlider(label: "Roundness", value: styleBinding(model, \.cameraRoundness), range: 0...1)
                    Picker("Aspect", selection: styleBinding(model, \.cameraAspect)) {
                        ForEach(CameraAspect.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    LabeledSlider(label: "Shadow", value: styleBinding(model, \.cameraShadow), range: 0...1)
                    LabeledSlider(label: "Border", value: styleBinding(model, \.cameraBorderWidth), range: 0...16, format: "%.0f")
                        .disabled(style.cameraRemoveBackground)
                        .help(style.cameraRemoveBackground ? "Borders don't apply when the background is removed" : "")
                }
                .disabled(style.hideCamera)
                Group2(title: "Behavior") {
                    Toggle("Mirror", isOn: styleBinding(model, \.mirrorCamera))
                    LabeledSlider(label: "Size when zoomed", value: styleBinding(model, \.cameraScaleDuringZoom), range: 0.3...1.2, format: "%.1fx")
                    Toggle("Auto-frame (keep face centred)", isOn: styleBinding(model, \.cameraAutoFrame))
                    LabeledSlider(label: "Camera zoom", value: styleBinding(model, \.cameraZoom), range: 1...2.5, format: "%.1fx")
                    Toggle("Remove background", isOn: styleBinding(model, \.cameraRemoveBackground))
                        .help("Cuts you out of your surroundings using on-device person segmentation")
                    if style.cameraRemoveBackground {
                        Text("Shows just you, trimmed to the camera shape. The shadow follows your outline; the border is off.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(style.hideCamera)
                Group2(title: "Layouts") {
                    Text("Switch layout for part of the video:").font(.callout).foregroundStyle(.secondary)
                    HStack {
                        ForEach(LayoutKind.allCases, id: \.self) { kind in
                            Button(kind.label) { model.addLayout(kind: kind) }.controlSize(.small)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Audio

private struct AudioInspector: View {
    @ObservedObject var model: EditorModel
    @State private var silenceThreshold: Double = -38
    @State private var silenceMin: Double = 1.0
    @State private var typingFactor: Double = 3

    var body: some View {
        let style = model.project.style
        Group {
            LabeledSlider(label: "Master volume", value: styleBinding(model, \.masterVolume), range: 0...2)
            if model.project.hasMicrophone {
                Group2(title: "Microphone") {
                    Toggle("Mute", isOn: styleBinding(model, \.muteMicrophone))
                    LabeledSlider(label: "Volume", value: styleBinding(model, \.microphoneVolume), range: 0...2)
                    Toggle("Improve audio (EQ, noise gate, leveling)", isOn: Binding(get: { style.improveMicrophone }, set: { model.setImproveMicrophone($0) }))
                }
            }
            if model.project.hasSystemAudio {
                Group2(title: "System audio") {
                    Toggle("Mute", isOn: styleBinding(model, \.muteSystemAudio))
                    LabeledSlider(label: "Volume", value: styleBinding(model, \.systemAudioVolume), range: 0...2)
                }
            }
            Group2(title: "Background music") {
                HStack {
                    Text(style.backgroundMusicPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "None")
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.audio]
                        if panel.runModal() == .OK, let url = panel.url {
                            model.updateStyle { $0.backgroundMusicPath = url.path }
                        }
                    }
                    if style.backgroundMusicPath != nil {
                        Button { model.updateStyle { $0.backgroundMusicPath = nil } } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                    }
                }
                if style.backgroundMusicPath != nil {
                    Toggle("Mute", isOn: styleBinding(model, \.muteBackgroundMusic))
                    LabeledSlider(label: "Volume", value: styleBinding(model, \.backgroundMusicVolume), range: 0...1)
                }
            }
            Group2(title: "Click sounds") {
                Toggle("Play a click on every mouse click", isOn: styleBinding(model, \.clickSound))
                if style.clickSound {
                    LabeledSlider(label: "Volume", value: styleBinding(model, \.clickSoundVolume), range: 0...1)
                }
            }
            Group2(title: "Smart edits") {
                Text("Remove silences").font(.callout.weight(.medium))
                LabeledSlider(label: "Threshold", value: $silenceThreshold, range: -60 ... -20, format: "%.0f", suffix: "dB")
                LabeledSlider(label: "Longer than", value: $silenceMin, range: 0.4...4, format: "%.1f", suffix: "s")
                Button("Cut silent parts") { model.removeSilences(thresholdDb: silenceThreshold, minDuration: silenceMin) }
                    .disabled(model.waveform.isEmpty)
                Divider()
                Text("Speed up typing").font(.callout.weight(.medium))
                LabeledSlider(label: "Speed", value: $typingFactor, range: 1.5...8, format: "%.1fx")
                Button("Speed up typing segments") { model.speedUpTyping(factor: typingFactor) }
                Divider()
                Button("Restore all cut/sped-up parts") { model.resetCuts() }
                    .disabled(model.project.clips.count == 1 && model.project.clips.first?.speed == 1)
            }
        }
    }
}

// MARK: - Captions & keystrokes

private struct CaptionsInspector: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        let style = model.project.style
        Group {
            Group2(title: "Captions") {
                Toggle("Show captions", isOn: styleBinding(model, \.showCaptions))
                LabeledSlider(label: "Size", value: styleBinding(model, \.captionsSize), range: 0.5...2.5, format: "%.1fx")
                HStack {
                    Button(model.project.captions.isEmpty ? "Generate captions" : "Regenerate") { model.generateCaptions() }
                        .disabled(!(model.project.hasMicrophone || model.project.hasSystemAudio) || model.busyMessage != nil)
                    if !model.project.captions.isEmpty {
                        Button("Clear", role: .destructive) { model.clearCaptions() }
                    }
                }
                Text("Transcribed on this Mac with Apple's speech recognition.").font(.caption).foregroundStyle(.secondary)
                ForEach(model.project.captions) { caption in
                    HStack(alignment: .top, spacing: 6) {
                        Text(formatTime(model.renderState.clipMap.outputTimeClamped(atSource: caption.start), tenths: false))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .leading)
                            .onTapGesture { model.seek(to: model.renderState.clipMap.outputTimeClamped(atSource: caption.start)) }
                        TextField("", text: Binding(get: { caption.text }, set: { model.updateCaption(caption.id, text: $0) }), axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.callout)
                        Button { model.deleteCaption(caption.id) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 4).fill(model.selection == .caption(caption.id) ? Color.accentColor.opacity(0.15) : .clear))
                }
            }
            Group2(title: "Keyboard shortcuts") {
                Toggle("Show pressed shortcuts", isOn: styleBinding(model, \.showShortcuts))
                if style.showShortcuts {
                    Toggle("Include regular typing", isOn: styleBinding(model, \.shortcutsSingleLetters))
                    LabeledSlider(label: "Size", value: styleBinding(model, \.shortcutsSize), range: 0.5...2.5, format: "%.1fx")
                }
                if !model.events.contains(where: { $0.kind == .keyDown }) {
                    Text("No keystrokes were recorded (enable “Record keystrokes” in Settings).").font(.caption).foregroundStyle(.secondary)
                }
            }
            Group2(title: "Masks") {
                Text("Blur, pixelate or spotlight part of the screen:").font(.callout).foregroundStyle(.secondary)
                HStack {
                    ForEach(MaskKind.allCases, id: \.self) { kind in
                        Button(kind.label) { model.addMask(kind: kind) }.controlSize(.small)
                    }
                }
            }
        }
    }
}

// MARK: - Selection

private struct SelectionInspector: View {
    @ObservedObject var model: EditorModel
    @State private var frame: CGImage?
    @State private var frameTime: Double = -1

    var body: some View {
        Group {
            if model.multiSelection.count > 1 {
                Section {
                    Label("\(model.multiSelection.count) items selected", systemImage: "square.stack.3d.up")
                        .font(.headline)
                    Text("Drag one of them on the timeline to move the group (zooms, masks and layouts move together), or delete them all. Shift-click an item to add or remove it.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Delete \(model.multiSelection.count) items", role: .destructive) { model.deleteSelected() }
                }
            } else {
            switch model.selection {
            case .clip(let id):
                if let clip = model.project.clips.first(where: { $0.id == id }) { clipEditor(clip) }
            case .zoom(let id):
                if let zoom = model.project.zoomRanges.first(where: { $0.id == id }) { zoomEditor(zoom) }
            case .mask(let id):
                if let mask = model.project.masks.first(where: { $0.id == id }) { maskEditor(mask) }
            case .layout(let id):
                if let layout = model.project.layouts.first(where: { $0.id == id }) { layoutEditor(layout) }
            case .caption(let id):
                if let caption = model.project.captions.first(where: { $0.id == id }) {
                    TextField("Caption", text: Binding(get: { caption.text }, set: { model.updateCaption(caption.id, text: $0) }), axis: .vertical)
                    Button("Delete caption", role: .destructive) { model.deleteCaption(caption.id) }
                }
            case nil:
                Text("Select a segment, zoom, mask or layout on the timeline to edit it here.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            }
        }
    }

    private var aspect: CGFloat {
        let s = model.renderState.recordingSize
        return s.height > 0 ? s.width / s.height : 16 / 9
    }

    private func loadFrame(at s: Double) {
        guard abs(s - frameTime) > 0.25 else { return }
        frameTime = s
        let url = model.folder.appendingPathComponent(model.project.screenFileName)
        Task { frame = await FrameGrabber(url: url).frame(at: s) }
    }

    private func clipEditor(_ clip: Clip) -> some View {
        Section {
            Text("Segment · \(formatTime(clip.sourceStart)) – \(formatTime(clip.sourceEnd)) of recording").font(.callout).foregroundStyle(.secondary)
            Picker("Speed", selection: Binding(get: { clip.speed }, set: { v in model.updateClip(clip.id) { $0.speed = v } })) {
                ForEach([0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4, 6, 8], id: \.self) { Text(String(format: "%gx", $0)).tag($0) }
            }
            LabeledSlider(label: "Volume", value: Binding(get: { clip.volume }, set: { v in model.updateClip(clip.id, coalesce: "vol") { $0.volume = v } }), range: 0...2)
            Toggle("Hide cursor in this segment", isOn: Binding(get: { clip.hideCursor }, set: { v in model.updateClip(clip.id) { $0.hideCursor = v } }))
            HStack {
                Button("Split at playhead") { model.splitAtPlayhead() }
                Button("Delete segment", role: .destructive) { model.deleteClip(clip.id) }
                    .disabled(model.project.clips.count < 2)
            }
        }
    }

    private func zoomEditor(_ zoom: ZoomRange) -> some View {
        Section {
            LabeledSlider(label: "Zoom level", value: Binding(get: { zoom.scale }, set: { v in model.updateZoom(zoom.id, coalesce: "scale") { $0.scale = v } }), range: 1.1...5, format: "%.1fx")
            Picker("Focus", selection: Binding(get: { zoom.mode }, set: { v in model.updateZoom(zoom.id) { $0.mode = v } })) {
                ForEach(ZoomMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            if zoom.mode == .manual {
                Text("Drag to choose the zoom target:").font(.callout).foregroundStyle(.secondary)
                PointPickerView(image: frame, aspect: aspect, point: Binding(
                    get: { zoom.target },
                    set: { p in model.updateZoom(zoom.id, coalesce: "target") { $0.targetX = p.x; $0.targetY = p.y } }
                ), zoomScale: zoom.scale)
                .onAppear { loadFrame(at: zoom.start) }
            }
            Toggle("Instant (no animation)", isOn: Binding(get: { zoom.instant }, set: { v in model.updateZoom(zoom.id) { $0.instant = v } }))
            Toggle("Disabled", isOn: Binding(get: { zoom.disabled }, set: { v in model.updateZoom(zoom.id) { $0.disabled = v } }))
            timeRangeFields(start: zoom.start, end: zoom.end) { s, e in model.updateZoom(zoom.id, coalesce: "times") { $0.start = s; $0.end = e } }
            Button("Delete zoom", role: .destructive) { model.deleteZoom(zoom.id) }
        }
    }

    private func maskEditor(_ mask: MaskRange) -> some View {
        Section {
            Picker("Type", selection: Binding(get: { mask.kind }, set: { v in model.updateMask(mask.id) { $0.kind = v } })) {
                ForEach(MaskKind.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            LabeledSlider(label: "Strength", value: Binding(get: { mask.intensity }, set: { v in model.updateMask(mask.id, coalesce: "int") { $0.intensity = v } }), range: 0...1)
            Text("Drag the box to position it; drag the corner to resize:").font(.callout).foregroundStyle(.secondary)
            RectEditorView(image: frame, aspect: aspect, rect: Binding(
                get: { mask.rect },
                set: { r in model.updateMask(mask.id, coalesce: "rect") { $0.rect = r } }
            ), tint: .orange, dimOutside: false)
            .onAppear { loadFrame(at: mask.start) }
            timeRangeFields(start: mask.start, end: mask.end) { s, e in model.updateMask(mask.id, coalesce: "times") { $0.start = s; $0.end = e } }
            Button("Delete mask", role: .destructive) { model.deleteMask(mask.id) }
        }
    }

    private func layoutEditor(_ layout: LayoutRange) -> some View {
        Section {
            Picker("Layout", selection: Binding(get: { layout.kind }, set: { v in model.updateLayout(layout.id) { $0.kind = v } })) {
                ForEach(LayoutKind.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            timeRangeFields(start: layout.start, end: layout.end) { s, e in model.updateLayout(layout.id, coalesce: "times") { $0.start = s; $0.end = e } }
            Button("Delete layout", role: .destructive) { model.deleteLayout(layout.id) }
        }
    }

    private func timeRangeFields(start: Double, end: Double, set: @escaping (Double, Double) -> Void) -> some View {
        Group {
            LabeledSlider(label: "Starts", value: Binding(get: { start }, set: { set(min($0, end - 0.2), end) }), range: 0...max(0.1, model.project.duration), format: "%.1f", suffix: "s")
            LabeledSlider(label: "Ends", value: Binding(get: { end }, set: { set(start, max($0, start + 0.2)) }), range: 0...max(0.1, model.project.duration), format: "%.1f", suffix: "s")
            HStack {
                Button("Start at playhead") { set(min(model.sourceTimeAtPlayhead, end - 0.2), end) }
                Button("End at playhead") { set(start, max(model.sourceTimeAtPlayhead, start + 0.2)) }
            }
            .controlSize(.small)
        }
    }
}
