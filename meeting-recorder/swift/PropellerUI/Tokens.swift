import SwiftUI
import AppKit
import CoreText

/// Propeller design tokens — three-tier alias chain (rntl / ArtIntel logic):
/// **Primitive → Token → Semantic**. Components consume **Semantic** (and Space /
/// Radius). Off-scale literals snap to the nearest step instead of inventing new ones.
///
/// Typography stays SF Pro (macOS-native). System Settings / alerts are out of scope.
public enum Tokens {

    // MARK: - 1. Primitives

    public enum Primitive {
        public enum AlphaWhite {
            public static let a0: Double = 0
            public static let a7: Double = 0.07
            public static let a10: Double = 0.10
            public static let a12: Double = 0.12
            public static let a15: Double = 0.15
            public static let a20: Double = 0.20
            public static let a30: Double = 0.30
            public static let a40: Double = 0.40 // snap for legacy 0.40 UI chrome
            public static let a50: Double = 0.50
            public static let a70: Double = 0.70
            public static let a95: Double = 0.95
            public static let a100: Double = 1.0

            public static func color(_ a: Double) -> SwiftUI.Color { SwiftUI.Color.white.opacity(a) }
            public static func nsColor(_ a: Double) -> NSColor {
                NSColor(calibratedWhite: 1, alpha: a)
            }
        }

        public enum AlphaBlack {
            public static let a0: Double = 0
            public static let a7: Double = 0.07
            public static let a10: Double = 0.10
            public static let a12: Double = 0.12
            public static let a15: Double = 0.15
            public static let a30: Double = 0.30
            public static let a50: Double = 0.50
            public static let a70: Double = 0.70
            public static let a80: Double = 0.80 // glass wash
            public static let a95: Double = 0.95
            public static let a100: Double = 1.0

            public static func color(_ a: Double) -> SwiftUI.Color { SwiftUI.Color.black.opacity(a) }
            public static func nsColor(_ a: Double) -> NSColor {
                NSColor(calibratedWhite: 0, alpha: a)
            }
        }

        /// Near-black used under glass (#0A0A0A).
        public static let inkWashWhite: CGFloat = 10.0 / 255.0
    }

    // MARK: - 2. Tokens (aliases over primitives)

    public enum Neutral {
        public static let aw7 = Primitive.AlphaWhite.color(Primitive.AlphaWhite.a7)
        public static let aw10 = Primitive.AlphaWhite.color(Primitive.AlphaWhite.a10)
        public static let aw12 = Primitive.AlphaWhite.color(Primitive.AlphaWhite.a12)
        public static let aw15 = Primitive.AlphaWhite.color(Primitive.AlphaWhite.a15)
        public static let aw20 = Primitive.AlphaWhite.color(Primitive.AlphaWhite.a20)
        public static let aw30 = Primitive.AlphaWhite.color(Primitive.AlphaWhite.a30)
        public static let aw40 = Primitive.AlphaWhite.color(Primitive.AlphaWhite.a40)
        public static let aw50 = Primitive.AlphaWhite.color(Primitive.AlphaWhite.a50)
        public static let aw70 = Primitive.AlphaWhite.color(Primitive.AlphaWhite.a70)
        public static let aw95 = Primitive.AlphaWhite.color(Primitive.AlphaWhite.a95)
        public static let white = Primitive.AlphaWhite.color(Primitive.AlphaWhite.a100)

        public static let ab7 = Primitive.AlphaBlack.color(Primitive.AlphaBlack.a7)
        public static let ab15 = Primitive.AlphaBlack.color(Primitive.AlphaBlack.a15)
        public static let ab30 = Primitive.AlphaBlack.color(Primitive.AlphaBlack.a30)
        public static let ab70 = Primitive.AlphaBlack.color(Primitive.AlphaBlack.a70)
        public static let ab95 = Primitive.AlphaBlack.color(Primitive.AlphaBlack.a95)
        public static let black = Primitive.AlphaBlack.color(Primitive.AlphaBlack.a100)
    }

    // MARK: - 3. Semantic (what components use)

    public enum Paint {
        public enum Bg {
            public static let page = Neutral.black
            public static let surface = Neutral.aw7
            public static let selected = Neutral.aw12
            public static let overlay = Neutral.ab70
            public static let inverted = Neutral.white
            /// `#0A0A0A @ 80%` wash over `.thickMaterial`.
            public static var glassWash: NSColor {
                NSColor(calibratedWhite: Primitive.inkWashWhite, alpha: Primitive.AlphaBlack.a80)
            }
        }

        public enum Text {
            public static let primary = Neutral.aw95
            public static let secondary = Neutral.aw70
            public static let tertiary = Neutral.aw30
            public static let quaternary = Neutral.aw40
            public static let disabled = Neutral.aw20
            public static let primaryInverse = Neutral.ab95
            public static let secondaryInverse = Neutral.ab70
        }

