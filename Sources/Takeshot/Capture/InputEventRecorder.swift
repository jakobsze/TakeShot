import Foundation
import AppKit
import CoreGraphics
import ApplicationServices
import QuartzCore

/// Tracks global cursor movement, clicks and (optionally) key presses via a
/// listen-only CGEventTap, timestamped against CACurrentMediaTime() — the
/// same host clock ScreenCaptureKit stamps frames with — minus any time
/// spent paused, so events line up with the (pause-compressed) video.
final class InputEventRecorder {
    private var mouseTap: (CFMachPort, CFRunLoopSource)?
    private var keyTap: (CFMachPort, CFRunLoopSource)?
    private var sessionStart: CFTimeInterval = 0
    private var pausedTotal: CFTimeInterval = 0
    private var pauseStartedAt: CFTimeInterval?
    private var recordKeys = true
    private(set) var log = InputEventLog()

    static func ensureAccessibilityPermission() {
        let opts: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    /// Session-relative time for "now", excluding paused spans.
    func sessionTime(_ now: CFTimeInterval = CACurrentMediaTime()) -> Double {
        now - sessionStart - pausedTotal
    }

    func start(sessionStart: CFTimeInterval, recordKeystrokes: Bool) {
        self.sessionStart = sessionStart
        self.recordKeys = recordKeystrokes
        pausedTotal = 0
        pauseStartedAt = nil
        log = InputEventLog()

        let mouseMask = (1 << CGEventType.mouseMoved.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.rightMouseUp.rawValue)
            | (1 << CGEventType.rightMouseDragged.rawValue)
            | (1 << CGEventType.scrollWheel.rawValue)
        if let tap = makeTap(mask: CGEventMask(mouseMask)) {
            mouseTap = tap
        } else {
            NSLog("InputEventRecorder: failed to create mouse event tap — Accessibility permission likely not granted.")
        }

        // Keyboard gets its own tap: key events need Input Monitoring
        // permission, and a single combined tap without it was observed to
        // deliver nothing at all — losing cursor tracking too.
        if recordKeystrokes {
            if CGPreflightListenEventAccess() {
                keyTap = makeTap(mask: CGEventMask(1 << CGEventType.keyDown.rawValue))
            } else {
                CGRequestListenEventAccess()
                NSLog("InputEventRecorder: Input Monitoring not granted; keystrokes won't be recorded this time.")
            }
        }

        // Seed an initial position so the cursor is visible from frame one.
        let loc = CGEvent(source: nil)?.location ?? .zero
        log.events.append(InputEvent(t: 0, x: loc.x, y: loc.y, kind: .move))
    }

    private func makeTap(mask: CGEventMask) -> (CFMachPort, CFRunLoopSource)? {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let recorder = Unmanaged<InputEventRecorder>.fromOpaque(refcon).takeUnretainedValue()
                recorder.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else { return nil }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)!
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return (tap, source)
    }

    func pause() {
        guard pauseStartedAt == nil else { return }
        pauseStartedAt = CACurrentMediaTime()
    }

    func resume() {
        guard let started = pauseStartedAt else { return }
        pausedTotal += CACurrentMediaTime() - started
        pauseStartedAt = nil
    }

    var isPaused: Bool { pauseStartedAt != nil }

    func stop() {
        for tap in [mouseTap, keyTap].compactMap({ $0 }) {
            CGEvent.tapEnable(tap: tap.0, enable: false)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), tap.1, .commonModes)
        }
        mouseTap = nil
        keyTap = nil
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            for tap in [mouseTap, keyTap].compactMap({ $0 }) { CGEvent.tapEnable(tap: tap.0, enable: true) }
            return
        }
        guard !isPaused else { return }
        let t = sessionTime()
        guard t >= 0 else { return }
        let loc = event.location
        switch type {
        case .leftMouseDown:
            log.events.append(InputEvent(t: t, x: loc.x, y: loc.y, kind: .leftDown))
        case .leftMouseUp:
            log.events.append(InputEvent(t: t, x: loc.x, y: loc.y, kind: .leftUp))
        case .rightMouseDown:
            log.events.append(InputEvent(t: t, x: loc.x, y: loc.y, kind: .rightDown))
        case .rightMouseUp:
            log.events.append(InputEvent(t: t, x: loc.x, y: loc.y, kind: .rightUp))
        case .scrollWheel:
            log.events.append(InputEvent(t: t, x: loc.x, y: loc.y, kind: .scroll))
        case .keyDown:
            guard recordKeys, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let chars = NSEvent(cgEvent: event)?.charactersIgnoringModifiers
            log.events.append(InputEvent(t: t, x: loc.x, y: loc.y, kind: .keyDown, chars: chars, keyCode: keyCode, modifiers: event.flags.rawValue))
        default:
            log.events.append(InputEvent(t: t, x: loc.x, y: loc.y, kind: .move))
        }
    }
}

/// Samples the system-wide cursor image (arrow, I-beam, pointing hand, …)
/// during recording so the editor can redraw the *actual* cursor shapes at
/// any size, instead of baking the low-res system cursor into the video.
final class CursorShapeRecorder {
    private var timer: Timer?
    private var log = CursorShapeLog()
    private var fingerprints: [Data: Int] = [:]
    private var currentID: Int?
    private var folder: URL?
    private var timeSource: (() -> Double)?
    private var paused = false

    func start(folder: URL, time: @escaping () -> Double) {
        self.folder = folder
        self.timeSource = time
        log = CursorShapeLog()
        fingerprints = [:]
        currentID = nil
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent(CursorShapeLog.folderName), withIntermediateDirectories: true)
        sample()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.sample() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func setPaused(_ value: Bool) { paused = value }

    func stop() {
        timer?.invalidate()
        timer = nil
        guard let folder else { return }
        if let data = try? JSONEncoder().encode(log) {
            try? data.write(to: folder.appendingPathComponent(CursorShapeLog.fileName))
        }
    }

    private func sample() {
        guard !paused, let folder, let timeSource else { return }
        guard let cursor = NSCursor.currentSystem else { return }
        let image = cursor.image
        let hot = cursor.hotSpot
        guard let fingerprint = Self.fingerprint(image: image, hotSpot: hot) else { return }
        let id: Int
        if let existing = fingerprints[fingerprint] {
            id = existing
        } else {
            id = log.shapes.count
            guard let rendered = RenderAssets.cursorImage(from: image, hotSpot: hot) else { return }
            let fileName = "cursor-\(id).png"
            let url = folder.appendingPathComponent(CursorShapeLog.folderName).appendingPathComponent(fileName)
            if let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, rendered.image, nil)
                CGImageDestinationFinalize(dest)
            }
            log.shapes.append(CursorShape(id: id, fileName: fileName, hotX: hot.x, hotY: hot.y, width: image.size.width, height: image.size.height))
            fingerprints[fingerprint] = id
        }
        if id != currentID {
            currentID = id
            log.changes.append(CursorShapeChange(t: max(0, timeSource()), id: id))
        }
    }

    /// Cheap identity for a cursor image: size, hotspot and a 12×12 thumbnail.
    private static func fingerprint(image: NSImage, hotSpot: NSPoint) -> Data? {
        let side = 12
        var rect = NSRect(x: 0, y: 0, width: image.size.width, height: image.size.height)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let bytes = ctx.data else { return nil }
        var data = Data(bytes: bytes, count: side * side * 4)
        var meta = [Double(image.size.width), Double(image.size.height), Double(hotSpot.x), Double(hotSpot.y)]
        data.append(Data(bytes: &meta, count: meta.count * 8))
        return data
    }
}
