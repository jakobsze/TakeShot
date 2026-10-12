import Foundation
import CoreGraphics

/// Damped-spring parameters (the usual mass/stiffness/damping trio),
/// used for cursor smoothing, camera (zoom/pan) movement and the
/// click "press" animation.
struct SpringConfig: Codable, Equatable {
    var mass: Double
    var stiffness: Double
    var damping: Double

    static let cursorDefault = SpringConfig(mass: 2.5, stiffness: 420, damping: 62)
    static let cameraDefault = SpringConfig(mass: 2, stiffness: 180, damping: 36)
    static let clickDefault = SpringConfig(mass: 1, stiffness: 650, damping: 28)

    /// Named "feel" presets for the motion pickers.
    static let cursorPresets: [(String, SpringConfig)] = [
        ("Gentle", SpringConfig(mass: 3.5, stiffness: 280, damping: 64)),
        ("Smooth", .cursorDefault),
        ("Brisk", SpringConfig(mass: 1.8, stiffness: 560, damping: 58)),
        ("Snappy", SpringConfig(mass: 1, stiffness: 860, damping: 54)),
    ]
    static let cameraPresets: [(String, SpringConfig)] = [
        ("Gentle", SpringConfig(mass: 3.2, stiffness: 130, damping: 40)),
        ("Smooth", .cameraDefault),
        ("Brisk", SpringConfig(mass: 1.4, stiffness: 280, damping: 38)),
        ("Snappy", SpringConfig(mass: 1, stiffness: 460, damping: 40)),
    ]
}

enum BackgroundType: String, Codable, CaseIterable {
    case wallpaper, gradient, color, image
    var label: String {
        switch self {
        case .wallpaper: return "Wallpaper"
        case .gradient: return "Gradient"
        case .color: return "Color"
        case .image: return "Image"
        }
    }
}

struct GradientSpec: Codable, Equatable, Hashable {
    var startHex: String
    var endHex: String
    /// Degrees; 0 = left→right, 90 = top→bottom.
    var angle: Double

    static let presets: [GradientSpec] = [
        GradientSpec(startHex: "4338CA", endHex: "38BDF8", angle: 45),
        GradientSpec(startHex: "F72585", endHex: "7209B7", angle: 45),
        GradientSpec(startHex: "FF9A8B", endHex: "FF6A88", angle: 90),
        GradientSpec(startHex: "FBD786", endHex: "F7797D", angle: 45),
        GradientSpec(startHex: "43E97B", endHex: "38F9D7", angle: 45),
        GradientSpec(startHex: "0F2027", endHex: "2C5364", angle: 90),
        GradientSpec(startHex: "8E2DE2", endHex: "4A00E0", angle: 135),
        GradientSpec(startHex: "FC466B", endHex: "3F5EFB", angle: 45),
        GradientSpec(startHex: "1D2B64", endHex: "F8CDDA", angle: 90),
        GradientSpec(startHex: "C9D6FF", endHex: "E2E2E2", angle: 45),
        GradientSpec(startHex: "232526", endHex: "414345", angle: 90),
        GradientSpec(startHex: "FF512F", endHex: "F09819", angle: 45),
        GradientSpec(startHex: "00C6FF", endHex: "0072FF", angle: 90),
        GradientSpec(startHex: "F7971E", endHex: "FFD200", angle: 45),
        GradientSpec(startHex: "EECDA3", endHex: "EF629F", angle: 135),
        GradientSpec(startHex: "000000", endHex: "434343", angle: 90),
    ]
}

enum WindowFrameStyle: String, Codable, CaseIterable {
    case none, macLight, macDark, glass
    var label: String {
        switch self {
        case .none: return "None"
        case .macLight: return "macOS Light"
        case .macDark: return "macOS Dark"
        case .glass: return "Glass border"
        }
    }
}