        public enum Interactive {
            public enum Primary {
                public static let rest = Neutral.aw95
                public static let hover = Neutral.white
                public static let disabled = Neutral.aw7
            }
            public enum Secondary {
                public static let rest = Neutral.aw7
                public static let hover = Neutral.aw12
                public static let active = Neutral.aw10
                public static let disabled = Neutral.aw7
            }
            public enum Ghost {
                public static let rest = Primitive.AlphaWhite.color(Primitive.AlphaWhite.a0)
                public static let hover = Neutral.aw7
                public static let active = Neutral.aw10
                public static let disabled = Primitive.AlphaWhite.color(Primitive.AlphaWhite.a0)
            }
            /// No fill ever — content only brightens (Propeller-specific).
            public enum Minimal {
                public static let rest = Text.tertiary
                public static let hover = Text.secondary
                public static let disabled = Text.disabled
            }
        }

        public enum Status {
            public static let record = SwiftUI.Color.red
            public static let warning = SwiftUI.Color.orange
            public static let accent = SwiftUI.Color.accentColor
        }
    }

    // MARK: - 4. Radiuses

    public enum Radius {
        public static let none: CGFloat = 0
        public static let xxxxs: CGFloat = 2
        public static let xxxs: CGFloat = 4
        public static let xxs: CGFloat = 6
        public static let xs: CGFloat = 8
        public static let sm: CGFloat = 10
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 14
        public static let xl: CGFloat = 26
        public static let x2l: CGFloat = 34
        public static let x3l: CGFloat = 42
        public static let full: CGFloat = 9999
    }

    // MARK: - 5. Spaces

    public enum Space {
        public static let s2: CGFloat = 2
        public static let s4: CGFloat = 4
        public static let s6: CGFloat = 6
        public static let s8: CGFloat = 8
        public static let s10: CGFloat = 10
        public static let s12: CGFloat = 12
        public static let s16: CGFloat = 16
        public static let s20: CGFloat = 20
        public static let s24: CGFloat = 24
        public static let s32: CGFloat = 32
        public static let s40: CGFloat = 40
        public static let s48: CGFloat = 48
        public static let s64: CGFloat = 64
    }

    // MARK: - 6. Motion

    public enum Motion {
        public static let hover: Double = 0.12
        public static let press: Double = 0.065
        public static let release: Double = 0.13
    }

    // MARK: - Layout semantics (roles → Space / Radius)

    public enum Glass {
        public static var fill: NSColor { Paint.Bg.glassWash }
        public static var fillWhite: CGFloat { Primitive.inkWashWhite }
        public static var fillAlpha: CGFloat { Primitive.AlphaBlack.a80 }
        public static var tint: NSColor { fill }
    }

    public enum Window {
        public static let contentWidth: CGFloat = 640
        public static let chromePadding: CGFloat = Space.s12
        public static let trafficLightSlotWidth: CGFloat = 76
        public static let trafficLightLeading: CGFloat = Space.s24
        public static let trafficLightSpacing: CGFloat = Space.s20
        public static let topBarHeight: CGFloat = 56
        public static let titleBlockHeight: CGFloat = 100
        public static let sectionStackGap: CGFloat = Space.s24
        public static let sectionInnerGap: CGFloat = Space.s8
        public static let rowRadius: CGFloat = Radius.md
        public static let updatePillHeight: CGFloat = Space.s32
        public static let updatePillHPadding: CGFloat = Space.s10
    }

    public enum Toast {
        public static let radius: CGFloat = Radius.lg
        public static let maxWidth: CGFloat = 280
        public static let fill = Paint.Bg.surface
        public static let cornerInset: CGFloat = Space.s16
    }

    public enum Card {
        public static let width: CGFloat = 400
        public static let height: CGFloat = 400
        public static let radius: CGFloat = Radius.xl
        public static let inset: CGFloat = Space.s24
        public static let contentGap: CGFloat = Space.s20
        public static let textGap: CGFloat = Space.s12
        public static let actionPadding: CGFloat = Space.s24
    }

    public enum Pill {
        public static let height: CGFloat = 36
        public static let hPadding: CGFloat = 14
        public static let vPadding: CGFloat = Space.s8
        public static let radius: CGFloat = Radius.full
        public static let iconGap: CGFloat = Space.s4
        public static let rowGap: CGFloat = Space.s8
    }

    /// Back-compat aliases — prefer `Tokens.Paint.Text.*`.
    public enum Ink {
        public static let primary = Paint.Text.primary
        public static let secondary = Paint.Text.secondary
        public static let tertiary = Paint.Text.tertiary
        public static let quaternary = Paint.Text.quaternary
    }

    // MARK: - 7. Typography
    // Three roles: Heading (titles), Label (UI), Body (reading: summary / transcript).

    public enum Typography {
        /// SF Pro opsz axis ends at 28 (Display). Headings lock there.
        public static let opszMax: CGFloat = 28
        /// Labels sit above Text default (17), below full Display.
        public static let opszElevated: CGFloat = 20
        /// Body stays on the Text end of the axis.
        public static let opszText: CGFloat = 17

        public struct Style: Equatable, Sendable {
            public let size: CGFloat
            public let lineHeight: CGFloat
            public let weight: Font.Weight
            public let opticalSize: CGFloat

