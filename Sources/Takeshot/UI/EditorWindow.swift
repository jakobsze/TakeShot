import SwiftUI
import AVFoundation
import AppKit

struct EditorView: View {
    let folder: URL
    @StateObject private var loader: ProjectLoader

    init(folder: URL) {
        self.folder = folder
        _loader = StateObject(wrappedValue: ProjectLoader(folder: folder))
    }

    var body: some View {
        Group {
            if let model = loader.model {
                EditorContentView(model: model)
            } else if let error = loader.error {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 32))
                        .foregroundStyle(.orange)
                    Text("Couldn't load project").font(.headline)
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
                .padding(40)
                .frame(minWidth: 400, minHeight: 260)
            } else {
                ProgressView("Opening project…")
                    .frame(minWidth: 400, minHeight: 260)
            }
        }
    }
}

/// Process-wide cache of EditorModel keyed by project folder.
///
/// SwiftUI does not guarantee `@StateObject`'s wrapped-value expression runs
/// exactly once per view identity — under `WindowGroup(for: URL.self)` plus
/// repeated `openWindow(value:)` calls, this app observed 3-5 independent
/// loader/model instances get constructed for what was meant to be a single
/// editor window. Each one's init has real side effects (decoder sessions,
/// preview rendering), and with multiple live instances they starved each
/// other and the exporter of the hardware video decoder. Caching by folder
/// path makes construction idempotent regardless of how many times SwiftUI
/// calls it.
@MainActor
private var editorModelCache: [String: EditorModel] = [:]
@MainActor
private var editorModelLoads: [String: Task<EditorModel, Error>] = [:]

@MainActor
final class ProjectLoader: ObservableObject {
    @Published var model: EditorModel?
    @Published var error: String?

    init(folder: URL) {
        let key = folder.standardizedFileURL.path
        if let cached = editorModelCache[key] {
            model = cached
            return
        }
        let task = editorModelLoads[key] ?? Task { try await EditorModel.load(folder: folder) }
        editorModelLoads[key] = task
        Task {
            do {
                let created = try await task.value
                editorModelCache[key] = created
                model = created
            } catch {
                self.error = error.localizedDescription
            }
            editorModelLoads[key] = nil
        }
    }

    static func evict(folder: URL) {
        editorModelCache[folder.standardizedFileURL.path]?.player.pause()
        editorModelCache[folder.standardizedFileURL.path] = nil
    }
}

private struct EditorContentView: View {
    @ObservedObject var model: EditorModel
    @StateObject private var exportJob = ExportJob()
    @State private var showExport = false
    @State private var inspectorTab: InspectorTab = .background
    @State private var didAutoExport = false
    @State private var editingName = false
    @State private var nameDraft = ""
    @State private var presetNameDraft = ""
    @State private var showSavePreset = false
    @State private var presetNames: [String] = PresetStore.names()

