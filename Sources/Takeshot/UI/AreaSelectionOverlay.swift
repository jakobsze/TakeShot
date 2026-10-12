import AppKit
import ScreenCaptureKit

/// A full-screen click-drag overlay (one borderless window per connected
/// display) for picking a capture region, modeled on the system screenshot
/// tool's marquee selection. Resolves to the `SCDisplay` the selection was
/// made on plus the rect in that display's own local point space (top-left
/// origin, matching `SCDisplay.frame`'s convention) — nil if the user
/// cancels (Escape, or a drag too small to count).
@MainActor
enum AreaSelectionOverlay {
    static func present(completion: @escaping ((SCDisplay, CGRect)?) -> Void) {
        Coordinator.shared.present(completion: completion)
    }
}

@MainActor
private final class Coordinator {
    static let shared = Coordinator()

    private var windows: [NSWindow] = []
    private var completion: ((SCDisplay, CGRect)?) -> Void = { _ in }
    private var displays: [SCDisplay] = []
    private var finished = false

    func present(completion: @escaping ((SCDisplay, CGRect)?) -> Void) {
        self.completion = completion
        self.finished = false
        Task {
            let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            self.displays = content?.displays ?? []
            self.showOverlays()
        }
    }

    private func showOverlays() {
        windows.forEach { $0.orderOut(nil) }
        windows = []

        for screen in NSScreen.screens {
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .screenSaver
            window.ignoresMouseEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            window.hasShadow = false

            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.onFinish = { [weak self] localRect, cancelled in
                self?.finish(screen: screen, localRect: localRect, cancelled: cancelled)
            }
            window.contentView = view
            windows.append(window)
        }

        for window in windows {
            window.orderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        if let keyWindow = windows.first(where: { $0.screen == NSScreen.main }) ?? windows.first {
            keyWindow.makeKeyAndOrderFront(nil)
            keyWindow.makeFirstResponder(keyWindow.contentView)
        }
    }

    private func finish(screen: NSScreen, localRect: CGRect, cancelled: Bool) {
        guard !finished else { return }
        finished = true

        let closing = windows
        windows = []
        closing.forEach { $0.orderOut(nil) }

        guard !cancelled, localRect.width > 4, localRect.height > 4 else {
            completion(nil)
            return
        }

        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let display = displays.first(where: { $0.displayID == CGDirectDisplayID(screenNumber.uint32Value) }) else {
            completion(nil)
            return
        }

        // Flip from Cocoa's bottom-left-origin view space to the top-left
        // origin SCDisplay.frame (and CGEvent globals) use.
        let flipped = CGRect(
            x: localRect.minX,
            y: screen.frame.height - localRect.maxY,
            width: localRect.width,
            height: localRect.height
        )
        completion((display, flipped))
    }
}

private final class SelectionView: NSView {
    var onFinish: ((CGRect, Bool) -> Void)?
    private var startPoint: NSPoint?
    private var currentRect: NSRect = .zero

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentRect = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        currentRect = NSRect(
            x: min(start.x, point.x), y: min(start.y, point.y),
            width: abs(point.x - start.x), height: abs(point.y - start.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        onFinish?(currentRect, false)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onFinish?(.zero, true)
        } else {
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()

        guard currentRect.width > 0, currentRect.height > 0 else { return }

        NSColor.clear.setFill()
        currentRect.fill(using: .copy)

        NSColor.white.setStroke()
        let border = NSBezierPath(rect: currentRect)
        border.lineWidth = 1.5
        border.stroke()
    }
}
