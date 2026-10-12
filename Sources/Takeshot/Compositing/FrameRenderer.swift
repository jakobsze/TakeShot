import Foundation
import CoreImage
import AppKit
import AVFoundation

/// Immutable snapshot of everything needed to render any frame of a project:
/// the project itself plus precomputed motion tracks. Rebuilt (off the main
/// thread) whenever an edit changes the project.
final class RenderState: @unchecked Sendable {
    let project: Project
    let folder: URL
    let clipMap: ClipMap
    let cursor: CursorTrack
    let viewport: ViewportTrack
    let keys: KeystrokeTrack
    let cursorImages: [Int: CursorImage]
    let defaultArrow: CursorImage
    /// Pixel size of screen.mov.
    let recordingSize: CGSize
    /// Recording pixels per display point.
    let pixelsPerPoint: CGFloat
    let maxZoomScale: Double

    init(project: Project, folder: URL, events: [InputEvent], cursorLog: CursorShapeLog?, cursorImages: [Int: CursorImage], defaultArrow: CursorImage, recordingSize: CGSize) {
        self.project = project
        self.folder = folder
        self.clipMap = project.clipMap
        let cursor = CursorTrack(events: events, shapes: cursorLog, project: project)
        self.cursor = cursor
        self.viewport = ViewportTrack(project: project, cursor: cursor.isEmpty ? nil : cursor)
        self.keys = KeystrokeTrack(events: events, offset: project.screenOffset)
        self.cursorImages = cursorImages
        self.defaultArrow = defaultArrow
        self.recordingSize = recordingSize
        self.pixelsPerPoint = project.displayFrameWidth > 0 ? recordingSize.width / CGFloat(project.displayFrameWidth) : 2
        self.maxZoomScale = max(project.style.defaultZoom, project.zoomRanges.map(\.scale).max() ?? 2)
    }

    var croppedSourceSize: CGSize {
        let c = project.style.cropRect
        return CGSize(width: recordingSize.width * c.width, height: recordingSize.height * c.height)
    }

    func canvasSize(shortSide: CGFloat) -> CGSize {
        FrameGeometry.canvasSize(style: project.style, sourceSize: croppedSourceSize, shortSide: shortSide)
    }

    func geometry(canvas: CGSize, sideBySide: Bool = false) -> FrameGeometry {
        FrameGeometry(style: project.style, sourceSize: croppedSourceSize, canvas: canvas, sideBySide: sideBySide)
    }

    /// Fraction 0...1 that a layout of `kind` is in effect at source time t,
    /// with short eased transitions at range edges.
    func layoutAmount(_ kind: LayoutKind, at t: Double) -> Double {
        var amount = 0.0
        for r in project.layouts where r.kind == kind && t >= r.start - 0.001 && t <= r.end + 0.001 {
            let ramp = 0.35
            let a = min(1, max(0, (t - r.start) / ramp))
            let b = min(1, max(0, (r.end - t) / ramp))
            let v = min(a, b)
            amount = max(amount, v * v * (3 - 2 * v))
        }
        return amount
    }
}

/// Composites one output frame with Core Image (GPU): background, the
/// zoomed/panned recording in a rounded+shadowed card, cursor with click
/// effects and motion blur, camera, masks, keystrokes and captions.
final class FrameRenderer: @unchecked Sendable {
    static let shared = FrameRenderer()

