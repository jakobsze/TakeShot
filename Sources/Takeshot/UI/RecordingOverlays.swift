import SwiftUI
import AppKit
import AVFoundation
import Carbon

/// Non-activating floating panel used for the countdown, recording widget
/// and camera preview. All are this app's own windows, which ScreenCapture
/// excludes from display/area recordings, so none of them end up in the video.
private final class OverlayPanel: NSPanel {
    init(contentRect: NSRect, interactive: Bool) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = interactive
        level = .statusBar
        isFloatingPanel = true
        hidesOnDeactivate = false
        ignoresMouseEvents = !interactive
        isMovableByWindowBackground = interactive
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
}

private func screen(for displayID: CGDirectDisplayID?) -> NSScreen {
    if let displayID, let match = NSScreen.screens.first(where: {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
    }) {
        return match
    }
    return NSScreen.main ?? NSScreen.screens[0]
}

// MARK: - Countdown

@MainActor
enum CountdownOverlay {
    private static var panel: NSPanel?

    static func run(seconds: Int, displayID: CGDirectDisplayID?, playSounds: Bool, cancelled: @escaping () -> Bool) async -> Bool {
        guard seconds > 0 else { return true }
        let target = screen(for: displayID)
        let size: CGFloat = 220
        let frame = NSRect(x: target.frame.midX - size / 2, y: target.frame.midY - size / 2, width: size, height: size)
        let panel = OverlayPanel(contentRect: frame, interactive: false)
        let model = CountdownModel(value: seconds)
        panel.contentView = NSHostingView(rootView: CountdownView(model: model))
        panel.orderFrontRegardless()
        self.panel = panel
        defer {
            panel.orderOut(nil)
            self.panel = nil
        }
        for value in stride(from: seconds, through: 1, by: -1) {
            model.value = value
            if playSounds { NSSound(named: "Tink")?.play() }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if cancelled() { return false }
        }
        return true
    }
}

@MainActor
private final class CountdownModel: ObservableObject {
    @Published var value: Int
    init(value: Int) { self.value = value }
}

private struct CountdownView: View {
    @ObservedObject var model: CountdownModel

    var body: some View {
        ZStack {
            Circle().fill(.clear).floatingSurface(Circle())
            Text("\(model.value)")
                .font(.system(size: 110, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.25), value: model.value)
        }
        .padding(10)
    }
}

// MARK: - Recording widget

@MainActor
enum RecordingWidget {
    private static var panel: NSPanel?

    static func show(recorder: RecorderViewModel, displayID: CGDirectDisplayID?) {
        hide()
        let target = screen(for: displayID)
        let size = NSSize(width: 286, height: 50)
        let frame = NSRect(x: target.visibleFrame.midX - size.width / 2, y: target.visibleFrame.minY + 24, width: size.width, height: size.height)
        let panel = OverlayPanel(contentRect: frame, interactive: true)
        panel.contentView = NSHostingView(rootView: RecordingWidgetView(recorder: recorder))
        panel.orderFrontRegardless()
        self.panel = panel
    }

    static func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct RecordingWidgetView: View {
    @ObservedObject var recorder: RecorderViewModel
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(recorder.isPaused ? Color(nsColor: .systemYellow) : Color(nsColor: .systemRed))
                .frame(width: 10, height: 10)
                .opacity(recorder.isPaused ? 1 : (pulse ? 0.35 : 1))
                .animation(.easeInOut(duration: 0.8).repeatForever(), value: pulse)
                .onAppear { pulse = true }
            Text(formatTime(recorder.elapsed, tenths: false))
                .font(.body.monospacedDigit().weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 48, alignment: .leading)
            Spacer(minLength: 0)
            widgetButton(recorder.isPaused ? "play.fill" : "pause.fill", help: recorder.isPaused ? "Resume (⌥⇧⌘P)" : "Pause (⌥⇧⌘P)") { recorder.togglePause() }
            widgetButton("arrow.counterclockwise", help: "Restart recording") { recorder.restartRecording() }
            widgetButton("trash", help: "Cancel and discard (⌥⇧⌘X)") { recorder.cancelRecording() }
            Button { recorder.toggleRecording() } label: {
                Image(systemName: "stop.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color(nsColor: .systemRed))
                    .font(.system(size: 28))
            }
            .buttonStyle(.plain)
            .help("Stop recording (⌥⇧⌘R)")
        }
        .padding(.horizontal, 14)
        .frame(width: 286, height: 50)
        .floatingSurface(Capsule())
        .disabled(recorder.isBusy)
    }

    private func widgetButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.callout.weight(.semibold)).foregroundStyle(.primary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Camera preview

@MainActor
enum CameraPreviewWindow {
    private static var panel: NSPanel?

    static func show() {
        guard panel == nil else { return }
        let target = NSScreen.main ?? NSScreen.screens[0]
        let size: CGFloat = 180
        let frame = NSRect(x: target.visibleFrame.maxX - size - 30, y: target.visibleFrame.minY + 90, width: size, height: size)
        let panel = OverlayPanel(contentRect: frame, interactive: true)
        let view = CameraPreviewNSView(frame: NSRect(origin: .zero, size: frame.size))
        panel.contentView = view
        panel.orderFrontRegardless()
        self.panel = panel
    }

    static func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private final class CameraPreviewNSView: NSView {
    private let preview = AVCaptureVideoPreviewLayer(session: WebcamCaptureEngine.shared.session)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.cornerRadius = frame.width / 2
        layer?.masksToBounds = true
        layer?.borderWidth = 3
        layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        layer?.backgroundColor = NSColor.black.cgColor
        preview.videoGravity = .resizeAspectFill
        preview.frame = bounds
        preview.connection?.automaticallyAdjustsVideoMirroring = false
        if preview.connection?.isVideoMirroringSupported == true { preview.connection?.isVideoMirrored = true }
        layer?.addSublayer(preview)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        preview.frame = bounds
    }
}

// MARK: - Global hotkeys

/// System-wide shortcuts via Carbon's RegisterEventHotKey (no extra
/// permission needed): ⌥⇧⌘R start/stop, ⌥⇧⌘P pause/resume, ⌥⇧⌘X cancel.
@MainActor
enum GlobalHotKeys {
    enum Action: UInt32 {
        case toggleRecording = 1
        case togglePause = 2
        case cancel = 3
    }

    private static var handler: ((Action) -> Void)?
    private static var refs: [EventHotKeyRef] = []
    private static var installed = false

    static func register(_ handler: @escaping (Action) -> Void) {
        self.handler = handler
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            if let action = GlobalHotKeys.Action(rawValue: id.id) {
                DispatchQueue.main.async { MainActor.assumeIsolated { GlobalHotKeys.handler?(action) } }
            }
            return noErr
        }, 1, &spec, nil, nil)

        let mods = UInt32(cmdKey | optionKey | shiftKey)
        let keys: [(Action, Int)] = [(.toggleRecording, kVK_ANSI_R), (.togglePause, kVK_ANSI_P), (.cancel, kVK_ANSI_X)]
        for (action, key) in keys {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x5353_4C54), id: action.rawValue)
            if RegisterEventHotKey(UInt32(key), mods, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                refs.append(ref)
            }
        }
    }
}
