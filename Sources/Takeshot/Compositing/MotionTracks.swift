import Foundation
import CoreGraphics

/// Semi-implicit Euler damped spring, integrated at a fixed sub-step for
/// stability at high stiffness.
struct Spring1D {
    var x: Double
    var v: Double = 0

    mutating func step(toward target: Double, config: SpringConfig, dt: Double) {
        let a = (config.stiffness * (target - x) - config.damping * v) / max(0.01, config.mass)
        v += a * dt
        x += v * dt
    }

    mutating func snap(_ value: Double) {
        x = value
        v = 0
    }
}

private func smoothstep(_ x: Double) -> Double {
    let t = min(max(x, 0), 1)
    return t * t * (3 - 2 * t)
}

/// Precomputed cursor motion over the whole recording, sampled at a fixed
/// rate in *video* time. Precomputing (instead of simulating live) means
/// scrubbing, playback and export all see exactly the same path.
struct CursorTrack {
    static let rate: Double = 120

    struct Click {
        let t: Double
        let position: CGPoint
    }

    /// Normalized (0...1, top-left origin) recording-space position.
    private var px: [Double] = []
    private var py: [Double] = []
    /// Velocity in normalized units per second.
    private var vx: [Double] = []
    private var vy: [Double] = []
    private var tilt: [Double] = []
    private var press: [Double] = []
    private var alpha: [Double] = []
    private(set) var clicks: [Click] = []
    private var shapeChanges: [(t: Double, id: Int)] = []

    var isEmpty: Bool { px.isEmpty }

    init(events: [InputEvent], shapes: CursorShapeLog?, project: Project) {
        let style = project.style
        let frame = project.displayFrame
        guard frame.width > 0, frame.height > 0 else { return }
        let offset = project.screenOffset
        let duration = max(project.duration, 0.1)

        // Positional samples in video time and points relative to the frame.
        var samples: [(t: Double, x: Double, y: Double)] = []
        var buttonEvents: [(t: Double, down: Bool)] = []
        let shakeThreshold = style.removeCursorShake ? 2.5 : 0
        for e in events where e.kind != .keyDown {
            let t = e.t - offset
            let x = e.x - frame.minX
            let y = e.y - frame.minY
            if e.isPress {
                clicks.append(Click(t: t, position: CGPoint(x: x / frame.width, y: y / frame.height)))
                buttonEvents.append((t, true))
            } else if e.isRelease {
                buttonEvents.append((t, false))
            }
            if let last = samples.last, !e.isPress, !e.isRelease,
               hypot(x - last.x, y - last.y) < shakeThreshold, t - last.t < 0.3 {
                continue
            }
            samples.append((t, x, y))
        }
        samples.sort { $0.t < $1.t }
        guard !samples.isEmpty else { return }

        if let shapes {
            shapeChanges = shapes.changes.map { ($0.t - offset, $0.id) }.sorted { $0.0 < $1.0 }
        }

        let n = Int(duration * Self.rate) + 2
        px.reserveCapacity(n); py.reserveCapacity(n)
        vx.reserveCapacity(n); vy.reserveCapacity(n)
        tilt.reserveCapacity(n); press.reserveCapacity(n); alpha.reserveCapacity(n)

        let first = samples[0]
        var sx = Spring1D(x: first.x)
        var sy = Spring1D(x: first.y)
        var tiltSpring = Spring1D(x: 0)
        var pressSpring = Spring1D(x: 0)
        let tiltConfig = SpringConfig(mass: 1, stiffness: 260, damping: 30)
        var currentAlpha = 1.0
        var lastMoveTime = -100.0
        var sampleIndex = 0
        var buttonIndex = 0
        var buttonDown = false
        let subSteps = 4
        let dt = 1 / Self.rate
        let subDt = dt / Double(subSteps)

        func rawTarget(at t: Double) -> (Double, Double) {
            while sampleIndex + 1 < samples.count, samples[sampleIndex + 1].t <= t {
                sampleIndex += 1
            }
            let a = samples[sampleIndex]
            guard sampleIndex + 1 < samples.count, t > a.t else { return (a.x, a.y) }
            let b = samples[sampleIndex + 1]
            let f = (t - a.t) / max(0.0001, b.t - a.t)
            return (a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f)
        }

        var previousTarget = (first.x, first.y)
        for i in 0..<n {
            let t = Double(i) * dt
            var (tx, ty) = rawTarget(at: t)
            if hypot(tx - previousTarget.0, ty - previousTarget.1) > 0.75 {
                lastMoveTime = t
            }
            previousTarget = (tx, ty)
            if style.loopCursorAtEnd {
                let loopWindow = min(1.2, duration * 0.3)
                let f = smoothstep((t - (duration - loopWindow)) / loopWindow)
                tx += (first.x - tx) * f
                ty += (first.y - ty) * f
            }
            while buttonIndex < buttonEvents.count, buttonEvents[buttonIndex].t <= t {
                buttonDown = buttonEvents[buttonIndex].down
                buttonIndex += 1
            }

            if style.smoothCursor {
                for _ in 0..<subSteps {
                    sx.step(toward: tx, config: style.cursorSpring, dt: subDt)
                    sy.step(toward: ty, config: style.cursorSpring, dt: subDt)
                }
            } else {
                let ox = sx.x, oy = sy.x
                sx.x = tx; sy.x = ty
                sx.v = (tx - ox) / dt; sy.v = (ty - oy) / dt
            }
            let tiltTarget = max(-28, min(28, -sx.v * 0.02 * style.cursorTilt))
            for _ in 0..<subSteps {
                tiltSpring.step(toward: tiltTarget, config: tiltConfig, dt: subDt)
                pressSpring.step(toward: buttonDown ? 1 : 0, config: .clickDefault, dt: subDt)
            }
            if style.hideIdleCursor {
                let idle = t - lastMoveTime > style.idleCursorDelay
                let rate = dt / 0.25
                currentAlpha = idle ? max(0, currentAlpha - rate) : min(1, currentAlpha + rate * 2)
            }

            px.append(sx.x / frame.width)
            py.append(sy.x / frame.height)
            vx.append(sx.v / frame.width)
            vy.append(sy.v / frame.height)
            tilt.append(tiltSpring.x)
            press.append(min(1, max(0, pressSpring.x)))
            alpha.append(currentAlpha)
        }
    }

