import SwiftUI
import AppKit
import AVFoundation

struct LabeledSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: String = "%.2f"
    var suffix: String = ""

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                Slider(value: $value, in: range)
                    .labelsHidden()
                    .accessibilityLabel(label)
                Text(String(format: format, value) + suffix)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }
            .frame(minWidth: 150)
        }
    }
}

extension Color {
    init(hex: String) {
        self.init(cgColor: CGColor.fromHex(hex))
    }

    func toHex() -> String {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return "1E1E1E" }
        return String(format: "%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}

/// A Binding into a StyleConfig field on the editor model, with undo
/// coalescing keyed by the field's key path.
@MainActor
func styleBinding<T>(_ model: EditorModel, _ keyPath: WritableKeyPath<StyleConfig, T>) -> Binding<T> {
    Binding(
        get: { model.project.style[keyPath: keyPath] },
        set: { value in model.updateStyle("\(keyPath)") { $0[keyPath: keyPath] = value } }
    )
}

@MainActor
func styleColorBinding(_ model: EditorModel, _ keyPath: WritableKeyPath<StyleConfig, String>) -> Binding<Color> {
    Binding(
        get: { Color(hex: model.project.style[keyPath: keyPath]) },
        set: { value in model.updateStyle("\(keyPath)") { $0[keyPath: keyPath] = value.toHex() } }
    )
}

func formatTime(_ t: Double, tenths: Bool = true) -> String {
    let total = max(0, t)
    let m = Int(total) / 60
    let s = Int(total) % 60
    if tenths {
        return String(format: "%d:%02d.%d", m, s, Int((total - floor(total)) * 10))
    }
    return String(format: "%d:%02d", m, s)
}

/// Grabs single frames from a recording for inspector thumbnails (crop,
/// mask and zoom-point pickers).
actor FrameGrabber {
    private let generator: AVAssetImageGenerator

    init(url: URL) {
        let asset = AVURLAsset(url: url)
        generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
    }

    func frame(at seconds: Double) async -> CGImage? {
        try? await generator.image(at: CMTime(seconds: max(0, seconds), preferredTimescale: 600)).image
    }
}

/// Shows a recording frame with an editable normalized rect (crop, masks).
struct RectEditorView: View {
    let image: CGImage?
    let aspect: CGFloat
    @Binding var rect: CGRect
    var tint: Color = .accentColor
    var dimOutside = true

    @State private var dragStart: CGRect?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let r = CGRect(x: rect.minX * size.width, y: rect.minY * size.height, width: rect.width * size.width, height: rect.height * size.height)
            ZStack(alignment: .topLeading) {
                if let image {
                    Image(decorative: image, scale: 1).resizable()
                } else {
                    Rectangle().fill(Color.black.opacity(0.6))
                }
                if dimOutside {
                    Path { p in
                        p.addRect(CGRect(origin: .zero, size: size))
                        p.addRect(r)
                    }
                    .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
                }
                Rectangle()
                    .strokeBorder(tint, lineWidth: 2)
                    .background(tint.opacity(dimOutside ? 0 : 0.25))
                    .frame(width: max(4, r.width), height: max(4, r.height))
                    .offset(x: r.minX, y: r.minY)
                    .gesture(DragGesture(minimumDistance: 1).onChanged { v in
                        let start = dragStart ?? rect
                        dragStart = start
                        var n = start
                        n.origin.x = min(max(0, start.minX + v.translation.width / size.width), 1 - start.width)
                        n.origin.y = min(max(0, start.minY + v.translation.height / size.height), 1 - start.height)
                        rect = n
                    }.onEnded { _ in dragStart = nil })
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().stroke(tint, lineWidth: 2))
                    .frame(width: 14, height: 14)
                    .offset(x: r.maxX - 7, y: r.maxY - 7)
                    .gesture(DragGesture(minimumDistance: 1).onChanged { v in
                        let start = dragStart ?? rect
                        dragStart = start
                        var n = start
                        n.size.width = min(max(0.03, start.width + v.translation.width / size.width), 1 - start.minX)
                        n.size.height = min(max(0.03, start.height + v.translation.height / size.height), 1 - start.minY)
                        rect = n
                    }.onEnded { _ in dragStart = nil })
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Shows a recording frame with a draggable focus point (manual zoom target).
struct PointPickerView: View {
    let image: CGImage?
    let aspect: CGFloat
    @Binding var point: CGPoint
    var zoomScale: Double

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let w = size.width / CGFloat(max(1, zoomScale)), h = size.height / CGFloat(max(1, zoomScale))
            let cx = min(max(point.x * size.width, w / 2), size.width - w / 2)
            let cy = min(max(point.y * size.height, h / 2), size.height - h / 2)
            ZStack(alignment: .topLeading) {
                if let image {
                    Image(decorative: image, scale: 1).resizable()
                } else {
                    Rectangle().fill(Color.black.opacity(0.6))
                }
                Rectangle()
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .background(Color.accentColor.opacity(0.15))
                    .frame(width: w, height: h)
                    .offset(x: cx - w / 2, y: cy - h / 2)
                Circle().fill(Color.accentColor).frame(width: 10, height: 10)
                    .offset(x: point.x * size.width - 5, y: point.y * size.height - 5)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                point = CGPoint(x: min(max(0, v.location.x / size.width), 1), y: min(max(0, v.location.y / size.height), 1))
            })
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Grid of wallpaper thumbnails, loaded lazily off the main thread.
struct WallpaperThumb: View {
    let wallpaper: Wallpaper
    let selected: Bool
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(Color.gray.opacity(0.3))
            }
        }
        .frame(height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2.5))
        .help(wallpaper.name)
        .task(id: wallpaper.thumbnailPath) {
            let path = wallpaper.thumbnailPath
            image = await Task.detached(priority: .utility) { () -> NSImage? in
                guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 220,
                      ] as CFDictionary) else { return nil }
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }.value
        }
    }
}

extension View {
    /// Section header styling for inspector groups.
    func inspectorHeader() -> some View {
        self.font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
    }
}
