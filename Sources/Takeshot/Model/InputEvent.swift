import Foundation

/// A single cursor/click/key sample, timestamped in seconds relative to the
/// start of the recording session (see `Project.screenOffset` for how that
/// relates to video time).
struct InputEvent: Codable {
    enum Kind: String, Codable {
        case move
        case leftDown
        case leftUp
        case rightDown
        case rightUp
        case keyDown
        case scroll
    }

    let t: Double
    let x: Double
    let y: Double
    let kind: Kind
    /// keyDown only: characters ignoring modifiers, e.g. "s".
    var chars: String?
    /// keyDown only: virtual key code.
    var keyCode: Int?
    /// keyDown only: CGEventFlags raw value.
    var modifiers: UInt64?

    init(t: Double, x: Double, y: Double, kind: Kind, chars: String? = nil, keyCode: Int? = nil, modifiers: UInt64? = nil) {
        self.t = t
        self.x = x
        self.y = y
        self.kind = kind
        self.chars = chars
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    var isPress: Bool { kind == .leftDown || kind == .rightDown }
    var isRelease: Bool { kind == .leftUp || kind == .rightUp }
}

struct InputEventLog: Codable {
    var events: [InputEvent] = []
}

/// A cursor image captured from the system during recording.
struct CursorShape: Codable {
    let id: Int
    let fileName: String
    /// Hotspot in points from the image's top-left.
    let hotX: Double
    let hotY: Double
    /// Size in points.
    let width: Double
    let height: Double
}

/// Which cursor shape was showing from time `t` (session time) onward.
struct CursorShapeChange: Codable {
    let t: Double
    let id: Int
}

struct CursorShapeLog: Codable {
    var shapes: [CursorShape] = []
    var changes: [CursorShapeChange] = []

    static let fileName = "cursors.json"
    static let folderName = "cursors"
}
