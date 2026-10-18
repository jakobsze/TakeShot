import AppKit

/// Where the recording pill is docked: an edge of a display plus a spot along
/// that edge. Docked to the left or right edge, the pill (and the recording
/// widget that replaces it while recording) is laid out vertically.
/// Positions are computed inside the screen's `visibleFrame`, so the menu bar,
/// the camera housing and the Dock (on any side) are never covered.
struct PillDock: Codable, Equatable {
    enum Side: String, Codable { case top, bottom, left, right }
    /// Along the edge: `start` is the left end of the top/bottom edges and the
    /// top end of the left/right edges.
    enum Spot: String, Codable { case start, center, end }

    var side: Side
    var spot: Spot
    /// `NSScreenNumber` of the display; nil or unknown means the main display.
    var displayID: UInt32?

    var isVertical: Bool { side == .left || side == .right }

    /// Gap between the docked pill and the edge of the usable screen area.
    static let margin: CGFloat = 12
    /// A pill dropped with the cursor this close to an outlined spot is pulled into it.
    static let magnetRadius: CGFloat = 150

    var screen: NSScreen {
        NSScreen.screens.first { Self.displayID(of: $0) == displayID }
            ?? NSScreen.screens.first ?? NSScreen.main!
    }

    static func displayID(of screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Window origin for something of `size` docked here.
    func origin(for size: NSSize) -> NSPoint {
        let visible = screen.visibleFrame
        let m = Self.margin
        var origin = NSPoint.zero
        switch side {
        case .top, .bottom:
            switch spot {
            case .start: origin.x = visible.minX + m
            case .center: origin.x = visible.midX - size.width / 2
            case .end: origin.x = visible.maxX - m - size.width
            }
            origin.y = side == .top ? visible.maxY - m - size.height : visible.minY + m
        case .left, .right:
            switch spot {
            case .start: origin.y = visible.maxY - m - size.height
            case .center: origin.y = visible.midY - size.height / 2
            case .end: origin.y = visible.minY + m
            }
            origin.x = side == .left ? visible.minX + m : visible.maxX - m - size.width
        }
        return NSPoint(x: origin.x.rounded(), y: origin.y.rounded())
    }

    /// The spots offered on `screen`: the ones outlined while dragging and
    /// listed in the ⚙︎ menu.
    static func spots(on screen: NSScreen) -> [PillDock] {
        menuChoices.map { PillDock(side: $0.side, spot: $0.spot, displayID: displayID(of: screen)) }
    }

    /// Where something of `size` sits when docked here, as a rect.
    func frame(for size: NSSize) -> NSRect {
        NSRect(origin: origin(for: size), size: size)
    }

    /// The spot a pill dropped with the cursor at `cursor` is pulled into:
    /// the outline nearest the cursor (each in the shape the pill takes
    /// there), if the cursor is within `magnetRadius` of it. Otherwise nil,
    /// and the pill stays where it was dropped.
    static func forDrop(cursor: NSPoint, on screen: NSScreen, horizontalSize: NSSize, verticalSize: NSSize) -> PillDock? {
        func distance(_ rect: NSRect) -> CGFloat {
            let dx = max(rect.minX - cursor.x, 0, cursor.x - rect.maxX)
            let dy = max(rect.minY - cursor.y, 0, cursor.y - rect.maxY)
            return (dx * dx + dy * dy).squareRoot()
        }
        func centreDistance(_ rect: NSRect) -> CGFloat {
            hypot(rect.midX - cursor.x, rect.midY - cursor.y)
        }
        let candidates = spots(on: screen).map { dock -> (PillDock, NSRect) in
            (dock, dock.frame(for: dock.isVertical ? verticalSize : horizontalSize))
        }
        let best = candidates.min { a, b in
            let da = distance(a.1), db = distance(b.1)
            return da != db ? da < db : centreDistance(a.1) < centreDistance(b.1)
        }
        guard let best, distance(best.1) <= magnetRadius else { return nil }
        return best.0
    }

    /// Keeps something of `size` centred on `center` but fully inside the usable area.
    static func origin(centeredOn center: CGPoint, size: NSSize) -> NSPoint {
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.screens.first ?? NSScreen.main!
        let visible = screen.visibleFrame
        var origin = NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - size.height - 4)
        return NSPoint(x: origin.x.rounded(), y: origin.y.rounded())
    }

    /// The choices offered in the pill's ⚙︎ menu.
    static let menuChoices: [(title: String, side: Side, spot: Spot)] = [
        ("Top Left", .top, .start), ("Top Centre", .top, .center), ("Top Right", .top, .end),
        ("Left", .left, .center), ("Right", .right, .center),
        ("Bottom Left", .bottom, .start), ("Bottom Centre", .bottom, .center), ("Bottom Right", .bottom, .end),
    ]
}