    private func sample(_ array: [Double], at t: Double) -> Double {
        guard !array.isEmpty else { return 0 }
        let f = max(0, t) * Self.rate
        let i = Int(f)
        if i >= array.count - 1 { return array[array.count - 1] }
        let frac = f - Double(i)
        return array[i] + (array[i + 1] - array[i]) * frac
    }

    func position(at t: Double) -> CGPoint? {
        guard !px.isEmpty else { return nil }
        return CGPoint(x: sample(px, at: t), y: sample(py, at: t))
    }

    func velocity(at t: Double) -> CGVector {
        CGVector(dx: sample(vx, at: t), dy: sample(vy, at: t))
    }

    func tiltDegrees(at t: Double) -> Double { sample(tilt, at: t) }
    func pressAmount(at t: Double) -> Double { sample(press, at: t) }
    func opacity(at t: Double) -> Double { alpha.isEmpty ? 1 : sample(alpha, at: t) }

    func shapeID(at t: Double) -> Int? {
        var result: Int?
        for change in shapeChanges {
            if change.t <= t { result = change.id } else { break }
        }
        return result ?? shapeChanges.first?.id
    }

    /// Ripple currently animating at t: position and progress 0...1.
    func activeRipple(at t: Double, duration: Double = 0.5) -> (position: CGPoint, progress: Double)? {
        guard let click = clicks.last(where: { $0.t <= t && t - $0.t <= duration }) else { return nil }
        return (click.position, (t - click.t) / duration)
    }
}

/// Precomputed camera (zoom scale + focal point) motion in video time.
/// Focal point and viewport are normalized within the *cropped* recording.
struct ViewportTrack {
    static let rate: Double = 120

    private var scale: [Double] = []
    private var fx: [Double] = []
    private var fy: [Double] = []

