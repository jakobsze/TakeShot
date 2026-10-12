import Foundation
import CoreGraphics

/// Where everything sits on the output canvas, in top-left-origin pixel
/// space. Shared by the renderer and by editor overlays (mask/zoom-target
/// handles on the preview) so they always agree.
struct FrameGeometry {
    let canvas: CGSize
    /// Scale factor relative to a 1080p canvas (for px-based style values).
    let unit: CGFloat
    /// The padded area the card is fitted into.
    let available: CGRect
    /// The rounded "window" card including frame chrome/border.
    let card: CGRect
    /// Where the (zoomed) recording pixels are drawn.
    let content: CGRect
    let titleBarHeight: CGFloat
    let border: CGFloat
    let cornerRadius: CGFloat

    init(style: StyleConfig, sourceSize: CGSize, canvas: CGSize, sideBySide: Bool = false) {
        self.canvas = canvas
        let short = min(canvas.width, canvas.height)
        unit = short / 1080
        let pad = CGFloat(style.padding) * short
        var avail = CGRect(x: pad, y: pad, width: max(10, canvas.width - pad * 2), height: max(10, canvas.height - pad * 2))
        if sideBySide {
            let gap = max(pad * 0.5, 24 * unit)
            if canvas.width >= canvas.height {
                avail.size.width = (avail.width - gap) * 0.64
            } else {
                avail.size.height = (avail.height - gap) * 0.64
            }
        }
        available = avail

        switch style.windowFrame {
        case .macLight, .macDark: titleBarHeight = 30 * unit
        default: titleBarHeight = 0
        }
        border = style.windowFrame == .glass ? 12 * unit : CGFloat(style.insetPadding) * unit
        cornerRadius = CGFloat(style.cornerRadius) * unit

        let ar = sourceSize.height > 0 ? sourceSize.width / sourceSize.height : 16.0 / 9
        let w = max(2, min(avail.width - 2 * border, (avail.height - 2 * border - titleBarHeight) * ar))
        let h = w / ar
        let cardSize = CGSize(width: w + 2 * border, height: h + 2 * border + titleBarHeight)
        card = CGRect(x: avail.midX - cardSize.width / 2, y: avail.midY - cardSize.height / 2, width: cardSize.width, height: cardSize.height)
        content = CGRect(x: card.minX + border, y: card.minY + border + titleBarHeight, width: w, height: h)
    }

    /// The canvas the camera occupies in side-by-side layout.
    func sideCameraRect(style: StyleConfig) -> CGRect {
        let short = min(canvas.width, canvas.height)
        let pad = CGFloat(style.padding) * short
        let gap = max(pad * 0.5, 24 * unit)
        if canvas.width >= canvas.height {
            let x = available.maxX + gap
            let w = canvas.width - pad - x
            let h = min(available.height, w * 1.25)
            return CGRect(x: x, y: canvas.height / 2 - h / 2, width: w, height: h)
        } else {
            let y = available.maxY + gap
            let h = canvas.height - pad - y
            let w = min(available.width, h * 1.25)
            return CGRect(x: canvas.width / 2 - w / 2, y: y, width: w, height: h)
        }
    }

    /// Output canvas size for a given export short side.
    static func canvasSize(style: StyleConfig, sourceSize: CGSize, shortSide: CGFloat) -> CGSize {
        let ratio = style.aspectRatio.ratio ?? (sourceSize.height > 0 ? Double(sourceSize.width / sourceSize.height) : 16.0 / 9)
        var w: CGFloat
        var h: CGFloat
        if ratio >= 1 {
            h = shortSide
            w = shortSide * CGFloat(ratio)
        } else {
            w = shortSide
            h = shortSide / CGFloat(ratio)
        }
        // Encoders want even dimensions; cap the long edge at 8K-ish.
        let cap: CGFloat = 7680
        if max(w, h) > cap {
            let s = cap / max(w, h)
            w *= s
            h *= s
        }
        return CGSize(width: CGFloat(Int(w / 2) * 2), height: CGFloat(Int(h / 2) * 2))
    }

    /// Maps a normalized recording-space point (top-left origin) to canvas
    /// pixels (top-left origin) for a given viewport (normalized within the crop).
    func canvasPoint(forRecordingPoint p: CGPoint, crop: CGRect, viewport: CGRect) -> CGPoint {
        let cx = (p.x - crop.minX) / max(0.0001, crop.width)
        let cy = (p.y - crop.minY) / max(0.0001, crop.height)
        let vx = (cx - viewport.minX) / max(0.0001, viewport.width)
        let vy = (cy - viewport.minY) / max(0.0001, viewport.height)
        return CGPoint(x: content.minX + vx * content.width, y: content.minY + vy * content.height)
    }

    func recordingPoint(forCanvasPoint p: CGPoint, crop: CGRect, viewport: CGRect) -> CGPoint {
        let vx = (p.x - content.minX) / max(0.0001, content.width)
        let vy = (p.y - content.minY) / max(0.0001, content.height)
        let cx = viewport.minX + vx * viewport.width
        let cy = viewport.minY + vy * viewport.height
        return CGPoint(x: crop.minX + cx * crop.width, y: crop.minY + cy * crop.height)
    }

    func canvasRect(forRecordingRect r: CGRect, crop: CGRect, viewport: CGRect) -> CGRect {
        let a = canvasPoint(forRecordingPoint: CGPoint(x: r.minX, y: r.minY), crop: crop, viewport: viewport)
        let b = canvasPoint(forRecordingPoint: CGPoint(x: r.maxX, y: r.maxY), crop: crop, viewport: viewport)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}

extension CGRect {
    func lerp(to other: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: minX + (other.minX - minX) * t, y: minY + (other.minY - minY) * t,
               width: width + (other.width - width) * t, height: height + (other.height - height) * t)
    }
}
