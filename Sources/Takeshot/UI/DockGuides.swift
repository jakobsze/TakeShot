import SwiftUI
import AppKit

/// Shown while the pill is being dragged: every screen dims a little and
/// outlines the spots the pill can dock to, in the shape it would take there
/// (upright on the left/right edges). The spot it would snap to if dropped
/// now is highlighted. Purely visual: it never takes mouse events.
@MainActor
enum DockGuides {
    private static var panels: [NSPanel] = []
    private static let model = DockGuidesModel()

    static var isShown: Bool { !panels.isEmpty }

    static func show(horizontalSize: NSSize, verticalSize: NSSize) {
        hide()
        model.horizontalSize = horizontalSize
        model.verticalSize = verticalSize
        for screen in NSScreen.screens {
            let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            // Just below the pill, above ordinary windows.
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.contentView = NSHostingView(rootView: DockGuidesView(
                model: model, screenFrame: screen.frame, displayID: PillDock.displayID(of: screen)))
            panel.setFrame(screen.frame, display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
            panels.append(panel)
        }
    }

    static func update(target: PillDock?) {
        if model.target != target { model.target = target }
    }

    static func hide() {
        panels.forEach { $0.orderOut(nil) }
        panels = []
        model.target = nil
    }
}

@MainActor
private final class DockGuidesModel: ObservableObject {
    @Published var target: PillDock?
    var horizontalSize = NSSize(width: 383, height: 44)
    var verticalSize = NSSize(width: 57, height: 361)
}

private struct DockGuidesView: View {
    @ObservedObject var model: DockGuidesModel
    let screenFrame: NSRect
    let displayID: UInt32?

    private struct Guide: Identifiable {
        let id: String
        let rect: CGRect
        let isTarget: Bool
    }

    /// The spots a drop can be pulled into on this display (the ⚙︎ menu's spots).
    private var guides: [Guide] {
        PillDock.menuChoices.map { PillDock(side: $0.side, spot: $0.spot, displayID: displayID) }.map { dock in
            let size = dock.isVertical ? model.verticalSize : model.horizontalSize
            let origin = dock.origin(for: size)
            // Screen coordinates (origin bottom-left) → this view (origin top-left).
            let rect = CGRect(x: origin.x - screenFrame.minX,
                              y: screenFrame.maxY - origin.y - size.height,
                              width: size.width, height: size.height)
            return Guide(id: "\(dock.side)-\(dock.spot)", rect: rect, isTarget: dock == model.target)
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(nsColor: .shadowColor).opacity(0.14)
            ForEach(guides) { guide in
                Capsule()
                    .fill(guide.isTarget ? AnyShapeStyle(Color.accentColor.opacity(0.3)) : AnyShapeStyle(.thinMaterial))
                    .overlay(Capsule().strokeBorder(guide.isTarget ? Color.accentColor : Color.primary.opacity(0.4),
                                                    lineWidth: guide.isTarget ? 2 : 1))
                    .opacity(guide.isTarget ? 1 : 0.85)
                    .frame(width: guide.rect.width, height: guide.rect.height)
                    .position(x: guide.rect.midX, y: guide.rect.midY)
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .animation(.easeOut(duration: 0.12), value: model.target)
    }
}
