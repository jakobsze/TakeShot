import SwiftUI
import AppKit

/// Actions the persistent menu-bar dropdown triggers, wired up once by
/// `RecordControlBar` on launch. Kept as plain closures (rather than a
/// reference back to `RecorderViewModel`) so `AppDelegate` doesn't need to
/// know that type exists.
struct MenuBarActions {
    var showMainWindow: () -> Void
    var recordDisplay: () -> Void
    var recordWindow: () -> Void
    var recordArea: () -> Void
    var showPreviousRecordings: () -> Void
    var showSettings: () -> Void
}

/// Opts out of macOS window-state restoration. In practice this alone
/// wasn't enough to stop it — SwiftUI's `WindowGroup(for: URL.self)` restores
/// one window per every URL value it has ever been opened with, independent
/// of this AppKit-level flag, so `applicationDidFinishLaunching` also force-
/// closes any Editor window still around from a restored prior session.
///
/// Also owns a persistent menu-bar status item, present from launch (not
/// just while recording) with a dropdown of quick actions when idle; while
/// recording, the dropdown is swapped out for a direct click-to-stop and the
/// floating bar hides, getting out of the way once you've started.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// `NSApp.delegate as? AppDelegate` does NOT work with SwiftUI's
    /// `@NSApplicationDelegateAdaptor` — `NSApp.delegate` points to a private
    /// `SwiftUI.AppDelegate` wrapper, not this instance, so that cast always
    /// silently returns nil. This static reference is the reliable way to
    /// reach it from elsewhere (confirmed via logging: enterRecordingMode
    /// was never actually being called).
    static private(set) var shared: AppDelegate!

    private weak var mainWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var stopAction: (() -> Void)?
    private var menuActions: MenuBarActions?
    private var dockHiddenForRecording = false

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        RenderAssets.prepare()
        if DebugHooks.runIfRequested() || TestHarness.runIfRequested() { return }
        NSApp.setActivationPolicy(AppSettings.shared.showInDock ? .regular : .accessory)
        AppUpdater.shared.start()
        if ProcessInfo.processInfo.environment["TAKESHOT_CHECK_UPDATES"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { AppUpdater.shared.checkForUpdates() }
        }
        DispatchQueue.main.async {
            for window in NSApp.windows {
                let identifier = window.identifier?.rawValue ?? ""
                if identifier.contains("Editor") || identifier.contains("projects") || window.title == "Editor" {
                    window.close()
                }
            }
            self.positionBar()
        }
        // Dev hook: show the drag guides with a highlighted target, e.g. "left:center".
        if let spec = ProcessInfo.processInfo.environment["TAKESHOT_TEST_DOCK_GUIDES"] {
            let parts = spec.split(separator: ":").map(String.init)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                DockGuides.show(horizontalSize: self.horizontalBarSize ?? self.mainWindow?.frame.size ?? NSSize(width: 383, height: 44),
                                verticalSize: self.verticalBarSize)
                if parts.count == 2, let side = PillDock.Side(rawValue: parts[0]), let spot = PillDock.Spot(rawValue: parts[1]) {
                    DockGuides.update(target: PillDock(side: side, spot: spot, displayID: NSScreen.screens.first.flatMap(PillDock.displayID(of:))))
                }
            }
        }
        // Dev hook: drag the pill with real mouse events, "fromX,fromY,toX,toY"
        // in global top-left coordinates (needs the app's Accessibility grant).
        if let spec = ProcessInfo.processInfo.environment["TAKESHOT_TEST_DRAG"] {
            let v = spec.split(separator: ",").compactMap { Double($0) }
            if v.count == 4 {
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    func post(_ type: CGEventType, _ x: Double, _ y: Double) {
                        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)?.post(tap: .cghidEventTap)
                    }
                    post(.mouseMoved, v[0], v[1]); usleep(100_000)
                    post(.leftMouseDown, v[0], v[1]); usleep(150_000)
                    for i in 1...40 {
                        let f = Double(i) / 40
                        post(.leftMouseDragged, v[0] + (v[2] - v[0]) * f, v[1] + (v[3] - v[1]) * f)
                        usleep(15_000)
                    }
                    usleep(200_000)
                    post(.leftMouseUp, v[2], v[3])
                    NSLog("TESTDRAG: released at \(v[2]),\(v[3]) axTrusted=\(AXIsProcessTrusted())")
                }
            }
        }
        setUpStatusItem()
    }

    func hideMainWindow() {
        mainWindow?.orderOut(nil)
    }

    func registerMainWindow(_ window: NSWindow) {
        mainWindow = window
        positionBar()
        installBarDragTracking()
        // Keep it pinned when its width changes (e.g. a longer device name)
        // and when displays are added, removed or rearranged.
        barObservers.forEach { NotificationCenter.default.removeObserver($0) }
        barObservers = [
            NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { AppDelegate.shared.barResized() }
            },
            NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AppDelegate.shared.positionBar() }
            },
        ]
    }

    private var barObservers: [NSObjectProtocol] = []

    /// The pill's last size in each orientation, for the dock guides.
    private var horizontalBarSize: NSSize?
    private var verticalBarSize = NSSize(width: 57, height: 361)

    private func barResized() {
        if let size = mainWindow?.frame.size {
            if AppSettings.shared.pillDock?.isVertical == true { verticalBarSize = size } else { horizontalBarSize = size }
        }
        positionBar()
    }

    /// Places the control pill. By default it sits centred at the bottom of
    /// the main display (the one with the menu bar), just above the Dock. If
    /// the user docked it to an edge/corner it is pinned there (see
    /// `PillDock`); if they dropped it elsewhere it stays centred on that spot
    /// (kept on screen). Both hold when its size changes.
    func positionBar(animated: Bool = false) {
        guard let window = mainWindow, let primary = NSScreen.screens.first else { return }
        let size = window.frame.size
        let settings = AppSettings.shared
        var origin: NSPoint
        if let dock = settings.pillDock {
            origin = dock.origin(for: size)
        } else if let center = settings.pillCenter {
            origin = PillDock.origin(centeredOn: center, size: size)
        } else {
            let visible = primary.visibleFrame
            origin = NSPoint(x: (visible.midX - size.width / 2).rounded(), y: visible.minY + 24)
        }
        guard window.frame.origin != origin else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                window.animator().setFrameOrigin(origin)
            }
        } else {
            window.setFrameOrigin(origin)
        }
    }

    /// Where the pill would dock if it were dropped now (nil = stays free).
    private func barDropTarget(_ window: NSWindow) -> PillDock? {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? window.screen ?? NSScreen.screens[0]
        let (horizontal, vertical) = barSizes(window)
        return PillDock.forDrop(cursor: mouse, on: screen, horizontalSize: horizontal, verticalSize: vertical)
    }

    /// The pill's size lying down and upright (the one not on screen is the last seen, or an estimate).
    private func barSizes(_ window: NSWindow) -> (NSSize, NSSize) {
        let isVertical = AppSettings.shared.pillDock?.isVertical ?? false
        return (isVertical ? (horizontalBarSize ?? NSSize(width: 383, height: 44)) : window.frame.size,
                isVertical ? window.frame.size : verticalBarSize)
    }

    /// A drag of the pill ended: dock it if it was dropped near an edge,
    /// otherwise remember the free spot.
    private func finishBarDrag(from start: NSPoint) {
        guard let window = mainWindow else { return }
        let end = window.frame.origin
        guard abs(end.x - start.x) > 2 || abs(end.y - start.y) > 2 else { return }
        let settings = AppSettings.shared
        let wasVertical = settings.pillDock?.isVertical ?? false
        if let dock = barDropTarget(window) {
            settings.pillDock = dock
        } else {
            settings.pillDock = nil
            settings.pillCenter = CGPoint(x: window.frame.midX, y: window.frame.midY)
        }
        // Snaps instantly; an orientation change also resizes the window,
        // which repositions it again via the resize observer.
        positionBar()
    }

    /// Docks the pill from the ⚙︎ menu, on the display it is currently on.
    func dockBar(side: PillDock.Side, spot: PillDock.Spot) {
        let screen = mainWindow?.screen ?? NSScreen.screens[0]
        AppSettings.shared.pillDock = PillDock(side: side, spot: spot, displayID: PillDock.displayID(of: screen))
        positionBar()
    }

    private var barDragMonitors: [Any] = []
    /// A press on the pill: where the mouse and the pill were, and whether it
    /// has turned into a drag yet.
    private var barDrag: (mouseStart: NSPoint, originStart: NSPoint, dragging: Bool)?

    /// The pill is moved by the app itself rather than by AppKit's window
    /// drag: that one moves the window asynchronously and reports the final
    /// position late, so a snap on release got undone or came late. Moving it
    /// here means the drop position is known on mouse-up and the snap is
    /// instant. Only presses that start on the pill count.
    private func installBarDragTracking() {
        guard barDragMonitors.isEmpty else { return }
        let mouse = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self, let window = self.mainWindow else { return event }
            switch event.type {
            case .leftMouseDown:
                self.barDrag = event.window === window ? (NSEvent.mouseLocation, window.frame.origin, false) : nil
                return event
            case .leftMouseDragged:
                guard var drag = self.barDrag else { return event }
                let mouse = NSEvent.mouseLocation
                let dx = mouse.x - drag.mouseStart.x, dy = mouse.y - drag.mouseStart.y
                if !drag.dragging {
                    guard hypot(dx, dy) > 3 else { return event }
                    drag.dragging = true
                    self.barDrag = drag
                    let (horizontal, vertical) = self.barSizes(window)
                    DockGuides.show(horizontalSize: horizontal, verticalSize: vertical)
                }
                window.setFrameOrigin(NSPoint(x: drag.originStart.x + dx, y: drag.originStart.y + dy))
                DockGuides.update(target: self.barDropTarget(window))
                return Self.awayFromControls(event)
            case .leftMouseUp:
                guard let drag = self.barDrag else { return event }
                self.barDrag = nil
                guard drag.dragging else { return event }
                DockGuides.hide()
                self.finishBarDrag(from: drag.originStart)
                return Self.awayFromControls(event)
            default:
                return event
            }
        }
        // A press that opens one of the pill's menus is not a drag.
        let menu = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                AppDelegate.shared.barDrag = nil
                DockGuides.hide()
            }
        }
        barDragMonitors = [mouse as Any, menu]
    }

    /// The same mouse event, but far outside the window, so a button the drag
    /// started on is cancelled instead of clicked (the pill moves with the
    /// cursor, so the cursor is still over that button on release).
    private static func awayFromControls(_ event: NSEvent) -> NSEvent {
        NSEvent.mouseEvent(with: event.type, location: NSPoint(x: -10_000, y: -10_000),
                           modifierFlags: event.modifierFlags, timestamp: event.timestamp,
                           windowNumber: event.windowNumber, context: nil, eventNumber: event.eventNumber,
                           clickCount: event.clickCount, pressure: event.pressure) ?? event
    }

    func resetBarPosition() {
        AppSettings.shared.pillCenter = nil
        AppSettings.shared.pillDock = nil
        positionBar()
    }

    func configureMenuActions(_ actions: MenuBarActions) {
        menuActions = actions
        applyIdleMenu()
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        statusItem = item
        applyIdleIcon()
        applyIdleMenu()
    }

    private func applyIdleIcon() {
        guard let button = statusItem?.button else { return }
        button.image = Self.coloredSymbol("record.circle", color: .systemBlue)
    }

    /// `NSStatusBarButton.contentTintColor` turned out unreliable for
    /// coloring status items (it's frequently just ignored) — baking the
    /// color into the symbol image itself via a palette configuration, and
    /// marking the result non-template, is what actually renders in color.
    private static func coloredSymbol(_ name: String, color: NSColor) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let config = NSImage.SymbolConfiguration(paletteColors: [color])
        let colored = base.withSymbolConfiguration(config)
        colored?.isTemplate = false
        return colored
    }

    private func applyIdleMenu() {
        guard let statusItem, let menuActions else { return }
        let menu = NSMenu()

        menu.addItem(makeItem("New Recording…", action: #selector(newRecording)))
        menu.addItem(.separator())
        menu.addItem(makeItem("Record Display", action: #selector(recordDisplay)))
        menu.addItem(makeItem("Record Window", action: #selector(recordWindow)))
        menu.addItem(makeItem("Record Area", action: #selector(recordArea)))
        menu.addItem(.separator())
        let dockItem = makeItem("Show in Dock", action: #selector(toggleDockVisibility))
        dockItem.state = AppSettings.shared.showInDock ? .on : .off
        menu.addItem(dockItem)
        menu.addItem(.separator())
        menu.addItem(makeItem("Recordings…", action: #selector(showPreviousRecordings)))
        menu.addItem(makeItem("Settings…", action: #selector(showSettings)))
        menu.addItem(makeItem("Check for Updates…", action: #selector(checkForUpdates)))
        menu.addItem(makeItem("Buy Me a Coffee…", action: #selector(showSupport)))
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit Takeshot", action: #selector(quit)))

        statusItem.menu = menu
        self.menuActions = menuActions
    }

    private func makeItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    /// Called when starting a recording — swaps the icon to a stop button
    /// and drops the menu so a click stops immediately instead of opening a
    /// dropdown (`NSStatusItem` shows its `.menu`, if any, on every click,
    /// so the menu has to be cleared to let a direct click-action through).
    func enterRecordingMode(hideDock: Bool, onStopRequested: @escaping () -> Void) {
        mainWindow?.orderOut(nil)
        if hideDock, AppSettings.shared.showInDock {
            dockHiddenForRecording = true
            NSApp.setActivationPolicy(.accessory)
        }
        stopAction = onStopRequested
        statusItem?.menu = nil
        statusItem?.button?.image = Self.coloredSymbol("stop.circle.fill", color: .systemRed)
    }

    func exitRecordingMode() {
        stopAction = nil
        if dockHiddenForRecording {
            dockHiddenForRecording = false
            NSApp.setActivationPolicy(.regular)
        }
        applyIdleIcon()
        applyIdleMenu()
        positionBar()
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func statusItemClicked() {
        // Only reached while recording — when idle, NSStatusItem shows
        // `.menu` instead of firing this action.
        stopAction?()
    }

    // MARK: - Idle menu actions

    @objc private func newRecording() {
        positionBar()
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        menuActions?.showMainWindow()
    }

    @objc private func recordDisplay() {
        menuActions?.recordDisplay()
    }

    @objc private func recordWindow() {
        menuActions?.recordWindow()
    }

    @objc private func recordArea() {
        menuActions?.recordArea()
    }

    @objc private func toggleDockVisibility() {
        AppSettings.shared.showInDock.toggle()
        applyIdleMenu()
    }

    @objc private func checkForUpdates() {
        AppUpdater.shared.checkForUpdates()
    }

    @objc private func showSupport() {
        Support.openDonatePage()
    }

    @objc private func showSettings() {
        menuActions?.showSettings()
    }

    @objc private func showPreviousRecordings() {
        menuActions?.showPreviousRecordings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

/// Makes the enclosing window a true borderless panel that exactly hugs the
/// pill's shape. Hiding the title bar via `.windowStyle` alone still
/// reserves its vertical space (an invisible strip above the content),
/// which showed up as a gap around the pill; dropping `.titled` from the
/// style mask entirely removes that reserved space.
///
/// A plain opaque NSWindow is always a rectangle — its shadow and edges are
/// hard right angles no matter what shape you draw inside it, which is why
/// the pill's rounded ends still sat inside a squared-off window. The
/// window itself has to be non-opaque with a clear background for AppKit to
/// compute the shadow/outline from the actual rendered (opaque) pixels —
/// i.e. the capsule shape — instead of the window's rectangular frame. The
/// pill fills the entire window with no margin, so in practice this isn't
/// "a transparent window" showing desktop through a gap (that was the
/// earlier, different problem) — the only non-opaque pixels are the few
/// outside the capsule's rounded corners.
struct FloatingBarWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.styleMask = [.borderless]
            // AppDelegate moves it on drag (see installBarDragTracking), so
            // AppKit's own window dragging is off.
            window.isMovableByWindowBackground = false
            window.isMovable = false
            window.setFrameAutosaveName("")
            window.collectionBehavior.insert(.canJoinAllSpaces)
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = true
            window.level = .floating
            AppDelegate.shared.registerMainWindow(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

@main
struct TakeshotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RecordControlBar()
                .background(FloatingBarWindowConfigurator())
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { AppUpdater.shared.checkForUpdates() }
            }
            CommandGroup(after: .newItem) {
                RecordingsMenuButton()
            }
        }

        WindowGroup("Editor", for: URL.self) { $folder in
            if let folder {
                EditorView(folder: folder)
            }
        }
        .defaultSize(width: 1320, height: 860)
        .windowToolbarStyle(.unified(showsTitle: true))

        Window("Recordings", id: "projects") {
            ProjectsWindow()
        }
        .defaultSize(width: 900, height: 620)

        Settings {
            SettingsView()
        }
    }
}

private struct RecordingsMenuButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Recordings…") { openWindow(id: "projects") }
            .keyboardShortcut("o", modifiers: [.command, .shift])
    }
}
