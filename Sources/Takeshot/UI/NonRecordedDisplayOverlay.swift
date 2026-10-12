import AppKit
import QuartzCore
import ScreenCaptureKit

/// While recording, darkens everything that is *not* being captured: other
/// displays entirely, the area outside a selected region, or everything
/// around a recorded window (the cut-out follows the window if it moves).
/// The overlays are this app's own click-through windows, which display and
/// area captures exclude, so the dimming never appears in the video.
@MainActor
enum NonRecordedDisplayOverlay {
    /// How dark the non-recorded parts get (0...1).
    static let dimAlpha: CGFloat = 0.78

    private static var windows: [(window: NSWindow, layer: CAShapeLayer, screen: NSScreen)] = []
    private static var trackingTimer: Timer?

    /// Display recording: dim every other display.
    static func show(recordingDisplayID: CGDirectDisplayID) {
        present(keepDisplay: recordingDisplayID, hole: nil)
    }

    /// Area recording: dim the rest of that display (and other displays).
    /// `rect` is in the display's local top-left-origin points.
    static func show(display: SCDisplay, area rect: CGRect) {
        let global = CGRect(x: display.frame.minX + rect.minX, y: display.frame.minY + rect.minY, width: rect.width, height: rect.height)
        present(keepDisplay: nil, hole: global)
    }

    /// Window recording: dim everything except the window, following it.
    static func show(window: SCWindow) {
        present(keepDisplay: nil, hole: window.frame, cornerRadius: 10)
        let id = window.windowID
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { _ in
            MainActor.assumeIsolated {
                if let frame = currentFrame(ofWindow: id) { updateHole(frame, cornerRadius: 10) }
            }
        }
    }

    static func hide() {
        trackingTimer?.invalidate()
        trackingTimer = nil
        windows.forEach { $0.window.orderOut(nil) }
        windows = []
    }

    // MARK: - Implementation

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    /// `hole` is in global top-left-origin coordinates (CoreGraphics / SCK).
    private static func present(keepDisplay: CGDirectDisplayID?, hole: CGRect?, cornerRadius: CGFloat = 0) {
        hide()
        for screen in NSScreen.screens {
            if let keepDisplay, displayID(of: screen) == keepDisplay { continue }
            // Passing `screen:` to the initializer mis-translated the frame
            // across displays with different scale factors, so the frame is
            // set explicitly after creation.
            let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
            window.setFrame(screen.frame, display: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            // .floating sits below many app windows; .screenSaver reliably
            // covers everything (the menu bar and Dock included).
            window.level = .screenSaver
            window.ignoresMouseEvents = true
            window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.wantsLayer = true
            let layer = CAShapeLayer()
            layer.frame = view.bounds
            layer.fillRule = .evenOdd
            layer.fillColor = NSColor.black.withAlphaComponent(dimAlpha).cgColor
            view.layer?.addSublayer(layer)
            window.contentView = view
            window.orderFrontRegardless()
            windows.append((window, layer, screen))
        }
        updateHole(hole, cornerRadius: cornerRadius)
    }

    private static func updateHole(_ hole: CGRect?, cornerRadius: CGFloat) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for entry in windows {
            let path = CGMutablePath()
            path.addRect(CGRect(origin: .zero, size: entry.screen.frame.size))
            if let hole {
                // Global top-left → Cocoa global → this screen's local space.
                let cocoa = CGRect(x: hole.minX, y: primaryHeight - hole.maxY, width: hole.width, height: hole.height)
                let local = cocoa.offsetBy(dx: -entry.screen.frame.minX, dy: -entry.screen.frame.minY)
                if local.intersects(CGRect(origin: .zero, size: entry.screen.frame.size)) {
                    path.addRoundedRect(in: local, cornerWidth: cornerRadius, cornerHeight: cornerRadius)
                }
            }
            entry.layer.path = path
        }
        CATransaction.commit()
    }

    private static func currentFrame(ofWindow id: CGWindowID) -> CGRect? {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let bounds = info.first?[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
        return CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
    }
}