    init(project: Project, cursor: CursorTrack?) {
        let style = project.style
        let crop = style.cropRect
        let duration = max(project.duration, 0.1)
        let ranges = project.zoomRanges.filter { !$0.disabled && $0.end > $0.start }.sorted { $0.start < $1.start }

        func toCrop(_ p: CGPoint) -> CGPoint {
            CGPoint(x: (p.x - crop.minX) / max(0.01, crop.width), y: (p.y - crop.minY) / max(0.01, crop.height))
        }

        let n = Int(duration * Self.rate) + 2
        scale.reserveCapacity(n); fx.reserveCapacity(n); fy.reserveCapacity(n)
        var ss = Spring1D(x: 1)
        var sx = Spring1D(x: 0.5)
        var sy = Spring1D(x: 0.5)
        var follow = CGPoint(x: 0.5, y: 0.5)
        var currentRangeID: UUID?
        var lastRange: ZoomRange?
        let subSteps = 4
        let dt = 1 / Self.rate
        let subDt = dt / Double(subSteps)
        var rangeIndex = 0

        for i in 0..<n {
            let t = Double(i) * dt
            while rangeIndex < ranges.count, ranges[rangeIndex].end < t { rangeIndex += 1 }
            let active: ZoomRange? = (rangeIndex < ranges.count && ranges[rangeIndex].start <= t) ? ranges[rangeIndex] : nil
            let effective = active ?? (style.alwaysKeepZoomedIn && rangeIndex > 0 ? lastRange : nil)

            var targetScale = 1.0
            if let r = effective {
                targetScale = max(1, r.scale)
                let half = 0.5 / targetScale
                if r.mode == .manual {
                    follow = toCrop(r.target)
                } else if let c = cursor?.position(at: t) {
                    let cp = toCrop(c)
                    if currentRangeID != r.id {
                        follow = cp
                    } else {
                        let inner = max(0.0, half * (1 - 2 * style.followEdgeMargin))
                        if cp.x > follow.x + inner { follow.x = cp.x - inner }
                        if cp.x < follow.x - inner { follow.x = cp.x + inner }
                        if cp.y > follow.y + inner { follow.y = cp.y - inner }
                        if cp.y < follow.y - inner { follow.y = cp.y + inner }
                    }
                }
                follow.x = min(max(follow.x, half), 1 - half)
                follow.y = min(max(follow.y, half), 1 - half)
            }

            let entering = effective?.id != currentRangeID
            if entering {
                if let r = effective, r.instant {
                    ss.snap(targetScale); sx.snap(follow.x); sy.snap(follow.y)
                } else if effective == nil, let previous = ranges.first(where: { $0.id == currentRangeID }), previous.instant {
                    ss.snap(1)
                }
                currentRangeID = effective?.id
                if let effective { lastRange = effective }
            }

            for _ in 0..<subSteps {
                ss.step(toward: targetScale, config: style.zoomSpring, dt: subDt)
                sx.step(toward: follow.x, config: style.zoomSpring, dt: subDt)
                sy.step(toward: follow.y, config: style.zoomSpring, dt: subDt)
            }
            scale.append(max(1, ss.x))
            fx.append(sx.x)
            fy.append(sy.x)
        }
    }

    private func sample(_ array: [Double], at t: Double) -> Double {
        guard !array.isEmpty else { return 0 }
        let f = max(0, t) * Self.rate
        let i = Int(f)
        if i >= array.count - 1 { return array[array.count - 1] }
        return array[i] + (array[i + 1] - array[i]) * (f - Double(i))
    }

    func state(at t: Double) -> (scale: Double, focal: CGPoint) {
        guard !scale.isEmpty else { return (1, CGPoint(x: 0.5, y: 0.5)) }
        return (sample(scale, at: t), CGPoint(x: sample(fx, at: t), y: sample(fy, at: t)))
    }

    /// d(scale)/dt and d(focal)/dt, for motion blur.
    func derivative(at t: Double) -> (dScale: Double, dFocal: CGVector) {
        let h = 1 / Self.rate
        let a = state(at: t - h), b = state(at: t + h)
        return ((b.scale - a.scale) / (2 * h), CGVector(dx: (b.focal.x - a.focal.x) / (2 * h), dy: (b.focal.y - a.focal.y) / (2 * h)))
    }

