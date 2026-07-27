import SwiftUI
import AppKit

/// Design tokens — ONLY values that actually repeat across the redesign get a
/// name here.
///
/// Cross-checked against Figma «Драфтология» onboarding 642:2120 (Welcome 642:2122).
public enum Tokens {

    /// Shared window fill for main + onboarding. One stack only — change here.
    /// Material + wash so both hosts look the same (pure liquid-glass samples
    /// the desktop differently in a floating panel vs a titled WindowGroup).
    public enum Glass {
        /// rgba(10,10,10,0.8) → #0A0A0A @ 80%.
        public static let fillWhite: CGFloat = 10.0 / 255.0
        public static let fillAlpha: CGFloat = 0.8

        public static var fill: NSColor {
            NSColor(calibratedWhite: fillWhite, alpha: fillAlpha)
        }

        /// Alias kept for any AppKit glass helpers.
        public static var tint: NSColor { fill }
    }

    /// Main Meetings window — Figma 640:1859.
    public enum Window {
        /// Inner column (Frame 86) — sits inside chromePadding.
        public static let contentWidth: CGFloat = 640
        /// Frame 84 / 87 outer inset.
        public static let chromePadding: CGFloat = 12
        /// Figma 640:1863: slot 76×32 at (12,12); discs Ø12 at x=12/32/52 → origins 24/44/64.
        public static let trafficLightSlotWidth: CGFloat = 76
        public static let trafficLightLeading: CGFloat = 24
        public static let trafficLightSpacing: CGFloat = 20
        /// Frame 84 = p-12 + 32 controls.
        public static let topBarHeight: CGFloat = 56
        /// Frame 85.
        public static let titleBlockHeight: CGFloat = 100
        /// Gap between title / Upcoming / Today blocks (Frame 86).
        public static let sectionStackGap: CGFloat = 24
        /// Gap header→rows and (inside section) not between rows.
        public static let sectionInnerGap: CGFloat = 8
        public static let rowRadius: CGFloat = 12
        /// Update pill in top bar (640:1979): h=32, px=10.
        public static let updatePillHeight: CGFloat = 32
        public static let updatePillHPadding: CGFloat = 10
    }

    /// In-app toast — Figma 640:1987.
    public enum Toast {
        public static let radius: CGFloat = 16
        public static let maxWidth: CGFloat = 280
        public static let fill = Color.white.opacity(0.07)
        /// Equal gap from both window edges, so the toast reads as offset from
        /// the corner rather than wedged into it. 8/12 was unequal and too tight;
        /// matching the toast's own corner radius keeps the rounded corner clear
        /// of the window corner.
        public static let cornerInset: CGFloat = 16
    }

    /// Onboarding plate — Figma 642:2122 is 400×400.
    public enum Card {
        public static let width: CGFloat = 400
        public static let height: CGFloat = 400
        /// Figma plate radius (used only when we must mirror the mock; live
        /// window prefers `NSGlassEffectView.cornerRadius`).
        public static let radius: CGFloat = 26
        public static let inset: CGFloat = 24
        /// Gap between pager / title block / extras in the centred stack.
        public static let contentGap: CGFloat = 20
        /// Gap between title and body inside the text block.
        public static let textGap: CGFloat = 12
        public static let actionPadding: CGFloat = 24
    }

    public enum Pill {
        public static let height: CGFloat = 36
        public static let hPadding: CGFloat = 14
        public static let vPadding: CGFloat = 8
        public static let radius: CGFloat = 32
        public static let iconGap: CGFloat = 4
        public static let rowGap: CGFloat = 8
    }

    public enum Ink {
        public static let primary = Color.white
        public static let secondary = Color.white.opacity(0.70)
        public static let tertiary = Color.white.opacity(0.30)
    }
}

extension Font {
    static let pillLabel = Font.system(size: 14, weight: .semibold)
}

/// Onboarding title/body via AppKit so line-height / tracking stick.
enum OnboardText {
    /// SF Pro Display 28 / semibold · line-height 30 · tracking −0.28 · white.
    static func title(_ string: String) -> StyledLabel {
        StyledLabel(attributed: attributed(
            string,
            font: .systemFont(ofSize: 28, weight: .semibold),
            lineHeight: 30, tracking: -0.28, color: .white,
            alignment: .center))
    }

    /// SF Pro 14 / regular · line-height 20 · white 70%.
    static func body(_ string: String) -> StyledLabel {
        StyledLabel(attributed: attributed(
            string,
            font: .systemFont(ofSize: 14, weight: .regular),
            lineHeight: 20, tracking: 0.025,
            color: NSColor.white.withAlphaComponent(0.70),
            alignment: .center))
    }

    /// Title with a solid lead and tertiary tail (end screen).
    static func titleTwoTone(_ lead: String, _ tail: String) -> StyledLabel {
        let font = NSFont.systemFont(ofSize: 28, weight: .semibold)
        let m = NSMutableAttributedString()
        m.append(attributed(lead, font: font, lineHeight: 30, tracking: -0.28,
                            color: .white, alignment: .center))
        m.append(attributed(tail, font: font, lineHeight: 30, tracking: -0.28,
                            color: NSColor.white.withAlphaComponent(0.30),
                            alignment: .center))
        return StyledLabel(attributed: m)
    }

    private static func attributed(
        _ string: String, font: NSFont, lineHeight: CGFloat, tracking: CGFloat,
        color: NSColor, alignment: NSTextAlignment = .left
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        paragraph.alignment = alignment
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraph,
            .foregroundColor: color,
        ]
        if tracking != 0 { attrs[.kern] = tracking }
        return NSAttributedString(string: string, attributes: attrs)
    }
}

struct StyledLabel: NSViewRepresentable {
    let attributed: NSAttributedString

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.attributedStringValue = attributed
        field.isEditable = false
        field.isSelectable = false
        field.drawsBackground = false
        field.isBordered = false
        field.focusRingType = .none
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        field.attributedStringValue = attributed
        field.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        let proposed = proposal.width ?? .infinity
        let width = (proposed.isFinite && proposed > 0) ? proposed : nsView.intrinsicContentSize.width
        nsView.preferredMaxLayoutWidth = width
        let fit = nsView.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(fit.height))
    }
}