    var body: some View {
        HSplitView {
                VStack(spacing: 0) {
                    PreviewArea(model: model)
                        .padding(14)
                        .frame(minHeight: 300)
                    transport
                        .padding(.horizontal, 14)
                        .padding(.bottom, 6)
                    EditorTimeline(model: model)
                        .frame(height: 254)
                }
                .frame(minWidth: 620)
                .background(Color(nsColor: .underPageBackgroundColor))

                InspectorPanel(model: model, tab: $inspectorTab)
                    .frame(minWidth: 300, idealWidth: 340, maxWidth: 440)
        }
        .frame(minWidth: 1080, minHeight: 700)
        .navigationTitle(model.project.name)
        .navigationSubtitle(formatTime(model.duration, tenths: false))
        .toolbar { editorToolbar }
        .sheet(isPresented: $showExport) {
            ExportSheet(model: model, job: exportJob, isPresented: $showExport)
        }
        .overlay(alignment: .top) { banner }
        .onChange(of: model.selection) { selection in
            if selection != nil { inspectorTab = .selection }
        }
        .onAppear {
            model.runLiveRefreshSelfTest()
            model.runMultiSelectSelfTest()
            if let raw = ProcessInfo.processInfo.environment["TAKESHOT_EDITOR_TAB"], let t = InspectorTab(rawValue: raw) { inspectorTab = t }
            if !didAutoExport, ProcessInfo.processInfo.environment["TAKESHOT_AUTO_EXPORT"] == "1" {
                didAutoExport = true
                let dest = model.folder.appendingPathComponent("export.\(model.project.export.format.fileExtension)")
                exportJob.start(state: model.renderState, settings: model.project.export, destination: dest)
                showExport = true
            }
        }
        .background(EditorKeyMonitor(onKey: handleKey))
        .onDisappear {
            model.pause()
            model.saveNow()
        }
        .alert("Save preset", isPresented: $showSavePreset) {
            TextField("Preset name", text: $presetNameDraft)
            Button("Save") {
                let name = presetNameDraft.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    PresetStore.save(model.project.style, name: name)
                    presetNames = PresetStore.names()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves every style setting (background, frame, cursor, camera, audio…) so you can reuse it.")
        }
        .alert("Rename project", isPresented: $editingName) {
            TextField("Name", text: $nameDraft)
            Button("Rename") { model.rename(nameDraft) }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var banner: some View {
        if let busy = model.busyMessage {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(busy).font(.callout)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            .padding(.top, 12)
        } else if let error = model.errorMessage {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                Text(error).font(.callout).lineLimit(2)
                Button {
                    model.errorMessage = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            .padding(.top, 12)
            .task(id: error) {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if model.errorMessage == error { model.errorMessage = nil }
            }
        }
    }

    /// Standard window toolbar (unified with the title bar).
    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                nameDraft = model.project.name
                editingName = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .help("Rename project")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            ControlGroup {
                Button { model.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .disabled(!model.canUndo)
                    .keyboardShortcut("z", modifiers: .command)
                    .help("Undo (⌘Z)")
                Button { model.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                    .disabled(!model.canRedo)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .help("Redo (⇧⌘Z)")
            }

            Picker(selection: styleBinding(model, \.aspectRatio)) {
                ForEach(AspectRatioOption.allCases, id: \.self) { Text($0.label).tag($0) }
            } label: {
                Label("Aspect Ratio", systemImage: "aspectratio")
            }
            .pickerStyle(.menu)
            .help("Output aspect ratio")

            Menu {
                if presetNames.isEmpty {
                    Text("No presets yet")
                } else {
                    Section("Apply preset") {
                        ForEach(presetNames, id: \.self) { name in
                            Button(name) { model.applyPreset(name) }
                        }
                    }
                }
                Divider()
                Button("Save current style as preset…") {
                    presetNameDraft = ""
                    showSavePreset = true
                }
                if !presetNames.isEmpty {
                    Menu("Default for new recordings") {
                        Button {
                            AppSettings.shared.defaultPresetName = nil
                        } label: {
                            if AppSettings.shared.defaultPresetName == nil { Label("Built-in defaults", systemImage: "checkmark") } else { Text("Built-in defaults") }
                        }
                        ForEach(presetNames, id: \.self) { name in
                            Button {
                                AppSettings.shared.defaultPresetName = name
                            } label: {
                                if AppSettings.shared.defaultPresetName == name { Label(name, systemImage: "checkmark") } else { Text(name) }
                            }
                        }
                    }
                    Menu("Delete preset") {
                        ForEach(presetNames, id: \.self) { name in
                            Button(name, role: .destructive) {
                                PresetStore.delete(name: name)
                                if AppSettings.shared.defaultPresetName == name { AppSettings.shared.defaultPresetName = nil }
                                presetNames = PresetStore.names()
                            }
                        }
                    }
                }
                Divider()
                Button("Reset style to defaults") {
                    model.updateStyle { s in
                        let crop = s.cropRect
                        s = StyleConfig()
                        s.cropRect = crop
                    }
                }
            } label: {
                Label("Presets", systemImage: "square.stack.3d.up")
            }
            .help("Style presets")
            .onAppear { presetNames = PresetStore.names() }

            Button {
                model.pause()
                exportJob.reset()
                showExport = true
            } label: {
                Text("Export")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .keyboardShortcut("e", modifiers: .command)
            .help("Export (⌘E)")
        }
        // Last, so it sits at the far right of the toolbar.
        ToolbarItem(placement: .primaryAction) {
            CoffeeButton(compact: true)
        }
    }

    private var transport: some View {
        HStack(spacing: 14) {
            Button { model.step(frames: -1) } label: { Image(systemName: "backward.frame.fill") }
                .buttonStyle(.borderless)
                .help("Previous frame (←)")
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 18))
                    .frame(width: 22)
            }
            .buttonStyle(.borderless)
            .help("Play / pause (Space)")
            Button { model.step(frames: 1) } label: { Image(systemName: "forward.frame.fill") }
                .buttonStyle(.borderless)
                .help("Next frame (→)")

            Text("\(formatTime(model.playhead)) / \(formatTime(model.duration))")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)

            Toggle(isOn: $model.loopPlayback) { Image(systemName: "repeat") }
                .toggleStyle(.button)
                .help("Loop playback")

            Spacer()

            Button { model.splitAtPlayhead() } label: { Label("Split", systemImage: "scissors") }
                .keyboardShortcut("b", modifiers: .command)
                .help("Split at playhead (⌘B)")
            Button { model.addZoom() } label: { Label("Zoom", systemImage: "plus.magnifyingglass") }
                .keyboardShortcut("z", modifiers: [.option])
                .help("Add zoom at playhead (⌥Z)")
            Menu {
                ForEach(MaskKind.allCases, id: \.self) { kind in
                    Button(kind.label) { model.addMask(kind: kind) }
                }
                if model.project.hasCameraVideo {
                    Divider()
                    ForEach(LayoutKind.allCases, id: \.self) { kind in
                        Button("Layout: \(kind.label)") { model.addLayout(kind: kind) }
                    }
                }
            } label: {
                Label("Add", systemImage: "plus.rectangle.on.rectangle")
            }
            .fixedSize()
            .help("Add a mask or a camera layout at the playhead")

            Button(role: .destructive) { deleteSelection() } label: { Image(systemName: "trash") }
                .disabled(model.multiSelection.isEmpty)
                .help("Delete selected item (⌫)")
        }
        .controlSize(.regular)
    }

    /// Space / Delete / arrows, handled here rather than as button
    /// shortcuts so they never steal keystrokes from text fields.
    private func handleKey(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 49: model.togglePlay()
        case 51, 117: deleteSelection()
        case 123: model.step(frames: -1)
        case 124: model.step(frames: 1)
        default: return false
        }
        return true
    }