    /// The visible sub-rect (normalized within the crop, top-left origin).
    static func viewportRect(scale: Double, focal: CGPoint) -> CGRect {
        guard scale > 1.0001 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let w = 1 / scale
        let x = min(max(focal.x - w / 2, 0), 1 - w)
        let y = min(max(focal.y - w / 2, 0), 1 - w)
        return CGRect(x: x, y: y, width: w, height: w)
    }
}

/// Keystroke overlay labels ("⌘ ⇧ S", or typed text) in video time.
struct KeystrokeTrack {
    struct Item {
        let start: Double
        var end: Double
        var label: String
    }

    private(set) var shortcuts: [Item] = []
    private(set) var typing: [Item] = []

    init(events: [InputEvent], offset: Double) {
        let keys = events.filter { $0.kind == .keyDown }.sorted { $0.t < $1.t }
        for e in keys {
            let t = e.t - offset
            let flags = e.modifiers ?? 0
            let cmd = flags & 0x100000 != 0
            let shift = flags & 0x20000 != 0
            let opt = flags & 0x80000 != 0
            let ctrl = flags & 0x40000 != 0
            let special = Self.specialKeyName(e.keyCode ?? -1)
            let char = (e.chars ?? "").uppercased()

            if cmd || ctrl || opt || special != nil {
                var parts: [String] = []
                if ctrl { parts.append("⌃") }
                if opt { parts.append("⌥") }
                if shift { parts.append("⇧") }
                if cmd { parts.append("⌘") }
                parts.append(special ?? (char.isEmpty ? "?" : char))
                if let last = shortcuts.last, last.end > t { shortcuts[shortcuts.count - 1].end = t }
                shortcuts.append(Item(start: t, end: t + 1.3, label: parts.joined(separator: " ")))
            } else if let c = e.chars, !c.isEmpty, c.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                if var last = typing.last, t < last.end {
                    last.label = String((last.label + c).suffix(28))
                    last.end = t + 1.0
                    typing[typing.count - 1] = last
                } else {
                    typing.append(Item(start: t, end: t + 1.0, label: c))
                }
            }
        }
    }

    func label(at t: Double, includeTyping: Bool) -> (text: String, opacity: Double)? {
        func find(_ items: [Item]) -> (String, Double)? {
            guard let item = items.last(where: { $0.start <= t && t <= $0.end }) else { return nil }
            let fadeIn = min(1, (t - item.start) / 0.08)
            let fadeOut = min(1, (item.end - t) / 0.2)
            return (item.label, max(0, min(fadeIn, fadeOut)))
        }
        if let s = find(shortcuts) { return s }
        if includeTyping, let s = find(typing) { return s }
        return nil
    }

    /// Video-time ranges with sustained typing (for "speed up typing").
    func typingRuns(minDuration: Double = 1.5, maxGap: Double = 1.0, events: [InputEvent], offset: Double) -> [(Double, Double)] {
        let times = events.filter { $0.kind == .keyDown && ($0.modifiers ?? 0) & 0x1C0000 == 0 }.map { $0.t - offset }.sorted()
        var runs: [(Double, Double)] = []
        var start: Double?
        var last = 0.0
        for t in times {
            if let s = start, t - last > maxGap {
                if last - s >= minDuration { runs.append((s, last)) }
                start = t
            } else if start == nil {
                start = t
            }
            last = t
        }
        if let s = start, last - s >= minDuration { runs.append((s, last)) }
        return runs
    }

    static func specialKeyName(_ code: Int) -> String? {
        switch code {
        case 36, 76: return "↩"
        case 48: return "⇥"
        case 49: return "Space"
        case 51: return "⌫"
        case 53: return "esc"
        case 117: return "⌦"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 115: return "↖"
        case 119: return "↘"
        case 116: return "⇞"
        case 121: return "⇟"
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        default: return nil
        }
    }
}