enum AspectRatioOption: String, Codable, CaseIterable {
    case auto, r16x9, r9x16, r1x1, r4x3, r3x4, r4x5, r21x9
    var label: String {
        switch self {
        case .auto: return "Auto"
        case .r16x9: return "16:9 Wide"
        case .r9x16: return "9:16 Vertical"
        case .r1x1: return "1:1 Square"
        case .r4x3: return "4:3 Standard"
        case .r3x4: return "3:4"
        case .r4x5: return "4:5 Social"
        case .r21x9: return "21:9 Cinema"
        }
    }
    /// nil means "use the recording's own aspect".
    var ratio: Double? {
        switch self {
        case .auto: return nil
        case .r16x9: return 16.0 / 9
        case .r9x16: return 9.0 / 16
        case .r1x1: return 1
        case .r4x3: return 4.0 / 3
        case .r3x4: return 3.0 / 4
        case .r4x5: return 4.0 / 5
        case .r21x9: return 21.0 / 9
        }
    }
}

enum CursorStyle: String, Codable, CaseIterable {
    /// The real cursor shapes captured during recording (arrow, I-beam, hand…).
    case recorded
    /// Always the default macOS arrow.
    case arrow
    /// A soft circle, like a touch indicator.
    case touch
    var label: String {
        switch self {
        case .recorded: return "As recorded"
        case .arrow: return "macOS arrow"
        case .touch: return "Touch circle"
        }
    }
}

enum ClickEffect: String, Codable, CaseIterable {
    case none, ripple, press, rippleAndPress
    var label: String {
        switch self {
        case .none: return "None"
        case .ripple: return "Ripple"
        case .press: return "Press"
        case .rippleAndPress: return "Ripple + press"
        }
    }
    var ripple: Bool { self == .ripple || self == .rippleAndPress }
    var press: Bool { self == .press || self == .rippleAndPress }
}

enum CameraCorner: String, Codable, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight, custom
    var label: String {
        switch self {
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        case .custom: return "Custom"
        }
    }
}

enum CameraAspect: String, Codable, CaseIterable {
    case square, original, landscape, portrait
    var label: String {
        switch self {
        case .square: return "Square"
        case .original: return "Original"
        case .landscape: return "16:9"
        case .portrait: return "9:16"
        }
    }
}

/// Every visual/audio styling option for a project. This is the part that
/// presets save and restore, and that "use as default for new projects"
/// copies forward.
struct StyleConfig: Codable, Equatable {
    // MARK: Background
    var backgroundType: BackgroundType = .gradient
    var wallpaperPath: String?
    var gradient: GradientSpec = GradientSpec.presets[0]
    var backgroundColorHex: String = "1E1E1E"
    var backgroundImagePath: String?
    /// 0...1
    var backgroundBlur: Double = 0

    // MARK: Frame
    /// Padding around the recording, fraction of the canvas's shorter side.
    var padding: Double = 0.08
    /// Corner radius in pixels at a 1080p canvas (scaled for other sizes).
    var cornerRadius: Double = 18
    var insetPadding: Double = 0
    var insetColorHex: String = "000000"
    var insetAlpha: Double = 1
    var windowFrame: WindowFrameStyle = .none
    var aspectRatio: AspectRatioOption = .auto
    /// Normalized (0...1, top-left origin) crop of the recording.
    var cropX: Double = 0
    var cropY: Double = 0
    var cropW: Double = 1
    var cropH: Double = 1

    // MARK: Shadow
    var shadowIntensity: Double = 0.6
    /// Degrees, 90 = shadow falls straight down.
    var shadowAngle: Double = 90
    var shadowDistance: Double = 18
    var shadowBlur: Double = 40

    // MARK: Cursor
    var hideCursor = false
    var cursorStyle: CursorStyle = .recorded
    var cursorSize: Double = 1.5
    var smoothCursor = true
    var cursorSpring: SpringConfig = .cursorDefault
    /// How much the cursor tilts while moving horizontally (0 = never).
    var cursorTilt: Double = 0.5
    var hideIdleCursor = false
    var idleCursorDelay: Double = 2.0
    var loopCursorAtEnd = false
    var removeCursorShake = true
    var clickEffect: ClickEffect = .rippleAndPress
    var rippleColorHex: String = "FFFFFF"
    var clickSound = false
    var clickSoundVolume: Double = 0.4

