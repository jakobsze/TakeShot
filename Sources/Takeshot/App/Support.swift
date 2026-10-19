import SwiftUI
import AppKit

/// Donation / "Support" entry points: a coffee button in the editor toolbar
/// and the menus, a dismissible banner inside the Recordings grid, and a card
/// in the export sheet while a video renders.
///
/// The donation link is the `DonateURL` key in Info.plist, so it can be
/// changed without touching code.
@MainActor
enum Support {
    static let bannerSnoozeDays = 7

    private static let defaults = UserDefaults.standard
    private static let exportCountKey = "supportExportCount"
    private static let bannerHiddenUntilKey = "supportBannerHiddenUntil"

    static var donateURL: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "DonateURL") as? String,
              !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return URL(string: raw)
    }

    static func openDonatePage() {
        if let url = donateURL {
            NSWorkspace.shared.open(url)
        } else {
            let alert = NSAlert()
            alert.messageText = "Support link not set yet"
            alert.informativeText = "Add your donation page URL to the DonateURL key in Resources/Info.plist and rebuild."
            alert.runModal()
        }
    }

    // MARK: Export count

    /// Call after each successful export.
    static func recordExport() {
        defaults.set(defaults.integer(forKey: exportCountKey) + 1, forKey: exportCountKey)
    }

    static var exportCount: Int { defaults.integer(forKey: exportCountKey) }

    // MARK: Banner

    static var isBannerVisible: Bool {
        let until = defaults.double(forKey: bannerHiddenUntilKey)
        return Date().timeIntervalSince1970 >= until
    }

    static func snoozeBanner() {
        let until = Date().addingTimeInterval(Double(bannerSnoozeDays) * 86_400)
        defaults.set(until.timeIntervalSince1970, forKey: bannerHiddenUntilKey)
    }
}

/// Plain entry used in toolbars and menus (menus can't show the styled button).
struct SupportButton: View {
    var body: some View {
        Button {
            Support.openDonatePage()
        } label: {
            Label("Buy Me a Coffee…", systemImage: "cup.and.saucer")
        }
        .help("Support Takeshot's development")
    }
}

/// The donation button in the style of the donation page: yellow rounded
/// rectangle, black text and a takeaway cup. Its fixed colours are deliberate
/// (a brand button, the same in light and dark mode), unlike the rest of the UI.
struct CoffeeButton: View {
    var compact = false

    private static let yellow = Color(red: 1, green: 0xDD / 255.0, blue: 0)

    var body: some View {
        let height: CGFloat = compact ? 26 : 38
        Button {
            Support.openDonatePage()
        } label: {
            HStack(spacing: height * 0.2) {
                CoffeeCup()
                    .frame(width: height * 0.4, height: height * 0.56)
                Text("Buy me a coffee")
                    .font(.system(size: height * 0.42, weight: .medium))
                    .foregroundStyle(.black)
                    .fixedSize()
            }
            .padding(.horizontal, height * 0.42)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: height * 0.2, style: .continuous).fill(Self.yellow))
            .contentShape(RoundedRectangle(cornerRadius: height * 0.2, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Opens buymeacoffee.com in your browser")
        .accessibilityLabel("Buy me a coffee")
    }
}

/// A takeaway cup: white, outlined in black, with a lid and a sleeve line.
private struct CoffeeCup: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let line = max(1.2, w * 0.11)
            ZStack {
                // Cup body, narrowing towards the bottom.
                Path { p in
                    p.move(to: CGPoint(x: w * 0.14, y: h * 0.3))
                    p.addLine(to: CGPoint(x: w * 0.86, y: h * 0.3))
                    p.addLine(to: CGPoint(x: w * 0.74, y: h * 0.97))
                    p.addLine(to: CGPoint(x: w * 0.26, y: h * 0.97))
                    p.closeSubpath()
                }
                .fill(.white)
                Path { p in
                    p.move(to: CGPoint(x: w * 0.14, y: h * 0.3))
                    p.addLine(to: CGPoint(x: w * 0.86, y: h * 0.3))
                    p.addLine(to: CGPoint(x: w * 0.74, y: h * 0.97))
                    p.addLine(to: CGPoint(x: w * 0.26, y: h * 0.97))
                    p.closeSubpath()
                    // Sleeve line.
                    p.move(to: CGPoint(x: w * 0.2, y: h * 0.58))
                    p.addLine(to: CGPoint(x: w * 0.8, y: h * 0.58))
                }
                .stroke(.black, style: StrokeStyle(lineWidth: line, lineJoin: .round))
                // Lid.
                RoundedRectangle(cornerRadius: line)
                    .fill(.white)
                    .overlay(RoundedRectangle(cornerRadius: line).stroke(.black, lineWidth: line))
                    .frame(width: w * 0.96, height: h * 0.16)
                    .position(x: w / 2, y: h * 0.22)
                // Lid top.
                RoundedRectangle(cornerRadius: line)
                    .fill(.white)
                    .overlay(RoundedRectangle(cornerRadius: line).stroke(.black, lineWidth: line))
                    .frame(width: w * 0.62, height: h * 0.12)
                    .position(x: w / 2, y: h * 0.08)
            }
        }
    }
}

