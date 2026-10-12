import Foundation
import AppKit
import CoreImage
import CoreText

extension CGColor {
    static func fromHex(_ hex: String, alpha: CGFloat = 1) -> CGColor {
        let (r, g, b) = hexComponents(hex)
        return CGColor(srgbRed: r, green: g, blue: b, alpha: alpha)
    }
}

extension CIColor {
    static func fromHex(_ hex: String, alpha: CGFloat = 1) -> CIColor {
        let (r, g, b) = hexComponents(hex)
        return CIColor(red: r, green: g, blue: b, alpha: alpha, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) ?? CIColor(red: r, green: g, blue: b, alpha: alpha)
    }
}

func hexComponents(_ hex: String) -> (CGFloat, CGFloat, CGFloat) {
    let s = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
    var value: UInt64 = 0
    Scanner(string: s).scanHexInt64(&value)
    return (CGFloat((value & 0xFF0000) >> 16) / 255, CGFloat((value & 0x00FF00) >> 8) / 255, CGFloat(value & 0x0000FF) / 255)
}

/// macOS's own desktop pictures, read from the system at runtime (nothing
/// is bundled), offered as background wallpapers.
struct Wallpaper: Identifiable, Hashable {
    let path: String
    let thumbnailPath: String
    var id: String { path }
    var name: String { URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent }

    static let all: [Wallpaper] = {
        var result: [Wallpaper] = []
        let fm = FileManager.default
        for dir in ["/System/Library/Desktop Pictures", "/Library/Desktop Pictures"] {
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for file in files.sorted() {
                let ext = (file as NSString).pathExtension.lowercased()
                guard ["heic", "jpg", "jpeg", "png"].contains(ext) else { continue }
                let path = "\(dir)/\(file)"
                let thumb = "\(dir)/.thumbnails/\(file)"
                result.append(Wallpaper(path: path, thumbnailPath: fm.fileExists(atPath: thumb) ? thumb : path))
            }
            // Dynamic/aerial wallpapers ship only a still thumbnail; those still
            // make perfectly good (if lower-res) backgrounds.
            let thumbDir = "\(dir)/.thumbnails"
            if let thumbs = try? fm.contentsOfDirectory(atPath: thumbDir) {
                for file in thumbs.sorted() where !files.contains(file) {
                    let ext = (file as NSString).pathExtension.lowercased()
                    guard ["heic", "jpg", "jpeg", "png"].contains(ext) else { continue }
                    let path = "\(thumbDir)/\(file)"
                    result.append(Wallpaper(path: path, thumbnailPath: path))
                }
            }
        }
        return result
    }()
}

/// A cursor bitmap with its hotspot, sized in points.
struct CursorImage {
    let image: CGImage
    let hotSpot: CGPoint
    let size: CGSize
}

/// Images that are drawn procedurally (or pulled from AppKit) once and reused.
enum RenderAssets {
    /// AppKit cursors must be read on the main thread; call once at launch.
    @MainActor static func prepare() {
        _ = defaultArrow
        _ = touchCursor
        _ = rippleRing
    }

    @MainActor static let defaultArrow: CursorImage = {
        let cursor = NSCursor.arrow
        return cursorImage(from: cursor.image, hotSpot: cursor.hotSpot) ?? CursorImage(image: touchCursor.image, hotSpot: CGPoint(x: 0, y: 0), size: CGSize(width: 20, height: 20))
    }()