    private func deleteSelection() {
        model.deleteSelected()
    }
}

/// The composited live preview: an AVPlayerLayer showing the player whose
/// video composition runs our custom compositor.
private struct PreviewArea: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        PlayerLayerView(player: model.player)
            .aspectRatio(model.previewCanvas.width / max(1, model.previewCanvas.height), contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { model.togglePlay() }
    }
}

struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerNSView {
        let view = PlayerNSView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ nsView: PlayerNSView, context: Context) {
        if nsView.playerLayer.player !== player { nsView.playerLayer.player = player }
    }

    final class PlayerNSView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = CALayer()
            layer?.backgroundColor = NSColor.black.cgColor
            playerLayer.videoGravity = .resizeAspect
            layer?.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }
}

/// Window-scoped key handler that ignores events while a text field is
/// being edited.
struct EditorKeyMonitor: NSViewRepresentable {
    let onKey: (UInt16) -> Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let window = context.coordinator.view?.window, event.window === window,
                  event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                  !(window.firstResponder is NSText) else { return event }
            return context.coordinator.onKey(event.keyCode) ? nil : event
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onKey = onKey
    }

    func makeCoordinator() -> Coordinator { Coordinator(onKey: onKey) }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
    }

    final class Coordinator {
        var onKey: (UInt16) -> Bool
        weak var view: NSView?
        var monitor: Any?
        init(onKey: @escaping (UInt16) -> Bool) { self.onKey = onKey }
    }
}
