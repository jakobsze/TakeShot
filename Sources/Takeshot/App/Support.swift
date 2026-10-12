import SwiftUI
import AppKit

/// Donation / "Support" entry points: a heart button in the editor toolbar
/// and the pill's menu, a dismissible banner in the Recordings window, and a
/// one-time thank-you after the 10th export.
///
/// The donation link is the `DonateURL` key in Info.plist, so it can be
/// changed without touching code.
@MainActor
enum Support {
    static let thankYouAfterExports = 10
    static let bannerSnoozeDays = 30

    private static let defaults = UserDefaults.standard
    private static let exportCountKey = "supportExportCount"
    private static let thankYouShownKey = "supportThankYouShown"
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

    // MARK: Export milestone

    /// Call after each successful export. Returns true exactly once, when
    /// the milestone is reached, so the thank-you note is shown a single time.
    static func recordExportAndCheckMilestone() -> Bool {
        let count = defaults.integer(forKey: exportCountKey) + 1
        defaults.set(count, forKey: exportCountKey)
        guard count >= thankYouAfterExports, !defaults.bool(forKey: thankYouShownKey) else { return false }
        defaults.set(true, forKey: thankYouShownKey)
        return true
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

/// Heart button used in toolbars and menus.
struct SupportButton: View {
    var body: some View {
        Button {
            Support.openDonatePage()
        } label: {
            Label("Support Takeshot", systemImage: "heart")
        }
        .help("Support Takeshot's development")
    }
}

/// Slim banner shown at the top of the Recordings window; closing it hides it for 30 days.
struct SupportBanner: View {
    @State private var visible = Support.isBannerVisible

    var body: some View {
        if visible {
            HStack(spacing: 10) {
                Image(systemName: "heart.fill")
                    .foregroundStyle(Color(nsColor: .systemPink))
                Text("Takeshot is free. If it saves you time, you can support its development.")
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Button("Support…") { Support.openDonatePage() }
                    .controlSize(.small)
                Button {
                    Support.snoozeBanner()
                    withAnimation { visible = false }
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Hide for \(Support.bannerSnoozeDays) days")
                .accessibilityLabel("Hide for \(Support.bannerSnoozeDays) days")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color(nsColor: .systemPink).opacity(0.08))
            .overlay(alignment: .bottom) { Divider() }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// One-time note after the 10th export, shown in the export sheet.
struct SupportThankYouCard: View {
    @Binding var visible: Bool

    var body: some View {
        if visible {
            VStack(alignment: .leading, spacing: 8) {
                Label("You've exported \(Support.thankYouAfterExports) videos. Thank you!", systemImage: "heart.fill")
                    .font(.headline)
                    .foregroundStyle(Color(nsColor: .systemPink))
                Text("Takeshot is free and made in spare time. If it's useful to you, a small donation helps keep it going.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Support…") { Support.openDonatePage() }
                    Button("Maybe later") { withAnimation { visible = false } }
                        .buttonStyle(.borderless)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .systemPink).opacity(0.08)))
        }
    }
}