    // MARK: Motion blur (0...1 each)
    var motionBlurCursor: Double = 0.6
    var motionBlurPan: Double = 0.6
    var motionBlurZoom: Double = 0.6

    // MARK: Zoom
    var zoomSpring: SpringConfig = .cameraDefault
    var defaultZoom: Double = 2.0
    var alwaysKeepZoomedIn = false
    /// Fraction of the visible viewport kept as a margin before an auto zoom
    /// pans to follow the cursor.
    var followEdgeMargin: Double = 0.25

    // MARK: Camera
    var hideCamera = false
    var mirrorCamera = true
    /// 0 = square corners, 1 = full circle/capsule.
    var cameraRoundness: Double = 1.0
    /// Fraction of the canvas's shorter side.
    var cameraSize: Double = 0.32
    var cameraCorner: CameraCorner = .bottomRight
    var cameraCustomX: Double = 0.85
    var cameraCustomY: Double = 0.8
    /// Camera size multiplier while the screen is fully zoomed in.
    var cameraScaleDuringZoom: Double = 0.7
    var cameraAspect: CameraAspect = .square
    var cameraRemoveBackground = false
    /// Keep the detected face centred in the camera shape.
    var cameraAutoFrame = true
    /// Extra zoom into the camera image (1 = fill the shape).
    var cameraZoom: Double = 1.0
    var cameraShadow: Double = 0.5
    var cameraBorderWidth: Double = 0

    // MARK: Overlays
    var showShortcuts = false
    var shortcutsSingleLetters = false
    var shortcutsSize: Double = 1
    var showCaptions = true
    var captionsSize: Double = 1

    // MARK: Audio
    var masterVolume: Double = 1
    var microphoneVolume: Double = 1
    var systemAudioVolume: Double = 1
    var muteMicrophone = false
    var muteSystemAudio = false
    var improveMicrophone = false
    var backgroundMusicPath: String?
    var backgroundMusicVolume: Double = 0.08
    var muteBackgroundMusic = false

    var cropRect: CGRect {
        get { CGRect(x: cropX, y: cropY, width: cropW, height: cropH) }
        set { cropX = newValue.minX; cropY = newValue.minY; cropW = newValue.width; cropH = newValue.height }
    }

    /// Lenient decoding: any key missing from older files falls back to its
    /// default, so adding new options never breaks existing projects/presets.
    static func decodeLenient(from data: Data) throws -> StyleConfig {
        try LenientJSON.decode(StyleConfig.self, from: data, defaults: StyleConfig())
    }
}

/// Merges stored JSON on top of an encoded default value before decoding,
/// so missing keys take the default instead of failing the whole decode.
enum LenientJSON {
    static func decode<T: Codable>(_ type: T.Type, from data: Data, defaults: T) throws -> T {
        let defaultData = try JSONEncoder().encode(defaults)
        guard var base = try JSONSerialization.jsonObject(with: defaultData) as? [String: Any],
              let stored = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return try JSONDecoder().decode(T.self, from: data)
        }
        merge(&base, with: stored)
        let merged = try JSONSerialization.data(withJSONObject: base)
        return try JSONDecoder().decode(T.self, from: merged)
    }

    static func decode<T: Codable>(_ type: T.Type, fromObject object: [String: Any], defaults: T) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try decode(type, from: data, defaults: defaults)
    }

    private static func merge(_ base: inout [String: Any], with stored: [String: Any]) {
        for (key, value) in stored {
            if let nested = value as? [String: Any], var existing = base[key] as? [String: Any] {
                merge(&existing, with: nested)
                base[key] = existing
            } else {
                base[key] = value
            }
        }
    }
}