    let context: CIContext
    private let lock = NSLock()
    private var backgroundCache: [String: CIImage] = [:]
    private var textCache: [String: CGImage] = [:]
    private var titleBarCache: [String: CGImage] = [:]
    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    private init() {
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false, .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        } else {
            context = CIContext(options: [.cacheIntermediates: false])
        }
    }

    // MARK: - Entry point

    func render(state: RenderState, outputTime: Double, screen: CIImage?, camera: CIImage?, cameraMask: CIImage?,
                cameraFocus: CGPoint? = nil, canvas: CGSize, highQuality: Bool) -> CIImage {
        let style = state.project.style
        let H = canvas.height
        let canvasRect = CGRect(origin: .zero, size: canvas)
        func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: H - r.maxY, width: r.width, height: r.height) }

        let t = state.clipMap.sourceTime(atOutput: outputTime)
        let clip = state.clipMap.clip(atOutput: outputTime)

        var output = background(style: style, canvas: canvas)

        let cameraOnly = state.project.hasCameraVideo && camera != nil ? state.layoutAmount(.cameraOnly, at: t) : 0
        let screenOnly = state.layoutAmount(.screenOnly, at: t)
        let side = state.project.hasCameraVideo && camera != nil ? state.layoutAmount(.sideBySide, at: t) : 0

        let normal = state.geometry(canvas: canvas)
        let geo: FrameGeometry
        var cardRect = normal.card
        var contentRect = normal.content
        if side > 0 {
            let sideGeo = state.geometry(canvas: canvas, sideBySide: true)
            cardRect = normal.card.lerp(to: sideGeo.card, CGFloat(side))
            contentRect = normal.content.lerp(to: sideGeo.content, CGFloat(side))
            geo = side > 0.5 ? sideGeo : normal
        } else {
            geo = normal
        }

        let (scale, focal) = state.viewport.state(at: t)
        let viewport = ViewportTrack.viewportRect(scale: scale, focal: focal)
        let crop = style.cropRect
        let screenAlpha = 1 - cameraOnly

        // Screen card
        if let screen, screenAlpha > 0.001 {
            let card = renderCard(state: state, screen: screen, t: t, viewport: viewport, scale: scale,
                                  cardRect: cardRect, contentRect: contentRect, geo: geo, canvas: canvas, highQuality: highQuality)
            let shadow = shadowLayer(rect: flip(cardRect), radius: geo.cornerRadius, style: style, unit: geo.unit)
            output = applyAlpha(shadow, screenAlpha).composited(over: output)
            output = applyAlpha(card, screenAlpha).composited(over: output)

            // Cursor + click effects, mapped through the same viewport.
            let hideCursor = style.hideCursor || (clip?.hideCursor ?? false)
            if !hideCursor, let pos = state.cursor.position(at: t) {
                let px = pointIn(contentRect: contentRect, recordingPoint: pos, crop: crop, viewport: viewport)
                let inside = contentRect.insetBy(dx: -4, dy: -4).contains(px)
                if inside {
                    let canvasPerSourcePx = contentRect.width / max(1, viewport.width * state.croppedSourceSize.width)
                    if style.clickEffect.ripple, let ripple = state.cursor.activeRipple(at: t) {
                        let rp = pointIn(contentRect: contentRect, recordingPoint: ripple.position, crop: crop, viewport: viewport)
                        output = rippleLayer(at: CGPoint(x: rp.x, y: H - rp.y), progress: ripple.progress,
                                             size: 46 * state.pixelsPerPoint * canvasPerSourcePx * CGFloat(style.cursorSize) / 1.5,
                                             colorHex: style.rippleColorHex, alpha: screenAlpha).composited(over: output)
                    }
                    if let cursor = cursorLayer(state: state, t: t, at: CGPoint(x: px.x, y: H - px.y),
                                                canvasPerSourcePx: canvasPerSourcePx, viewportWidth: viewport.width,
                                                contentWidth: contentRect.width) {
                        output = applyAlpha(cursor, screenAlpha * state.cursor.opacity(at: t)).composited(over: output)
                    }
                }
            }
        }

        // Camera
        if let camera, !style.hideCamera, state.project.hasCameraVideo {
            let cameraAlpha = 1 - screenOnly
            if cameraAlpha > 0.001 {
                output = cameraLayer(state: state, camera: camera, mask: cameraMask, focus: cameraFocus, t: t, scale: scale,
                                     geo: normal, cameraOnly: cameraOnly, side: side, canvas: canvas,
                                     alpha: cameraAlpha).composited(over: output)
            }
        }

        // Keystrokes
        var bottomOffset: CGFloat = 0.065 * H
        if style.showShortcuts, let label = state.keys.label(at: t, includeTyping: style.shortcutsSingleLetters) {
            let fontSize = 30 * normal.unit * CGFloat(style.shortcutsSize)
            if let pill = cachedText(label.text, fontSize: fontSize, maxWidth: canvas.width * 0.8, bg: CGColor(gray: 0.08, alpha: 0.78)) {
                let img = CIImage(cgImage: pill)
                let x = canvas.width / 2 - img.extent.width / 2
                output = applyAlpha(img.transformed(by: CGAffineTransform(translationX: x, y: bottomOffset)), label.opacity).composited(over: output)
                bottomOffset += img.extent.height + 12 * normal.unit
            }
        }

        // Captions
        if style.showCaptions, let caption = state.project.captions.first(where: { t >= $0.start && t <= $0.end }) {
            let fontSize = 34 * normal.unit * CGFloat(style.captionsSize)
            if let pill = cachedText(caption.text, fontSize: fontSize, maxWidth: canvas.width * 0.82, bg: CGColor(gray: 0, alpha: 0.66)) {
                let img = CIImage(cgImage: pill)
                let fade = min(1, (t - caption.start) / 0.12, (caption.end - t) / 0.12)
                let x = canvas.width / 2 - img.extent.width / 2
                output = applyAlpha(img.transformed(by: CGAffineTransform(translationX: x, y: bottomOffset)), max(0, fade)).composited(over: output)
            }
        }

        return output.cropped(to: canvasRect)
    }

    private func pointIn(contentRect: CGRect, recordingPoint p: CGPoint, crop: CGRect, viewport: CGRect) -> CGPoint {
        let cx = (p.x - crop.minX) / max(0.0001, crop.width)
        let cy = (p.y - crop.minY) / max(0.0001, crop.height)
        let vx = (cx - viewport.minX) / max(0.0001, viewport.width)
        let vy = (cy - viewport.minY) / max(0.0001, viewport.height)
        return CGPoint(x: contentRect.minX + vx * contentRect.width, y: contentRect.minY + vy * contentRect.height)
    }

    // MARK: - Screen card

    private func renderCard(state: RenderState, screen: CIImage, t: Double, viewport: CGRect, scale: Double,
                            cardRect: CGRect, contentRect: CGRect, geo: FrameGeometry, canvas: CGSize, highQuality: Bool) -> CIImage {
        let style = state.project.style
        let H = canvas.height
        func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: H - r.maxY, width: r.width, height: r.height) }

        let W = screen.extent.width, SH = screen.extent.height
        let crop = style.cropRect
        let cropPx = CGRect(x: crop.minX * W, y: (1 - crop.maxY) * SH, width: crop.width * W, height: crop.height * SH)
        let vpPx = CGRect(x: cropPx.minX + viewport.minX * cropPx.width,
                          y: cropPx.minY + (1 - viewport.maxY) * cropPx.height,
                          width: viewport.width * cropPx.width,
                          height: viewport.height * cropPx.height)
        let content = flip(contentRect)
        let sx = content.width / max(1, vpPx.width)
        let sy = content.height / max(1, vpPx.height)

        var img = screen.cropped(to: vpPx).transformed(by: CGAffineTransform(translationX: -vpPx.minX, y: -vpPx.minY))
        if highQuality && sx < 0.75, let lanczos = CIFilter(name: "CILanczosScaleTransform") {
            lanczos.setValue(img, forKey: kCIInputImageKey)
            lanczos.setValue(sy, forKey: kCIInputScaleKey)
            lanczos.setValue(sx / max(0.0001, sy), forKey: kCIInputAspectRatioKey)
            img = lanczos.outputImage ?? img.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        } else {
            img = img.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        }
        img = img.transformed(by: CGAffineTransform(translationX: content.minX, y: content.minY)).cropped(to: content)

        // Motion blur from camera movement.
        let (dScale, dFocal) = state.viewport.derivative(at: t)
        // A half-frame "shutter" at 60fps keeps the blur subtle, like a
        // real camera, rather than smearing whole transitions.
        let shutter = 0.5 / 60
        let panSpeedPx = hypot(dFocal.dx, dFocal.dy) * Double(content.width) * scale
        let panLength = panSpeedPx * shutter * style.motionBlurPan
        if panLength > 1.5 {
            img = img.clampedToExtent()
                .applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: min(panLength, 24), kCIInputAngleKey: atan2(dFocal.dy, -dFocal.dx)])
                .cropped(to: content)
        }
        let zoomLength = abs(dScale) / max(1, scale) * shutter * Double(content.width) * 0.25 * style.motionBlurZoom
        if zoomLength > 1.0 {
            let centerTL = pointIn(contentRect: contentRect, recordingPoint: CGPoint(x: crop.minX + (viewport.midX) * crop.width, y: crop.minY + viewport.midY * crop.height), crop: crop, viewport: viewport)
            img = img.clampedToExtent()
                .applyingFilter("CIZoomBlur", parameters: [kCIInputCenterKey: CIVector(x: centerTL.x, y: H - centerTL.y), "inputAmount": min(zoomLength, 8)])
                .cropped(to: content)
        }

        // Masks (blur / pixelate / spotlight).
        for mask in state.project.masks where t >= mask.start && t <= mask.end {
            let r = rectIn(contentRect: contentRect, recordingRect: mask.rect, crop: crop, viewport: viewport)
            let maskRect = flip(r).intersection(content)
            guard !maskRect.isNull, maskRect.width > 1, maskRect.height > 1 else { continue }
            switch mask.kind {
            case .blur:
                let sigma = (6 + 34 * mask.intensity) * Double(geo.unit) * scale
                let blurred = img.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: maskRect)
                img = blurred.composited(over: img)
            case .pixelate:
                let size = max(4, (8 + 44 * mask.intensity) * Double(geo.unit) * scale)
                let pix = img.clampedToExtent()
                    .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: size, kCIInputCenterKey: CIVector(x: maskRect.minX, y: maskRect.minY)])
                    .cropped(to: maskRect)
                img = pix.composited(over: img)
            case .highlight:
                let dim = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.25 + 0.6 * mask.intensity)).cropped(to: content)
                let dimmed = dim.composited(over: img)
                let hole = roundedRectMask(maskRect, radius: 10 * geo.unit)
                img = img.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: dimmed, kCIInputMaskImageKey: hole])
                    .cropped(to: content)
            }
        }

        let card = flip(cardRect)
        var layer = img
        if geo.border > 0 {
            let innerRadius = max(0, geo.cornerRadius - geo.border)
            layer = layer.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: roundedRectMask(content, radius: innerRadius),
            ])
            let borderColor: CIColor = style.windowFrame == .glass
                ? CIColor(red: 1, green: 1, blue: 1, alpha: 0.28)
                : CIColor.fromHex(style.insetColorHex, alpha: CGFloat(style.insetAlpha))
            let borderLayer: CIImage
            if style.windowFrame == .glass {
                borderLayer = CIImage(color: borderColor).cropped(to: card)
                    .composited(over: background(style: style, canvas: canvas).clampedToExtent().applyingGaussianBlur(sigma: 18 * Double(geo.unit)).cropped(to: card))
            } else {
                borderLayer = CIImage(color: borderColor).cropped(to: card)
            }
            layer = layer.composited(over: borderLayer)
        }
        if geo.titleBarHeight > 0 {
            let tbRect = CGRect(x: card.minX, y: card.maxY - geo.titleBarHeight, width: card.width, height: geo.titleBarHeight)
            if let bar = cachedTitleBar(width: Int(tbRect.width.rounded()), height: Int(tbRect.height.rounded()), dark: style.windowFrame == .macDark, unit: geo.unit) {
                let barImage = CIImage(cgImage: bar).transformed(by: CGAffineTransform(translationX: tbRect.minX, y: tbRect.minY))
                layer = barImage.composited(over: layer)
            }
            if geo.border == 0 {
                let fill = CIImage(color: style.windowFrame == .macDark ? CIColor(red: 0.1, green: 0.1, blue: 0.1) : CIColor(red: 1, green: 1, blue: 1)).cropped(to: card)
                layer = layer.composited(over: fill)
            }
        }
        return layer.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: roundedRectMask(card, radius: geo.cornerRadius),
        ]).cropped(to: card)
    }

    private func rectIn(contentRect: CGRect, recordingRect r: CGRect, crop: CGRect, viewport: CGRect) -> CGRect {
        let a = pointIn(contentRect: contentRect, recordingPoint: CGPoint(x: r.minX, y: r.minY), crop: crop, viewport: viewport)
        let b = pointIn(contentRect: contentRect, recordingPoint: CGPoint(x: r.maxX, y: r.maxY), crop: crop, viewport: viewport)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    // MARK: - Layers

    private func shadowLayer(rect: CGRect, radius: CGFloat, style: StyleConfig, unit: CGFloat) -> CIImage {
        guard style.shadowIntensity > 0.001 else { return CIImage.empty() }
        let angle = style.shadowAngle * .pi / 180
        let dist = CGFloat(style.shadowDistance) * unit
        let offset = CGAffineTransform(translationX: CGFloat(cos(angle)) * dist, y: -CGFloat(sin(angle)) * dist)
        let shape = roundedRectMask(rect, radius: radius, color: CIColor(red: 0, green: 0, blue: 0, alpha: CGFloat(min(1, style.shadowIntensity))))
        let sigma = max(0.5, style.shadowBlur * Double(unit) * 0.5)
        return shape.transformed(by: offset).applyingGaussianBlur(sigma: sigma)
    }

    private func roundedRectMask(_ rect: CGRect, radius: CGFloat, color: CIColor = CIColor(red: 1, green: 1, blue: 1)) -> CIImage {
        let r = max(0, min(radius, min(rect.width, rect.height) / 2))
        guard let filter = CIFilter(name: "CIRoundedRectangleGenerator") else {
            return CIImage(color: color).cropped(to: rect)
        }
        filter.setValue(CIVector(cgRect: rect), forKey: "inputExtent")
        filter.setValue(r, forKey: "inputRadius")
        filter.setValue(color, forKey: "inputColor")
        return filter.outputImage ?? CIImage(color: color).cropped(to: rect)
    }

    private func applyAlpha(_ image: CIImage, _ alpha: Double) -> CIImage {
        guard alpha < 0.999 else { return image }
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(alpha), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: CGFloat(alpha), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(alpha), w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(alpha)),
        ])
    }

    private func cursorLayer(state: RenderState, t: Double, at p: CGPoint, canvasPerSourcePx: CGFloat, viewportWidth: CGFloat, contentWidth: CGFloat) -> CIImage? {
        let style = state.project.style
        let cursor: CursorImage
        switch style.cursorStyle {
        case .touch:
            cursor = RenderAssets.touchCursor
        case .arrow:
            cursor = state.defaultArrow
        case .recorded:
            if let id = state.cursor.shapeID(at: t), let img = state.cursorImages[id] {
                cursor = img
            } else {
                cursor = state.defaultArrow
            }
        }
        let press = style.clickEffect.press ? state.cursor.pressAmount(at: t) : 0
        let pointsToCanvas = state.pixelsPerPoint * canvasPerSourcePx * CGFloat(style.cursorSize) * CGFloat(1 - 0.18 * press)
        let targetW = cursor.size.width * pointsToCanvas
        let imgW = CGFloat(cursor.image.width)
        guard imgW > 0, targetW > 0.5 else { return nil }
        let s = targetW / imgW
        let imgH = CGFloat(cursor.image.height)
        // Hotspot in image pixels, CI (bottom-left) space.
        let hx = cursor.hotSpot.x / cursor.size.width * imgW
        let hy = imgH - cursor.hotSpot.y / cursor.size.height * imgH
        var img = CIImage(cgImage: cursor.image)
        var transform = CGAffineTransform(translationX: -hx, y: -hy)
        transform = transform.concatenating(CGAffineTransform(scaleX: s, y: s))
        let tilt = style.cursorStyle == .touch ? 0 : state.cursor.tiltDegrees(at: t)
        if abs(tilt) > 0.05 {
            transform = transform.concatenating(CGAffineTransform(rotationAngle: CGFloat(tilt * .pi / 180)))
        }
        transform = transform.concatenating(CGAffineTransform(translationX: p.x, y: p.y))
        img = img.transformed(by: transform, highQualityDownsample: true)

        // Cursor motion blur.
        let v = state.cursor.velocity(at: t)
        let cropW = state.project.style.cropRect.width
        let canvasPerNorm = contentWidth / max(0.0001, viewportWidth * cropW)
        let speed = hypot(v.dx, v.dy) * Double(canvasPerNorm)
        let length = speed * (0.5 / 60) * style.motionBlurCursor
        if length > 2 {
            img = img.applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: min(length, 30), kCIInputAngleKey: atan2(-v.dy, v.dx)])
        }
        return img
    }

    private func rippleLayer(at p: CGPoint, progress: Double, size: CGFloat, colorHex: String, alpha: Double) -> CIImage {
        let eased = 1 - pow(1 - progress, 3)
        let diameter = size * CGFloat(0.35 + 0.9 * eased)
        let ring = CIImage(cgImage: RenderAssets.rippleRing)
        let s = diameter / ring.extent.width
        let (r, g, b) = hexComponents(colorHex)
        let a = CGFloat((1 - progress) * 0.85 * alpha)
        return ring
            .transformed(by: CGAffineTransform(scaleX: s, y: s).concatenating(CGAffineTransform(translationX: p.x - diameter / 2, y: p.y - diameter / 2)))
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: r * a, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: g * a, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: b * a, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: a),
            ])
    }

    private func cameraLayer(state: RenderState, camera: CIImage, mask: CIImage?, focus: CGPoint?, t: Double, scale: Double,
                             geo: FrameGeometry, cameraOnly: Double, side: Double, canvas: CGSize, alpha: Double) -> CIImage {
        let style = state.project.style
        let H = canvas.height
        let short = min(canvas.width, canvas.height)
        func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: H - r.maxY, width: r.width, height: r.height) }

        var cam = camera
        if let mask {
            let scaled = mask.transformed(by: CGAffineTransform(scaleX: cam.extent.width / mask.extent.width, y: cam.extent.height / mask.extent.height))
                .transformed(by: CGAffineTransform(translationX: cam.extent.minX, y: cam.extent.minY))
            cam = cam.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: scaled])
                .cropped(to: camera.extent)
        }
        if style.mirrorCamera {
            cam = cam.transformed(by: CGAffineTransform(scaleX: -1, y: 1).concatenating(CGAffineTransform(translationX: camera.extent.maxX + camera.extent.minX, y: 0)))
        }

        // Bubble rect (top-left space).
        let aspect: CGFloat
        switch style.cameraAspect {
        case .square: aspect = 1
        case .original: aspect = camera.extent.height > 0 ? camera.extent.width / camera.extent.height : 1
        case .landscape: aspect = 16.0 / 9
        case .portrait: aspect = 9.0 / 16
        }
        let zoomProgress = min(1, max(0, (scale - 1) / max(0.01, state.maxZoomScale - 1)))
        let sizeFactor = 1 + (style.cameraScaleDuringZoom - 1) * zoomProgress
        let base = CGFloat(style.cameraSize * sizeFactor) * short
        let bw = base * sqrt(aspect), bh = base / sqrt(aspect)
        let margin = 0.035 * short
        var center: CGPoint
        switch style.cameraCorner {
        case .topLeft: center = CGPoint(x: margin + bw / 2, y: margin + bh / 2)
        case .topRight: center = CGPoint(x: canvas.width - margin - bw / 2, y: margin + bh / 2)
        case .bottomLeft: center = CGPoint(x: margin + bw / 2, y: H - margin - bh / 2)
        case .bottomRight: center = CGPoint(x: canvas.width - margin - bw / 2, y: H - margin - bh / 2)
        case .custom: center = CGPoint(x: CGFloat(style.cameraCustomX) * canvas.width, y: CGFloat(style.cameraCustomY) * H)
        }
        center.x = min(max(center.x, bw / 2), canvas.width - bw / 2)
        center.y = min(max(center.y, bh / 2), H - bh / 2)
        var rect = CGRect(x: center.x - bw / 2, y: center.y - bh / 2, width: bw, height: bh)
        var radius = CGFloat(style.cameraRoundness) * min(bw, bh) / 2

        if side > 0 {
            let sideRect = geo.sideCameraRect(style: style)
            rect = rect.lerp(to: sideRect, CGFloat(side))
            radius += (geo.cornerRadius - radius) * CGFloat(side)
        }
        if cameraOnly > 0 {
            rect = rect.lerp(to: geo.available, CGFloat(cameraOnly))
            radius += (geo.cornerRadius - radius) * CGFloat(cameraOnly)
        }
        let target = flip(rect)

        // Aspect-fill the camera into the rect, optionally zoomed in and
        // framed around the detected face (slightly above centre).
        let fill = max(target.width / cam.extent.width, target.height / cam.extent.height) * CGFloat(max(1, style.cameraZoom))
        let fw = cam.extent.width * fill, fh = cam.extent.height * fill
        var originX = target.midX - fw / 2
        var originY = target.midY - fh / 2
        if let focus {
            let fx = style.mirrorCamera ? 1 - focus.x : focus.x
            originX = target.midX - fx * fw
            originY = target.midY + target.height * 0.08 - focus.y * fh
            originX = min(target.minX, max(target.maxX - fw, originX))
            originY = min(target.minY, max(target.maxY - fh, originY))
        }
        var placed = cam.transformed(by: CGAffineTransform(translationX: -cam.extent.minX, y: -cam.extent.minY)
            .concatenating(CGAffineTransform(scaleX: fill, y: fill))
            .concatenating(CGAffineTransform(translationX: originX, y: originY)))
            .cropped(to: target)

        var result = CIImage.empty()
        let removed = mask != nil
        // The shape (roundness) applies in both modes; with the background
        // removed it trims the cut-out instead of framing a bubble.
        placed = placed.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: roundedRectMask(target, radius: radius),
        ])
        if style.cameraShadow > 0.001 {
            let shadow: CIImage
            if removed {
                // Shadow follows the person's silhouette.
                shadow = placed.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(style.cameraShadow)),
                ])
            } else {
                shadow = roundedRectMask(target, radius: radius, color: CIColor(red: 0, green: 0, blue: 0, alpha: CGFloat(style.cameraShadow)))
            }
            result = shadow.transformed(by: CGAffineTransform(translationX: 0, y: -8 * geo.unit))
                .applyingGaussianBlur(sigma: 18 * Double(geo.unit))
        }
        if !removed && style.cameraBorderWidth > 0 {
            let bwPx = CGFloat(style.cameraBorderWidth) * geo.unit
            let outer = target.insetBy(dx: -bwPx, dy: -bwPx)
            result = roundedRectMask(outer, radius: radius + bwPx, color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.95)).composited(over: result)
        }
        result = placed.composited(over: result)
        return applyAlpha(result, alpha)
    }

    // MARK: - Background

    func background(style: StyleConfig, canvas: CGSize) -> CIImage {
        let key = "\(style.backgroundType.rawValue)|\(style.wallpaperPath ?? "")|\(style.gradient.startHex)|\(style.gradient.endHex)|\(style.gradient.angle)|\(style.backgroundColorHex)|\(style.backgroundImagePath ?? "")|\(style.backgroundBlur)|\(Int(canvas.width))x\(Int(canvas.height))"
        lock.lock()
        if let cached = backgroundCache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let rect = CGRect(origin: .zero, size: canvas)
        var image: CIImage
        switch style.backgroundType {
        case .color:
            image = CIImage(color: CIColor.fromHex(style.backgroundColorHex)).cropped(to: rect)
        case .gradient:
            image = gradientImage(style.gradient, canvas: canvas)
        case .wallpaper, .image:
            let path = style.backgroundType == .wallpaper ? (style.wallpaperPath ?? Wallpaper.all.first?.path) : style.backgroundImagePath
            if let path, let loaded = CIImage(contentsOf: URL(fileURLWithPath: path), options: [.applyOrientationProperty: true]) {
                let fill = max(canvas.width / loaded.extent.width, canvas.height / loaded.extent.height)
                let w = loaded.extent.width * fill, h = loaded.extent.height * fill
                image = loaded.transformed(by: CGAffineTransform(translationX: -loaded.extent.minX, y: -loaded.extent.minY)
                    .concatenating(CGAffineTransform(scaleX: fill, y: fill))
                    .concatenating(CGAffineTransform(translationX: (canvas.width - w) / 2, y: (canvas.height - h) / 2)), highQualityDownsample: true)
                    .cropped(to: rect)
            } else {
                image = gradientImage(style.gradient, canvas: canvas)
            }
        }
        if style.backgroundBlur > 0.001 {
            let sigma = style.backgroundBlur * 40 * Double(min(canvas.width, canvas.height)) / 1080
            image = image.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: rect)
        }
        // Flatten once so per-frame rendering doesn't redo decode/scale/blur.
        if let cg = context.createCGImage(image, from: rect, format: .RGBA8, colorSpace: srgb) {
            image = CIImage(cgImage: cg)
        }
        lock.lock()
        if backgroundCache.count > 12 { backgroundCache.removeAll() }
        backgroundCache[key] = image
        lock.unlock()
        return image
    }

    private func gradientImage(_ g: GradientSpec, canvas: CGSize) -> CIImage {
        let a = g.angle * .pi / 180
        let dx = CGFloat(cos(a)), dy = CGFloat(sin(a))
        let length = abs(canvas.width * dx) + abs(canvas.height * dy)
        let c = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
        // Top-left space → CI space (flip y).
        let p0 = CGPoint(x: c.x - dx * length / 2, y: canvas.height - (c.y - dy * length / 2))
        let p1 = CGPoint(x: c.x + dx * length / 2, y: canvas.height - (c.y + dy * length / 2))
        let filter = CIFilter(name: "CILinearGradient")!
        filter.setValue(CIVector(cgPoint: p0), forKey: "inputPoint0")
        filter.setValue(CIVector(cgPoint: p1), forKey: "inputPoint1")
        filter.setValue(CIColor.fromHex(g.startHex), forKey: "inputColor0")
        filter.setValue(CIColor.fromHex(g.endHex), forKey: "inputColor1")
        return (filter.outputImage ?? CIImage(color: .black)).cropped(to: CGRect(origin: .zero, size: canvas))
    }

    // MARK: - Caches

    private func cachedText(_ text: String, fontSize: CGFloat, maxWidth: CGFloat, bg: CGColor) -> CGImage? {
        let key = "\(text)|\(Int(fontSize * 10))|\(Int(maxWidth))|\(bg.alpha)"
        lock.lock()
        if let cached = textCache[key] { lock.unlock(); return cached }
        lock.unlock()
        let image = RenderAssets.textPill(text, fontSize: fontSize, maxWidth: maxWidth, background: bg)
        lock.lock()
        if textCache.count > 300 { textCache.removeAll() }
        textCache[key] = image
        lock.unlock()
        return image
    }

    private func cachedTitleBar(width: Int, height: Int, dark: Bool, unit: CGFloat) -> CGImage? {
        let key = "\(width)x\(height)|\(dark)"
        lock.lock()
        if let cached = titleBarCache[key] { lock.unlock(); return cached }
        lock.unlock()
        let image = RenderAssets.titleBar(width: width, height: height, dark: dark, unit: unit)
        lock.lock()
        if titleBarCache.count > 40 { titleBarCache.removeAll() }
        titleBarCache[key] = image
        lock.unlock()
        return image
    }
}