// MARK: - Designed donation surfaces (from the project's Figma designs)

/// Images for the donation surfaces, copied into the bundle from
/// `Resources/Donation/` by the Makefile and the release script.
enum DonationArt {
    static func image(_ name: String) -> NSImage? {
        Bundle.main.url(forResource: name, withExtension: "png").flatMap(NSImage.init(contentsOf:))
    }
    static let appIcon = image("app-icon")
    static let cup = image("cup@4x")
    static let close = image("close@4x")
    static let bannerBackground = image("banner-background")
    static let exportBackground = image("export-background")
    /// The button colour in the design.
    static let orange = Color(red: 1, green: 0x48 / 255.0, blue: 0)
}

/// Orange "Buy me a coffee" pill used by the designed banner and export card.
private struct OrangeCoffeeButton: View {
    var large = false

    var body: some View {
        Button {
            Support.openDonatePage()
        } label: {
            HStack(spacing: 5) {
                if let cup = DonationArt.cup {
                    Image(nsImage: cup)
                        .resizable()
                        .frame(width: 12.435, height: 18)
                        .frame(width: 18, height: 18)
                }
                Text("Buy me a coffee")
                    .font(.system(size: large ? 18 : 12, weight: large ? .bold : .semibold))
                    .foregroundStyle(.white)
                    .fixedSize()
            }
            .padding(.horizontal, large ? 32 : 16)
            .padding(.vertical, large ? 16 : 7)
            .background(Capsule().fill(DonationArt.orange))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Opens buymeacoffee.com in your browser")
        .accessibilityLabel("Buy me a coffee")
    }
}

/// Banner placed inside the Recordings grid (Figma node 14:30). Its colours
/// come from the design's light background, so they don't follow dark mode.
struct SupportBanner: View {
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                if let icon = DonationArt.appIcon {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 30, height: 30)
                }
                Text("Takeshot is free. If it saves you time, you can support its development.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.black)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                OrangeCoffeeButton()
                Button(action: onClose) {
                    if let close = DonationArt.close {
                        Image(nsImage: close).resizable().frame(width: 24, height: 24)
                    }
                }
                .buttonStyle(.plain)
                .help("Hide for \(Support.bannerSnoozeDays) days")
                .accessibilityLabel("Hide for \(Support.bannerSnoozeDays) days")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 48)
        .background {
            if let bg = DonationArt.bannerBackground {
                Image(nsImage: bg).resizable().scaledToFill()
            }
        }
        .clipped()
    }
}

/// Card shown in the export sheet while a video renders (Figma node 14:102).
struct ExportSupportCard: View {
    var body: some View {
        VStack(spacing: 14) {
            if let icon = DonationArt.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 109, height: 109)
                    .shadow(color: Color(red: 26 / 255, green: 28 / 255, blue: 31 / 255).opacity(0.03), radius: 7.18 / 2, y: 3.99)
                    .shadow(color: Color(red: 26 / 255, green: 28 / 255, blue: 31 / 255).opacity(0.04), radius: 24.12 / 2, y: 13.4)
                    .shadow(color: Color(red: 26 / 255, green: 28 / 255, blue: 31 / 255).opacity(0.07), radius: 108 / 2, y: 60)
            }
            VStack(spacing: 20) {
                Text("Takeshot is free and made in spare time. If it\u{2019}s useful to you, a small donation helps keep it going.")
                    .font(.system(size: 16, weight: .semibold))
                    .lineSpacing(1)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.black)
                    .fixedSize(horizontal: false, vertical: true)
                OrangeCoffeeButton(large: true)
            }
        }
        .frame(width: 359)
        .padding(.horizontal, 29)
        .padding(.vertical, 24)
        .background {
            if let bg = DonationArt.exportBackground {
                Image(nsImage: bg).resizable().scaledToFill()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