    static func cursorImage(from image: NSImage, hotSpot: NSPoint) -> CursorImage? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        var rect = NSRect(x: 0, y: 0, width: size.width * 4, height: size.height * 4)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        return CursorImage(image: cg, hotSpot: hotSpot, size: size)
    }

    static let touchCursor: CursorImage = {
        let px = 128
        let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let rect = CGRect(x: 8, y: 8, width: px - 16, height: px - 16)
        ctx.setFillColor(CGColor(gray: 0.15, alpha: 0.55))
        ctx.fillEllipse(in: rect)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
        ctx.setLineWidth(7)
        ctx.strokeEllipse(in: rect.insetBy(dx: 3.5, dy: 3.5))
        return CursorImage(image: ctx.makeImage()!, hotSpot: CGPoint(x: 12, y: 12), size: CGSize(width: 24, height: 24))
    }()

    static let rippleRing: CGImage = {
        let px = 256
        let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setLineWidth(12)
        ctx.strokeEllipse(in: CGRect(x: 8, y: 8, width: px - 16, height: px - 16))
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.25))
        ctx.fillEllipse(in: CGRect(x: 14, y: 14, width: px - 28, height: px - 28))
        return ctx.makeImage()!
    }()

    /// Loads cursor shapes captured during a recording.
    static func loadRecordedCursors(folder: URL) -> (CursorShapeLog?, [Int: CursorImage]) {
        let url = folder.appendingPathComponent(CursorShapeLog.fileName)
        guard let data = try? Data(contentsOf: url),
              let log = try? JSONDecoder().decode(CursorShapeLog.self, from: data) else { return (nil, [:]) }
        var images: [Int: CursorImage] = [:]
        for shape in log.shapes {
            let file = folder.appendingPathComponent(CursorShapeLog.folderName).appendingPathComponent(shape.fileName)
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            images[shape.id] = CursorImage(image: image, hotSpot: CGPoint(x: shape.hotX, y: shape.hotY), size: CGSize(width: shape.width, height: shape.height))
        }
        return (log, images)
    }

    /// Generates (once) a short synthetic mouse-click sound used for the
    /// "click sounds" option.
    static let clickSoundURL: URL = {
        let url = PresetStore.supportFolder.appendingPathComponent("click.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let sampleRate = 44100
        let count = Int(Double(sampleRate) * 0.06)
        var samples = [Int16](repeating: 0, count: count)
        var seed: UInt32 = 12345
        for i in 0..<count {
            let t = Double(i) / Double(sampleRate)
            seed = seed &* 1664525 &+ 1013904223
            let noise = Double(Int32(bitPattern: seed)) / Double(Int32.max)
            let env = exp(-t * 140)
            let tone = sin(2 * .pi * 2200 * t) * exp(-t * 90)
            let v = (noise * 0.55 + tone * 0.6) * env
            samples[i] = Int16(max(-1, min(1, v)) * 30000)
        }
        var data = Data()
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        let byteCount = count * 2
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + byteCount).littleEndian)
        data.append(contentsOf: Array("WAVE".utf8)); data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16).littleEndian); append(UInt16(1).littleEndian); append(UInt16(1).littleEndian)
        append(UInt32(sampleRate).littleEndian); append(UInt32(sampleRate * 2).littleEndian)
        append(UInt16(2).littleEndian); append(UInt16(16).littleEndian)
        data.append(contentsOf: Array("data".utf8)); append(UInt32(byteCount).littleEndian)
        samples.forEach { append($0.littleEndian) }
        try? data.write(to: url)
        return url
    }()

    // MARK: - Text

    /// Renders text into a rounded "pill" image (keystrokes, captions).
    static func textPill(_ text: String, fontSize: CGFloat, maxWidth: CGFloat, background: CGColor, weight: NSFont.Weight = .semibold) -> CGImage? {
        guard !text.isEmpty, fontSize > 1 else { return nil }
        let font = NSFont.systemFont(ofSize: fontSize, weight: weight)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let padX = fontSize * 0.7
        let padY = fontSize * 0.42
        let constraint = CGSize(width: max(10, maxWidth - padX * 2), height: .greatestFiniteMagnitude)
        let textSize = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil, constraint, nil)
        let width = Int(ceil(textSize.width + padX * 2))
        let height = Int(ceil(textSize.height + padY * 2))
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let radius = min(CGFloat(height) / 2, fontSize * 0.6)
        ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height), cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setFillColor(background)
        ctx.fillPath()
        let path = CGPath(rect: CGRect(x: padX, y: padY, width: ceil(textSize.width) + 1, height: ceil(textSize.height)), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, ctx)
        return ctx.makeImage()
    }

    /// macOS-style window title bar (traffic lights) for the window frame option.
    static func titleBar(width: Int, height: Int, dark: Bool, unit: CGFloat) -> CGImage? {
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(dark ? CGColor(srgbRed: 0.17, green: 0.17, blue: 0.18, alpha: 1) : CGColor(srgbRed: 0.95, green: 0.95, blue: 0.95, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(dark ? CGColor(gray: 0, alpha: 0.6) : CGColor(gray: 0.78, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: max(1, unit)))
        let r = 6.5 * unit
        let colors = [CGColor(srgbRed: 1, green: 0.373, blue: 0.341, alpha: 1),
                      CGColor(srgbRed: 0.996, green: 0.737, blue: 0.18, alpha: 1),
                      CGColor(srgbRed: 0.157, green: 0.784, blue: 0.251, alpha: 1)]
        for (i, color) in colors.enumerated() {
            let cx = 20 * unit + CGFloat(i) * 21 * unit
            ctx.setFillColor(color)
            ctx.fillEllipse(in: CGRect(x: cx - r, y: CGFloat(height) / 2 - r, width: r * 2, height: r * 2))
        }
        return ctx.makeImage()
    }
}
