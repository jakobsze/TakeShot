import SwiftUI
import AppKit

/// Native macOS styling helpers, so every surface uses system materials,
/// colours and controls (following Apple's Human Interface Guidelines)
/// rather than hard-coded values. On macOS 26+ floating surfaces use
/// Liquid Glass; earlier systems get the equivalent NSVisualEffectView
/// material.

/// A behind-window blur (vibrancy) background. SwiftUI's own materials
/// only blend *within* a window, which shows nothing useful in our
/// transparent floating panels.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

extension View {
    /// Floating-control surface: Liquid Glass on macOS 26+, HUD material before.
    @ViewBuilder
    func floatingSurface<S: Shape>(_ shape: S) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(VisualEffectBackground(material: .hudWindow).clipShape(shape))
                .overlay(shape.stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
        }
    }
}

/// Opens the app's standard Settings window (⌘,) from anywhere. On macOS 14+
/// this uses SwiftUI's `openSettings` action, captured from a live view by
/// `SettingsOpenerInstaller`; the old selector is only a macOS 13 fallback.
@MainActor
enum SettingsOpener {
    static var action: (() -> Void)?
}

@MainActor
func openAppSettings() {
    NSApp.activate(ignoringOtherApps: true)
    if let action = SettingsOpener.action {
        action()
    } else {
        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
    }
}

/// Attach once to an always-present view to capture `openSettings`.
struct SettingsOpenerInstaller: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.modifier(Installer14())
        } else {
            content
        }
    }

    @available(macOS 14.0, *)
    private struct Installer14: ViewModifier {
        @Environment(\.openSettings) private var openSettings
        func body(content: Content) -> some View {
            content.onAppear {
                let action = openSettings
                SettingsOpener.action = { action() }
            }
        }
    }
}

/// System colours for timeline tracks and badges.
enum TrackColor {
    static let clip = Color(nsColor: .systemYellow)
    static let clipFast = Color(nsColor: .systemOrange)
    static let clipSlow = Color(nsColor: .systemTeal)
    static let zoom = Color(nsColor: .systemPurple)
    static let mask = Color(nsColor: .systemOrange)
    static let layout = Color(nsColor: .systemGreen)
    static let caption = Color(nsColor: .systemGray)
    static let playhead = Color(nsColor: .systemRed)
}
