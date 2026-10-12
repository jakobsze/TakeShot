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
                MainActor.assumeIsolated { AppDelegate.shared.positionBar() }
            },
            NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AppDelegate.shared.positionBar() }
            },
            // While the user drags the pill the mouse-up never reaches the
            // local monitor's window check reliably, so also finish on move end.
            NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { AppDelegate.shared.barMoved() }
            },
        ]
    }

    private var barObservers: [NSObjectProtocol] = []

    private var isPositioningBar = false

    /// Places the control pill. By default it sits centred at the bottom of
    /// the main display (the one with the menu bar), just above the Dock. If
    /// the user has dragged it somewhere, it stays centred on that spot
    /// (kept on screen) even when its width changes.
    func positionBar() {
        guard let window = mainWindow, let primary = NSScreen.screens.first else { return }
        let size = window.frame.size
        var origin: NSPoint
        if let center = AppSettings.shared.pillCenter {
            let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? primary
            let visible = screen.visibleFrame
            origin = NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
            origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - size.height - 4)
        } else {
            let visible = primary.visibleFrame
            origin = NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 24)
        }
        origin = NSPoint(x: origin.x.rounded(), y: origin.y.rounded())
        guard window.frame.origin != origin else { return }
        isPositioningBar = true
        window.setFrameOrigin(origin)
        isPositioningBar = false
    }

    /// Origin of the pill when the user pressed the mouse on it; a drag is a
    /// press on the pill followed by the window ending up somewhere else.
    private var barDragStartOrigin: NSPoint?
    private var barDragMonitor: Any?

    /// Remembers where the user drags the pill. Only presses that start on
    /// the pill count, so system-driven moves never change the saved spot.
    private func installBarDragTracking() {
        guard barDragMonitor == nil else { return }
        barDragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            guard let self, let window = self.mainWindow else { return event }
            if event.type == .leftMouseDown, event.window === window {
                self.barDragStartOrigin = window.frame.origin
            } else if event.type == .leftMouseUp, let start = self.barDragStartOrigin {
                self.barDragStartOrigin = nil
                let end = window.frame.origin
                if abs(end.x - start.x) > 2 || abs(end.y - start.y) > 2 {
                    AppSettings.shared.pillCenter = CGPoint(x: window.frame.midX, y: window.frame.midY)
                }
            }
            return event
        }
    }

    /// A window-server drag ends without a mouse-up event for us, so the
    /// move notification (debounced) completes the drag instead.
    private var barMoveWork: DispatchWorkItem?
    fileprivate func barMoved() {
        guard !isPositioningBar, barDragStartOrigin != nil, let window = mainWindow else { return }
        barMoveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, NSEvent.pressedMouseButtons & 1 == 0, let start = self.barDragStartOrigin else { return }
            self.barDragStartOrigin = nil
            let end = window.frame.origin
            if abs(end.x - start.x) > 2 || abs(end.y - start.y) > 2 {
                AppSettings.shared.pillCenter = CGPoint(x: window.frame.midX, y: window.frame.midY)
            }
        }
        barMoveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func resetBarPosition() {
        AppSettings.shared.pillCenter = nil
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
        menu.addItem(makeItem("Support Takeshot…", action: #selector(showSupport)))
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
            // Draggable by its background/grip; AppDelegate remembers the spot.
            window.isMovableByWindowBackground = true
            window.isMovable = true
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