            public var nsWeight: NSFont.Weight {
                switch weight {
                case .semibold: return .semibold
                case .medium: return .medium
                default: return .regular
                }
            }

            public var nsFont: NSFont {
                Typography.systemFont(size: size, weight: nsWeight, opticalSize: opticalSize)
            }

            public var font: Font { Font(nsFont) }

            /// Extra for SwiftUI `.lineSpacing` (may be negative when LH is tight).
            public var lineSpacingExtra: CGFloat {
                let used = nsFont.ascender - nsFont.descender + nsFont.leading
                return lineHeight - used
            }
        }

        /// Titles. Semibold, max opsz. LH% 95→105 as size drops.
        public enum Heading {
            /// 36 / 34 (95%)
            public static let lg = Style(size: 36, lineHeight: 34, weight: .semibold, opticalSize: opszMax)
            /// 28 / 28 (~100%)
            public static let md = Style(size: 28, lineHeight: 28, weight: .semibold, opticalSize: opszMax)
            /// 22 / 23 (105%)
            public static let sm = Style(size: 22, lineHeight: 23, weight: .semibold, opticalSize: opszMax)
        }

        /// UI copy — mostly single-line. Regular or medium, elevated opsz.
        public enum Label {
            /// 14 / 18
            public static let mdRegular = Style(size: 14, lineHeight: 18, weight: .regular, opticalSize: opszElevated)
            public static let mdMedium = Style(size: 14, lineHeight: 18, weight: .medium, opticalSize: opszElevated)
            /// 12 / 14
            public static let smRegular = Style(size: 12, lineHeight: 14, weight: .regular, opticalSize: opszElevated)
            public static let smMedium = Style(size: 12, lineHeight: 14, weight: .medium, opticalSize: opszElevated)
            /// 10 / 12
            public static let xsRegular = Style(size: 10, lineHeight: 12, weight: .regular, opticalSize: opszElevated)
            public static let xsMedium = Style(size: 10, lineHeight: 12, weight: .medium, opticalSize: opszElevated)

            /// Pill / CTA label — medium 14/18 (no semibold in Label).
            public static let pill = mdMedium
        }

        /// Long-form reading: summary, transcript, notes. 14 / 22.
        public enum Body {
            public static let md = Style(size: 14, lineHeight: 22, weight: .regular, opticalSize: opszText)
        }

        fileprivate static func systemFont(
            size: CGFloat, weight: NSFont.Weight, opticalSize: CGFloat
        ) -> NSFont {
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            let key = NSFontDescriptor.AttributeName(rawValue: kCTFontOpticalSizeAttribute as String)
            let desc = base.fontDescriptor.addingAttributes([key: opticalSize])
            return NSFont(descriptor: desc, size: size) ?? base
        }
    }
}

extension View {
    /// Apply a Propeller text style (font + line height).
    public func typo(
        _ style: Tokens.Typography.Style,
        monospacedDigit: Bool = false
    ) -> some View {
        let font = monospacedDigit ? style.font.monospacedDigit() : style.font
        return self
            .font(font)
            .lineSpacing(style.lineSpacingExtra)
    }
}

/// Onboarding title/supporting via AppKit so fixed line-height sticks.
enum OnboardText {
    /// Heading.md, centered, primary ink.
    static func title(_ string: String) -> StyledLabel {
        StyledLabel(attributed: attributed(
            string,
            style: Tokens.Typography.Heading.md,
            color: Tokens.Primitive.AlphaWhite.nsColor(Tokens.Primitive.AlphaWhite.a95),
            alignment: .center))
    }

    /// Label.md regular — onboarding support line (not Body; Body is for reading panes).
    static func body(_ string: String) -> StyledLabel {
        StyledLabel(attributed: attributed(
            string,
            style: Tokens.Typography.Label.mdRegular,
            color: Tokens.Primitive.AlphaWhite.nsColor(Tokens.Primitive.AlphaWhite.a70),
            alignment: .center))
    }

    /// Heading.md with solid lead + tertiary tail (end / summary-model screens).
    static func titleTwoTone(_ lead: String, _ tail: String) -> StyledLabel {
        let style = Tokens.Typography.Heading.md
        let m = NSMutableAttributedString()
        m.append(attributed(lead, style: style,
                            color: Tokens.Primitive.AlphaWhite.nsColor(Tokens.Primitive.AlphaWhite.a95),
                            alignment: .center))
        m.append(attributed(tail, style: style,
                            color: Tokens.Primitive.AlphaWhite.nsColor(Tokens.Primitive.AlphaWhite.a30),
                            alignment: .center))
        return StyledLabel(attributed: m)
    }

    private static func attributed(
        _ string: String, style: Tokens.Typography.Style,
        color: NSColor, alignment: NSTextAlignment = .left
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = style.lineHeight
        paragraph.maximumLineHeight = style.lineHeight
        paragraph.alignment = alignment
        return NSAttributedString(string: string, attributes: [
            .font: style.nsFont,
            .paragraphStyle: paragraph,
            .foregroundColor: color,
        ])
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
